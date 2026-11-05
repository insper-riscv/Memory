// Propriedades do flash_arbiter, verificadas na netlist Verilog que o GHDL sintetiza do VHDL. Os dois mestres
// (a cache de instruções e a de dados) e a flash são entradas livres, presas ao contrato por suposições; as
// asserções são o que o árbitro garante. Dois registradores (dbg_*, adicionados a uma cópia da netlist) são
// expostos para as invariantes: o dono do canal (0 nenhum, 1 mestre A, 2 mestre B) e o último atendido.
`ifndef K
`define K 2      // a flash responde em até K ciclos com o pedido ativo (só a vivacidade usa)
`endif
`ifndef N
`define N 6      // um mestre é atendido em até N ciclos depois de pedir
`endif

module props (input clk);
  (* anyseq *) wire rst;
  (* anyseq *) wire [31:0] a_addr, b_addr, f_rdata;
  (* anyseq *) wire a_rden, a_line, a_adv, b_rden, b_line, b_adv, f_ready;
  (* anyseq *) wire [95:0] f_rdata_x;
  wire a_ready, b_ready, o_rden, o_line, o_adv;
  wire [31:0] a_rdata, b_rdata, o_addr;
  wire [95:0] a_rdata_x, b_rdata_x;
  wire [1:0] d_owner; wire d_last_a;

  flash_arbiter dut (.i_clk(clk), .i_rst(rst),
    .i_a_addr(a_addr), .i_a_rden(a_rden), .i_a_line(a_line), .i_a_advance(a_adv), .o_a_ready(a_ready), .o_a_rdata(a_rdata), .o_a_rdata_x(a_rdata_x),
    .i_b_addr(b_addr), .i_b_rden(b_rden), .i_b_line(b_line), .i_b_advance(b_adv), .o_b_ready(b_ready), .o_b_rdata(b_rdata), .o_b_rdata_x(b_rdata_x),
    .o_addr(o_addr), .o_rden(o_rden), .o_line(o_line), .o_advance(o_adv), .i_ready(f_ready), .i_rdata(f_rdata), .i_rdata_x(f_rdata_x),
    .dbg_owner(d_owner), .dbg_last_a(d_last_a));

  reg f_past_valid = 0;
  reg p_a_rden = 0, p_b_rden = 0, p_a_adv = 0, p_b_adv = 0, p_a_ready = 0, p_b_ready = 0;
  reg [31:0] p_a_addr = 0, p_b_addr = 0;
  reg p_a_line = 0, p_b_line = 0;
  reg [3:0] f_wait = 0;
  reg [5:0] a_wait = 0, b_wait = 0;
  always @(posedge clk) begin
    f_past_valid <= 1;
    p_a_rden <= a_rden; p_b_rden <= b_rden; p_a_adv <= a_adv; p_b_adv <= b_adv;
    p_a_ready <= a_ready; p_b_ready <= b_ready;
    p_a_addr <= a_addr; p_b_addr <= b_addr; p_a_line <= a_line; p_b_line <= b_line;
    f_wait <= (o_rden && !f_ready) ? f_wait + 1 : 0;
    a_wait <= (a_rden && !a_ready) ? a_wait + 1 : 0;
    b_wait <= (b_rden && !b_ready) ? b_wait + 1 : 0;
  end

  // ---- o ambiente ----
  // um clock de reset no início
  always @* if (!f_past_valid) assume (rst);
  always @* if (f_past_valid) assume (!rst);
  // um mestre mantém o pedido e o endereço até ser atendido, e consome a resposta no ciclo em que ela chega
  always @* begin
    assume (a_adv == (a_rden && a_ready));
    assume (b_adv == (b_rden && b_ready));
  end
  always @(posedge clk) if (f_past_valid) begin
    if (p_a_rden && !p_a_adv) assume (a_rden && a_addr == p_a_addr && a_line == p_a_line);
    if (p_b_rden && !p_b_adv) assume (b_rden && b_addr == p_b_addr && b_line == p_b_line);
  end
  // a flash só responde a um pedido que está ativo, e responde em até K ciclos
  always @* begin
    if (f_ready) assume (o_rden);
    assume (!(f_wait == `K && o_rden));
  end

  // ---- invariantes e propriedades ----
  always @* if (f_past_valid) begin
    // o estado do dono é um dos três valores
    assert (d_owner != 2'd3);
    // 1. Exclusão: nunca os dois mestres recebem a resposta ao mesmo tempo.
    assert (!(a_ready && b_ready));
    // 2. Só o dono recebe a resposta, e só o dono dirige o canal da flash.
    if (a_ready) assert (d_owner == 2'd1 && f_ready);
    if (b_ready) assert (d_owner == 2'd2 && f_ready);
    if (d_owner == 2'd1) assert (o_addr == a_addr && o_rden == a_rden && o_line == a_line && o_adv == a_adv);
    if (d_owner == 2'd2) assert (o_addr == b_addr && o_rden == b_rden && o_line == b_line && o_adv == b_adv);
    if (d_owner == 2'd0) assert (!o_rden && !o_adv && !a_ready && !b_ready);
    // 3. O dado da flash chega inteiro aos dois mestres.
    assert (a_rdata == f_rdata && b_rdata == f_rdata && a_rdata_x == f_rdata_x && b_rdata_x == f_rdata_x);
  end

`ifdef FAIRNESS
  // 4. Todo pedido é atendido em até N ciclos, qualquer que seja o outro mestre (sem inanição).
  always @* if (f_past_valid) begin
    assert (a_wait <= `N);
    assert (b_wait <= `N);
  end
`endif

`ifdef COVER
  always @(posedge clk) if (f_past_valid) begin
    cover (a_ready && a_rden);
    cover (b_ready && b_rden);
    cover (a_ready && b_rden);
    cover (b_ready && a_rden);
    cover (d_owner == 2'd0 && a_rden && b_rden);
  end
`endif
endmodule
