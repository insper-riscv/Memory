// Propriedades do epcs_ctrl, verificadas na netlist Verilog que o GHDL sintetiza do VHDL (o epcs_cmd e o epcs_spi
// juntos), com um chip de 128 KB (dois setores de 64 KB) e a região de usuário a partir de 64 KB. O ambiente é livre:
// o barramento de registradores (só ADDRESS, LENGTH e COMMAND) e o MISO são entradas quaisquer, presas só por suposições
// (só o primeiro ciclo tem reset, e o barramento não escreve o buffer, o que deixa a prova sem a memória de página).
// As propriedades olham só os pinos SPI: um monitor remonta cada quadro (instrução, endereço, bytes de dado) pelos bits que
// o mestre põe em MOSI a cada subida de SCK, e a escrita habilitada do chip (wel_chip) sobe quando um quadro WREN termina e
// cai quando um quadro PP ou SE termina. O que o chip jamais deve receber, qualquer que seja o software:
// uma instrução fora da lista, um PP ou SE sem WREN, um PP ou SE abaixo da região de usuário (o bitstream), um SE fora
// do alinhamento de setor, um PP que atravessa a página.
module props (input clk);
  localparam [23:0] UBASE = 24'h010000, CHIP = 24'h020000;
  (* anyseq *) wire rst, wr, rd, miso;
  (* anyseq *) wire [3:0] address;
  (* anyseq *) wire [31:0] data_in;
  wire [31:0] data_out;
  wire irq, sck, cs_n, mosi;

  epcs_ctrl dut (.i_clk(clk), .i_rst(rst), .i_address(address), .i_write(wr), .i_read(rd), .i_data_in(data_in),
    .o_data_out(data_out), .o_irq(irq), .o_sck(sck), .o_cs_n(cs_n), .o_mosi(mosi), .i_miso(miso));

  reg f_past_valid = 0;
  reg p_sck = 0, p_cs = 1;
  reg [3:0] bit_cnt = 0;
  reg [7:0] sh = 0, ins = 0;
  reg [8:0] byte_cnt = 0, data_cnt = 0;
  reg [23:0] addr = 0;
  reg wel_chip = 0;
  always @(posedge clk) begin
    f_past_valid <= 1;
    p_sck <= sck;
    p_cs <= cs_n;
  end

  // O monitor: a subida de SCK com CS# baixo entrega um bit.
  wire rise = !cs_n && sck && !p_sck;
  wire [7:0] sh2 = {sh[6:0], mosi};
  wire byte_done = rise && bit_cnt == 7;
  wire frame_end = cs_n && !p_cs;
  wire in_list = sh2 == 8'h9F || sh2 == 8'h05 || sh2 == 8'h06 || sh2 == 8'h03 || sh2 == 8'h0B || sh2 == 8'h02 || sh2 == 8'hD8;
  wire is_ep = sh2 == 8'h02 || sh2 == 8'hD8;
  wire [23:0] full = {addr[15:0], sh2};

  always @(posedge clk) begin
    if (rise) begin
      sh <= sh2;
      bit_cnt <= bit_cnt == 7 ? 0 : bit_cnt + 1;
    end
    if (byte_done) begin
      byte_cnt <= byte_cnt + 1;
      if (byte_cnt == 0) ins <= sh2;
      else if (byte_cnt <= 3) addr <= {addr[15:0], sh2};
      else data_cnt <= data_cnt + 1;
    end
    if (frame_end && byte_cnt != 0) begin
      if (byte_cnt == 1 && ins == 8'h06) wel_chip <= 1;
      if (ins == 8'h02 || ins == 8'hD8) wel_chip <= 0;
      byte_cnt <= 0;
      data_cnt <= 0;
      bit_cnt <= 0;
      addr <= 0;
    end
  end

  always @* if (!f_past_valid) assume (rst);
  always @* if (f_past_valid) assume (!rst);
  // O barramento só escreve os registradores de endereço, de tamanho e de comando, e nunca manda ler (o buffer fica fixo).
  always @* assume (address == 4'd2 || address == 4'd3 || address == 4'd4);
  always @* assume (!(wr && address == 4'd4) || data_in[2:0] != 3'd4);
`ifdef SC_SE
  always @* assume (!(wr && address == 4'd4) || data_in[2:0] == 3'd2 || data_in[2:0] == 3'd3 || data_in[2:0] == 3'd6);
`endif
`ifdef SC_PP
  always @* assume (!(wr && address == 4'd4) || data_in[2:0] == 3'd2 || data_in[2:0] == 3'd3 || data_in[2:0] == 3'd5);
`endif

  always @(posedge clk) if (f_past_valid) begin
    // 1. O clock fica baixo com o chip desmarcado.
    if (cs_n) assert (!sck);
    // 2. Só as sete instruções da lista saem; nenhum apagar do chip todo, nenhuma escrita do registrador de estado.
    if (byte_done && byte_cnt == 0) assert (in_list);
    // 3. Nunca PP nem SE sem um WREN terminado antes (e sem outro PP ou SE no meio).
    if (byte_done && byte_cnt == 0 && is_ep) assert (wel_chip);
    // 4. O endereço de um PP ou SE fica na região de usuário e dentro do chip; o do SE é de início de setor.
    if (byte_done && byte_cnt == 3 && (ins == 8'h02 || ins == 8'hD8)) begin
      assert (full >= UBASE && full < CHIP);
      if (ins == 8'hD8) assert (full[15:0] == 16'h0000);
    end
    // 5. Fim de quadro: um número inteiro de bytes; o SE tem quatro, o PP tem de um a 256 de dado sem sair da página,
    // o WREN tem um.
    if (frame_end && byte_cnt != 0) begin
      assert (bit_cnt == 0);
      if (ins == 8'hD8) assert (byte_cnt == 4);
      if (ins == 8'h06) assert (byte_cnt == 1);
      if (ins == 8'h02) assert (data_cnt >= 1 && data_cnt <= 256 && {1'b0, addr[7:0]} + data_cnt <= 9'd256);
    end
  end

`ifdef COVER
  always @(posedge clk) if (f_past_valid) begin
    cover (frame_end && ins == 8'h06);
    cover (frame_end && ins == 8'hD8 && wel_chip);
    cover (frame_end && ins == 8'h02 && wel_chip);
  end
`endif
endmodule
