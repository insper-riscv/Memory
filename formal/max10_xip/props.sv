// Propriedades do max10_xip, verificadas na netlist Verilog que o GHDL sintetiza do VHDL, com uma janela de 64 bytes
// (16 palavras) que começa na palavra 8 do espaço de dados da megafunção, de 6 bits de endereço. O ambiente é livre: o
// pedido (endereço, tipo, avanço), a espera, a validade do dado lido e o dado da megafunção são entradas quaisquer, presas
// só por suposições (um clock de reset no início, o avanço só com o pedido pronto, o pedido mantido até
// lá, e uma palavra lida só para um pedido de leitura já aceito). O módulo não tem porta de escrita, então a megafunção
// nunca a recebe. As propriedades olham a interface de dados: cada leitura traz o endereço de palavra do pedido dentro
// da janela, uma só por vez e na ordem; o pedido de leitura se mantém até a espera cair; um pedido fora da janela não toca
// na megafunção; e o dado entregue é o das palavras lidas.
module props (input clk);
  localparam [5:0] BASE = 6'd8;
  (* anyseq *) wire rst, rden, line, adv, wait_req, rvalid;
  (* anyseq *) wire [31:0] addr, rd_in;
  wire ready, busy, rd_out;
  wire [5:0] a_out;
  wire [31:0] rdata;
  wire [95:0] rdata_x;

  max10_xip dut (.i_clk(clk), .i_rst(rst), .i_addr(addr), .i_rden(rden), .i_line(line), .i_advance(adv),
    .o_ready(ready), .o_busy(busy), .o_rdata(rdata), .o_rdata_x(rdata_x),
    .o_data_read(rd_out), .o_data_addr(a_out), .i_data_wait(wait_req), .i_data_rvalid(rvalid), .i_data_rdata(rd_in));

  wire outw = addr[25:6] != 0;
  wire [2:0] nwords = line ? 3'd4 : 3'd1;
  wire [5:0] exp_base = BASE + (addr[5:2] & (line ? 4'hC : 4'hF));
  wire accept = rd_out && !wait_req;

  reg f_past_valid = 0;
  reg p_rden = 0, p_adv = 0, p_line = 0, p_ready = 0, p_rd = 0, p_wait = 0, pend = 0;
  reg [31:0] p_addr = 0, p_rdata = 0;
  reg [5:0] p_a = 0;
  reg [95:0] p_rdata_x = 0;
  reg [2:0] acc_cnt = 0, rv_cnt = 0;
  reg [127:0] dat = 0;
  always @(posedge clk) begin
    f_past_valid <= 1;
    p_rden <= rden; p_adv <= adv; p_line <= line; p_addr <= addr; p_ready <= ready; p_rdata <= rdata;
    p_rdata_x <= rdata_x; p_rd <= rd_out; p_wait <= wait_req; p_a <= a_out;
    if (accept) begin pend <= 1; acc_cnt <= acc_cnt + 1; end
    if (rvalid) begin
      pend <= accept;
      rv_cnt <= rv_cnt + 1;
      dat[{rv_cnt[1:0], 5'b00000} +: 32] <= rd_in;
    end
    if (adv) begin acc_cnt <= 0; rv_cnt <= 0; end
  end

  // ---- o ambiente ----
  always @* if (!f_past_valid) assume (rst);
  always @* if (f_past_valid) assume (!rst);
  always @* if (adv) assume (rden && ready);
  always @(posedge clk) if (f_past_valid && p_rden && !p_adv) assume (rden && addr == p_addr && line == p_line);
  // uma palavra lida só vem de um pedido de leitura aceito e ainda sem resposta
  always @* if (rvalid) assume (pend);
`ifdef SC_WORD
  always @* assume (!line);
`endif
`ifdef SC_LINE
  always @* assume (line);
`endif

  // ---- propriedades ----
  always @* if (f_past_valid) begin
    // 1. Cada leitura traz o endereço de palavra do pedido na janela, na ordem, uma palavra a cada leitura aceita.
    if (rd_out) assert (a_out == exp_base + {3'd0, acc_cnt[2:0]} && acc_cnt < nwords);
    // 2. Uma só leitura por vez: nunca uma nova com uma resposta pendente.
    if (rd_out) assert (!pend);
    // 3. O pedido de leitura se mantém, com o mesmo endereço, até a espera cair.
    if (p_rd && p_wait) assert (rd_out && a_out == p_a);
    // 4. Um pedido fora da janela não toca na megafunção.
    if (rden && outw) assert (!rd_out && !busy);
    // 5. O pronto só vem a um pedido, e o pedido dentro da janela só depois de todas as palavras lidas.
    if (ready) assert (rden && !busy);
    if (ready && !outw) assert (acc_cnt == nwords && rv_cnt == nwords);
    // 6. O dado entregue é o das palavras lidas, a palavra 0 primeiro, e zero fora da janela.
    if (ready && !outw) assert (rdata == dat[31:0]);
    if (ready && !outw && line) assert (rdata_x == dat[127:32]);
    if (ready && outw) assert (rdata == 0);
    if (ready && outw && line) assert (rdata_x == 0);
    // 7. O pronto e o dado se mantêm até o avanço.
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
