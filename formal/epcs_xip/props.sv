// Propriedades do epcs_xip, verificadas na netlist Verilog que o GHDL sintetiza do VHDL (o adaptador e o epcs_spi
// juntos), com uma janela de 64 bytes que começa no byte 128 do chip. O ambiente é livre: o pedido (endereço, tipo,
// avanço) e o MISO são entradas quaisquer, presas só por suposições (um clock de reset no início, o avanço só no ciclo
// em que o pedido é atendido e o pedido mantido até lá). As propriedades olham só os pinos SPI: um monitor remonta cada
// quadro (instrução, endereço, bytes de dado lidos no MISO) pelos bits de cada subida de SCK. O que o chip jamais deve
// receber, qualquer que seja o pedido: outra instrução que não seja READ (ou FAST_READ, com -DFAST), um endereço que
// não seja o do pedido dentro da janela e alinhado à palavra ou à linha, um quadro de tamanho errado; e o que o SoC
// jamais deve ver: um dado que não seja o lido no quadro, ou uma leitura fora da janela que toque o chip.
`ifdef FAST
`define INS 8'h0B
`define HDR 5
`else
`define INS 8'h03
`define HDR 4
`endif

module props (input clk);
  localparam [23:0] OFF = 24'd128;
  (* anyseq *) wire rst, rden, line, adv, miso;
  (* anyseq *) wire [31:0] addr;
  wire ready, busy, sck, cs_n, mosi;
  wire [31:0] rdata;
  wire [95:0] rdata_x;

  epcs_xip dut (.i_clk(clk), .i_rst(rst), .i_addr(addr), .i_rden(rden), .i_line(line), .i_advance(adv),
    .o_ready(ready), .o_busy(busy), .o_rdata(rdata), .o_rdata_x(rdata_x),
    .o_sck(sck), .o_cs_n(cs_n), .o_mosi(mosi), .i_miso(miso));

  wire outw = addr[25:6] != 0;
  wire [4:0] len = line ? 5'd16 : 5'd4;
  wire [23:0] exp_addr = OFF + {18'd0, addr[5:0] & (line ? 6'h30 : 6'h3C)};

  reg f_past_valid = 0;
  reg p_sck = 0, p_cs = 1, p_miso = 0, p_rden = 0, p_adv = 0, p_line = 0, p_ready = 0;
  reg [31:0] p_addr = 0, p_rdata = 0;
  reg [95:0] p_rdata_x = 0;
  reg [3:0] bit_cnt = 0;
  reg [7:0] sh = 0, mi = 0;
  reg [4:0] byte_cnt = 0, data_cnt = 0, seen_len = 0;
  reg [23:0] a24 = 0;
  reg [127:0] dat = 0;
  always @(posedge clk) begin
    f_past_valid <= 1;
    p_sck <= sck; p_cs <= cs_n; p_miso <= miso;
    p_rden <= rden; p_adv <= adv; p_line <= line; p_addr <= addr;
    p_ready <= ready; p_rdata <= rdata; p_rdata_x <= rdata_x;
  end

  // O monitor: a subida de SCK com CS# baixo entrega um bit. O mestre amostra o MISO na borda do clock em que SCK sobe,
  // um ciclo antes de o monitor ver a subida, então o bit lido é o do ciclo anterior.
  wire rise = !cs_n && sck && !p_sck;
  wire [7:0] sh2 = {sh[6:0], mosi};
  wire [7:0] mi2 = {mi[6:0], p_miso};
  wire byte_done = rise && bit_cnt == 7;
  wire frame_end = cs_n && !p_cs;
  wire [4:0] didx = byte_cnt - `HDR;

  always @(posedge clk) begin
    if (rise) begin
      sh <= sh2;
      mi <= mi2;
      bit_cnt <= bit_cnt == 7 ? 0 : bit_cnt + 1;
    end
    if (byte_done) begin
      byte_cnt <= byte_cnt + 1;
      if (byte_cnt >= 1 && byte_cnt <= 3) a24 <= {a24[15:0], sh2};
      if (byte_cnt >= `HDR && didx < 16) begin
        dat[{didx[3:0], 3'b000} +: 8] <= mi2;
        data_cnt <= data_cnt + 1;
      end
    end
    if (frame_end && byte_cnt != 0) begin
      seen_len <= data_cnt;
      byte_cnt <= 0;
      data_cnt <= 0;
      bit_cnt <= 0;
    end
  end

  // ---- o ambiente ----
  always @* if (!f_past_valid) assume (rst);
  always @* if (f_past_valid) assume (!rst);
  always @* if (adv) assume (rden && ready);
  always @(posedge clk) if (f_past_valid && p_rden && !p_adv) assume (rden && addr == p_addr && line == p_line);
`ifdef SC_WORD
  always @* assume (!line);
`endif
`ifdef SC_LINE
  always @* assume (line);
`endif

  // ---- propriedades ----
  always @* if (f_past_valid) begin
    // 1. A única instrução que o chip recebe é a de leitura.
    if (byte_done && byte_cnt == 0) assert (sh2 == `INS);
    // 2. O endereço do quadro é o do pedido dentro da janela, somado ao byte inicial dela e alinhado.
    if (byte_done && byte_cnt == 3) assert ({a24[15:0], sh2} == exp_addr);
    // 3. O quadro traz o cabeçalho e os bytes do tipo de pedido, nem um a mais nem a menos.
    if (byte_done) assert (byte_cnt < `HDR + len);
    if (frame_end && byte_cnt != 0) assert (byte_cnt == `HDR + len);
    // 4. O chip só é selecionado enquanto um pedido espera o quadro.
    if (!cs_n) assert (busy);
    // 5. Um pedido fora da janela não toca no chip.
    if (rden && outw) assert (cs_n && !busy);
    // 6. O pronto só vem a um pedido, e o pedido dentro da janela só depois de um quadro com os bytes dele.
    if (ready) assert (rden && !busy);
    if (ready && !outw) assert (seen_len == len);
    // 7. O dado entregue é o lido do MISO no quadro (a palavra 0 com o byte de menor endereço nos bits mais baixos),
    // e zero fora da janela.
    if (ready && !outw) assert (rdata == dat[31:0]);
    if (ready && !outw && line) assert (rdata_x == dat[127:32]);
    if (ready && outw) assert (rdata == 0);
    if (ready && outw && line) assert (rdata_x == 0);
    // 8. O pronto e o dado se mantêm até o avanço.
    if (p_ready && !p_adv) assert (ready && rdata == p_rdata && rdata_x == p_rdata_x);
  end

`ifdef COVER
  always @(posedge clk) if (f_past_valid) begin
`ifdef SC_WORD
    cover (ready && !outw && !line);
`endif
`ifdef SC_LINE
    cover (ready && !outw && line);
`endif
    cover (ready && outw);
    cover (adv && !outw);
  end
`endif
endmodule
