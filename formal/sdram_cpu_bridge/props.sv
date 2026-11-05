// Propriedades do sdram_cpu_bridge, verificadas na netlist Verilog que o GHDL sintetiza do VHDL. O núcleo e o
// controlador da SDRAM (o outro domínio de clock) são entradas livres, presas ao contrato por suposições; as
// asserções são o que a ponte garante. Quatro registradores (dbg_*, adicionados a uma cópia da netlist) são
// expostos: o estado (0 livre, 1 espera, 2 pronto), as saídas dos dois sincronizadores e o toggle de pedido.
`ifndef K
`define K 3      // o controlador responde em até K ciclos depois do pedido (só a vivacidade usa)
`endif

module props (input clk);
  (* anyseq *) wire rst;
  (* anyseq *) wire [31:0] addr, wdata, c_rdata;
  (* anyseq *) wire [3:0] byteena;
  (* anyseq *) wire rden, wren, mem_advance, line, ack_tog, init_done;
  (* anyseq *) wire [95:0] wdata_x, c_rdata_x;
  (* anyseq *) wire [11:0] byteena_x;
  wire ready, req_tog, c_we, c_line, d_ack, d_init, d_req;
  wire [31:0] rdata, c_wdata;
  wire [95:0] rdata_x, c_wdata_x;
  wire [23:0] c_addr;
  wire [3:0] c_be;
  wire [11:0] c_be_x;
  wire [1:0] d_st;

  sdram_cpu_bridge dut (.i_clk_cpu(clk), .i_rst_cpu(rst),
    .i_addr(addr), .i_wdata(wdata), .i_byteena(byteena), .i_rden(rden), .i_wren(wren), .i_mem_advance(mem_advance),
    .o_ready(ready), .o_rdata(rdata), .i_line(line), .i_wdata_x(wdata_x), .i_byteena_x(byteena_x), .o_rdata_x(rdata_x),
    .o_req_tog(req_tog), .i_ack_tog(ack_tog), .i_init_done(init_done), .o_c_we(c_we), .o_c_addr(c_addr), .o_c_wdata(c_wdata),
    .o_c_be(c_be), .i_c_rdata(c_rdata), .o_c_line(c_line), .o_c_wdata_x(c_wdata_x), .o_c_be_x(c_be_x), .i_c_rdata_x(c_rdata_x),
    .dbg_st(d_st), .dbg_ack_sync(d_ack), .dbg_init_sync(d_init), .dbg_req_i(d_req));

  reg f_past_valid = 0;
  reg p_rden = 0, p_wren = 0, p_adv = 0, p_ready = 0, p_req = 0, p_ack = 0, p_init = 0, p_line = 0, p_rst = 0;
  reg [1:0] p_st = 0;
  reg [31:0] p_addr = 0, p_wdata = 0, p_crd = 0;
  reg [3:0] p_be = 0;
  reg [95:0] p_wx = 0, p_crdx = 0;
  reg [11:0] p_bex = 0;
  reg [23:0] p_caddr = 0;
  reg [31:0] p_cwdata = 0;
  reg [3:0] p_cbe = 0;
  reg p_cwe = 0, p_cline = 0;
  reg [95:0] p_cwx = 0;
  reg [11:0] p_cbex = 0;
  // Modelo do dado de leitura: capturado quando a ponte vê a resposta, entregue no avanço de uma leitura.
  reg [31:0] cap = 0, m_r = 0;
  reg [95:0] cap_x = 0, m_rx = 0;
  // Ciclos desde que o ack do controlador igualou o pedido, e ciclos de espera de uma resposta.
  reg [3:0] ack_age = 0, resp_wait = 0;

  wire accept = p_st == 2'd0 && (p_rden || p_wren) && p_init && !p_rst;
  wire seen = d_st == 2'd1 && d_ack == d_req;

  always @(posedge clk) begin
    f_past_valid <= 1;
    p_rden <= rden; p_wren <= wren; p_adv <= mem_advance; p_ready <= ready; p_req <= req_tog; p_ack <= ack_tog;
    p_init <= d_init; p_line <= line; p_rst <= rst; p_st <= d_st;
    p_addr <= addr; p_wdata <= wdata; p_be <= byteena; p_wx <= wdata_x; p_bex <= byteena_x; p_crd <= c_rdata; p_crdx <= c_rdata_x;
    p_caddr <= c_addr; p_cwdata <= c_wdata; p_cbe <= c_be; p_cwe <= c_we; p_cline <= c_line; p_cwx <= c_wdata_x; p_cbex <= c_be_x;
    if (seen) begin cap <= c_rdata; cap_x <= c_rdata_x; end
    if (d_st == 2'd2 && mem_advance && !c_we) begin m_r <= cap; m_rx <= cap_x; end
    ack_age <= (ack_tog == req_tog) ? (ack_age == 4'd15 ? ack_age : ack_age + 1) : 0;
    resp_wait <= (req_tog != p_req) ? 1 : ((d_st == 2'd1) ? (resp_wait == 4'd15 ? resp_wait : resp_wait + 1) : 0);
  end

  // ---- o ambiente ----
  always @* if (!f_past_valid) assume (rst && !ack_tog && !init_done);
  always @* if (f_past_valid) assume (!rst);
  // o núcleo mantém o pedido até avançar, e só avança quando a ponte está pronta
  always @(posedge clk) if (f_past_valid && (p_rden || p_wren) && !p_adv)
    assume (rden == p_rden && wren == p_wren && addr == p_addr && wdata == p_wdata && byteena == p_be && line == p_line
      && wdata_x == p_wx && byteena_x == p_bex);
  always @* assume (!mem_advance || ready);
  // o controlador só responde a um pedido pendente, com o toggle do pedido, em até K ciclos, e segura o dado
  // da resposta até o pedido seguinte; a inicialização, uma vez pronta, fica pronta
  always @(posedge clk) if (f_past_valid) begin
    if (ack_tog != p_ack) assume (p_req != p_ack && ack_tog == p_req);
    if (req_tog == ack_tog && p_req == p_ack) assume (c_rdata == p_crd && c_rdata_x == p_crdx);
    if (p_ack != p_req && ack_tog != req_tog) assume (resp_wait != `K || 1);
  end
  always @* assume (!(req_tog != ack_tog && ack_age == 0 && resp_wait >= `K));
  always @(posedge clk) if (f_past_valid && init_done == 1'b0) assume (!p_init || p_rst);

  always @(posedge clk) if (f_past_valid) begin
    // 1. Um pedido novo só sai da ponte livre, com o núcleo pedindo e a inicialização sincronizada; e esse
    //    pedido sempre vira uma inversão do toggle (nenhum pedido se perde).
    if (req_tog != p_req) assert (accept);
    if (accept) assert (req_tog != p_req);
    // 2. A carga útil que o controlador vê é a do núcleo no ciclo do pedido, e se mantém até o pedido seguinte.
    if (req_tog != p_req) begin
      assert (c_addr == p_addr[25:2] && c_wdata == p_wdata && c_be == p_be && c_we == p_wren && c_line == p_line);
      assert (c_wdata_x == p_wx && c_be_x == p_bex);
    end else begin
      assert (c_addr == p_caddr && c_wdata == p_cwdata && c_be == p_cbe && c_we == p_cwe && c_line == p_cline);
      assert (c_wdata_x == p_cwx && c_be_x == p_cbex);
    end
    // 3. O pronto só vem depois da resposta, e dura até o avanço; depois do avanço, some (uma resposta por pedido).
    if (ready) assert (d_ack == d_req);
    if (p_ready && !p_adv) assert (ready);
    if (p_ready && p_adv) assert (!ready);
    // 4. O cruzamento de domínio passa pelo sincronizador: a resposta só é vista dois ciclos depois de o ack
    //    do controlador igualar o pedido, e o pronto só vem depois disso.
    if (p_st == 2'd1 && d_st == 2'd2) assert (ack_age >= 2);
    // 5. Toda resposta do controlador dentro de K ciclos vira pronto em até K + 4 ciclos do pedido.
    assert (resp_wait <= `K + 4);
    // 6. Os dados de leitura saem na ordem: o dado entregue é o capturado quando a resposta foi vista, e uma
    //    escrita não mexe nele.
    assert (rdata == m_r && rdata_x == m_rx);
  end

`ifdef COVER
  always @(posedge clk) if (f_past_valid) begin
    cover (ready && !c_we && rdata != 0);
    cover (ready && c_we);
    cover (req_tog != p_req && c_line);
    cover (p_ready && p_adv && !ready);
  end
`endif
endmodule
