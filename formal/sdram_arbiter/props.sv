// Properties of sdram_arbiter, checked on the Verilog netlist that GHDL synthesizes from the VHDL.
// Only the ports and a few exposed registers (dbg_*, added to a copy of the netlist) are used.
`ifndef K
`define K 4      // the controller answers within K clocks of a request
`endif
`ifndef W
`define W 14     // an accepted request is answered within W clocks (14 is the smallest bound that holds)
`endif

module props (input clk);
  (* anyseq *) wire rst;
  (* anyseq *) wire a_req_tog, a_we; (* anyseq *) wire [23:0] a_addr; (* anyseq *) wire [31:0] a_wdata; (* anyseq *) wire [3:0] a_be;
  (* anyseq *) wire b_req_tog, b_we; (* anyseq *) wire [23:0] b_addr; (* anyseq *) wire [31:0] b_wdata; (* anyseq *) wire [3:0] b_be;
  (* anyseq *) wire c_ack_tog;       (* anyseq *) wire [31:0] c_rdata;
  (* anyseq *) wire a_line; (* anyseq *) wire [95:0] a_wdata_x, c_rdata_x; (* anyseq *) wire [11:0] a_be_x;   // the line words travel with the request, untouched
  wire [95:0] a_rdata_x, c_wdata_x; wire [11:0] c_be_x; wire c_line;
  wire a_ack_tog, b_ack_tog, c_req_tog, c_we;
  wire d_st, d_gb, d_lb, d_atl; wire [1:0] d_as;   // internal registers, exposed in the verification copy of the netlist
  wire [31:0] a_rdata, b_rdata, c_wdata; wire [23:0] c_addr; wire [3:0] c_be;

  sdram_arbiter dut (.clk(clk), .rst(rst),
    .a_req_tog(a_req_tog), .a_ack_tog(a_ack_tog), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata), .a_be(a_be), .a_rdata(a_rdata),
    .b_req_tog(b_req_tog), .b_ack_tog(b_ack_tog), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata), .b_be(b_be), .b_rdata(b_rdata),
    .c_req_tog(c_req_tog), .c_ack_tog(c_ack_tog), .c_we(c_we), .c_addr(c_addr), .c_wdata(c_wdata), .c_be(c_be), .c_rdata(c_rdata),
    .a_line(a_line), .a_wdata_x(a_wdata_x), .a_be_x(a_be_x), .a_rdata_x(a_rdata_x),
    .c_line(c_line), .c_wdata_x(c_wdata_x), .c_be_x(c_be_x), .c_rdata_x(c_rdata_x),
    .dbg_st(d_st), .dbg_grant_b(d_gb), .dbg_last_b(d_lb), .dbg_a_tog_l(d_atl), .dbg_a_s(d_as));

  reg f_past_valid = 0;
  reg p_a_req_tog = 0, p_a_ack_tog = 0, p_a_we = 0, p_b_req_tog = 0, p_b_ack_tog = 0, p_b_we = 0;
  reg p_c_req_tog = 0, p_c_ack_tog = 0, p_c_we = 0;
  reg [23:0] p_a_addr = 0, p_b_addr = 0, p_c_addr = 0;
  reg [31:0] p_a_wdata = 0, p_b_wdata = 0, p_c_wdata = 0, p_a_rdata = 0, p_b_rdata = 0, p_c_rdata = 0;
  reg [3:0] p_a_be = 0, p_b_be = 0, p_c_be = 0;
  reg [1:0] sh_a = 0;                  // the two-flop synchronizer of master A, as the arbiter sees it
  reg [5:0] c_wait = 0, a_wait = 0, b_wait = 0;

  wire a_pend = sh_a[1] != a_ack_tog;  // A request the arbiter has seen and not answered
  wire b_pend = b_req_tog != b_ack_tog;
  reg p_a_pend = 0, p_b_pend = 0;
  wire c_pend = c_req_tog != c_ack_tog;
  wire a_flip = a_ack_tog != p_a_ack_tog, b_flip = b_ack_tog != p_b_ack_tog, grant = c_req_tog != p_c_req_tog;
  wire grant_word_a = c_we == p_a_we && c_addr == p_a_addr && c_wdata == p_a_wdata && c_be == p_a_be;
  wire grant_word_b = c_we == p_b_we && c_addr == p_b_addr && c_wdata == p_b_wdata && c_be == p_b_be;

  always @(posedge clk) begin
    f_past_valid <= 1;
    p_a_req_tog <= a_req_tog; p_a_ack_tog <= a_ack_tog; p_a_we <= a_we; p_a_addr <= a_addr; p_a_wdata <= a_wdata; p_a_be <= a_be; p_a_rdata <= a_rdata;
    p_b_req_tog <= b_req_tog; p_b_ack_tog <= b_ack_tog; p_b_we <= b_we; p_b_addr <= b_addr; p_b_wdata <= b_wdata; p_b_be <= b_be; p_b_rdata <= b_rdata;
    p_c_req_tog <= c_req_tog; p_c_ack_tog <= c_ack_tog; p_c_we <= c_we; p_c_addr <= c_addr; p_c_wdata <= c_wdata; p_c_be <= c_be; p_c_rdata <= c_rdata;
    sh_a <= rst ? 2'b00 : {sh_a[0], a_req_tog};
    p_a_pend <= a_pend; p_b_pend <= b_pend;
    c_wait <= c_pend ? c_wait + 1 : 0;
    a_wait <= (a_req_tog != a_ack_tog) ? a_wait + 1 : 0;
    b_wait <= (b_req_tog != b_ack_tog) ? b_wait + 1 : 0;
  end

  // ---- the environment ----
  // one reset clock at the start, with every toggle at its reset value
  always @* if (!f_past_valid) assume(rst && !a_req_tog && !b_req_tog && !c_ack_tog);
  always @* if (f_past_valid) assume(!rst);
  // a master flips its toggle only when the previous request was answered, and holds the buses until then
  always @(posedge clk) if (f_past_valid) begin
    if (a_req_tog != p_a_req_tog) assume(p_a_req_tog == p_a_ack_tog);
    if (b_req_tog != p_b_req_tog) assume(p_b_req_tog == p_b_ack_tog);
    if (p_a_req_tog != p_a_ack_tog) assume(a_req_tog == p_a_req_tog && a_we == p_a_we && a_addr == p_a_addr && a_wdata == p_a_wdata && a_be == p_a_be);
    if (p_b_req_tog != p_b_ack_tog) assume(b_req_tog == p_b_req_tog && b_we == p_b_we && b_addr == p_b_addr && b_wdata == p_b_wdata && b_be == p_b_be);
    // the controller answers only a pending request, with the toggle of that request, within K clocks
    if (c_ack_tog != p_c_ack_tog) assume(p_c_req_tog != p_c_ack_tog && c_ack_tog == p_c_req_tog);
  end
  always @* assume(!(c_wait == `K && c_pend));

  // ---- invariants of the arbiter state (strengthen the induction) ----
  always @* if (f_past_valid) begin
    // idle: no request toward the controller; a request toward the controller means busy
    if (!d_st) assert(c_req_tog == c_ack_tog);
    if (c_req_tog != c_ack_tog) assert(d_st);
    // the synchronizer of A has settled on the request whenever it differs from the answer
    if (d_as[1] != a_ack_tog) assert(a_req_tog == d_as[1]);
    if (a_req_tog == a_ack_tog) assert(d_as == {2{a_ack_tog}});
    // serving A: the latched toggle is the pending request; serving B: B is pending
    if (d_st && !d_gb) assert(d_atl != a_ack_tog && d_atl == a_req_tog);
    if (d_st && d_gb) assert(b_req_tog != b_ack_tog);
  end

  // ---- safety ----
  always @(posedge clk) if (f_past_valid) begin
    // one request at a time toward the controller, and the buses hold while it is pending
    if (grant) assert(p_c_req_tog == p_c_ack_tog);
    if (p_c_req_tog != p_c_ack_tog) assert(c_req_tog == p_c_req_tog && c_we == p_c_we && c_addr == p_c_addr && c_wdata == p_c_wdata && c_be == p_c_be);
    // a grant carries the word of a master that was waiting
    if (grant) assert((p_a_pend && grant_word_a) || (p_b_pend && grant_word_b));
    // an answer goes to a master that was waiting, once, with the toggle of its request
    if (a_flip) assert(p_a_pend && a_ack_tog == a_req_tog);
    if (b_flip) assert(p_b_pend && b_ack_tog == b_req_tog);
    if (a_flip || b_flip) assert(p_c_req_tog == p_c_ack_tog);
    assert(!(a_flip && b_flip));
    // the read data of a master is the one the controller returned, and changes only with its answer
    if (a_flip) assert(a_rdata == p_c_rdata);
    if (b_flip) assert(b_rdata == p_c_rdata);
    if (a_rdata != p_a_rdata) assert(a_flip);
    if (b_rdata != p_b_rdata) assert(b_flip);
  end

`ifdef FAIRNESS
  // ---- bounded wait: with a controller that answers within K clocks, a request is answered within W ----
  always @* begin
    assert(a_wait <= `W);
    assert(b_wait <= `W);
  end
`endif

`ifdef COVER
  always @(posedge clk) if (f_past_valid) begin
    cover(grant && p_a_pend && !p_b_pend);
    cover(grant && p_b_pend && !p_a_pend);
    cover(grant && p_a_pend && p_b_pend && grant_word_b && !grant_word_a);
    cover(a_flip); cover(b_flip);
    cover(a_flip && p_b_pend);          // A answered while B waits
    cover(b_flip && p_a_pend);          // B answered while A waits
  end
`endif
endmodule
