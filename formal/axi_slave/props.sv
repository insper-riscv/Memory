// Properties of axi_slave_word_bridge, checked on the Verilog netlist GHDL synthesizes from the VHDL.
// The AXI4 master and the memory behind the word port are free inputs held to their contracts by
// assumptions; the assertions are what the bridge itself must guarantee. The payload that reaches the
// memory is checked by the system tests against the chip model (AxiSdramSlave); here are the
// protocol: handshakes, beats, the last flag, one transaction at a time, and that a request the
// bridge does not serve never reaches the memory.
`ifndef K
`define K 3      // the master and the memory answer within K clocks (liveness only)
`endif
`ifndef W
`define W 40     // a transaction of up to four beats is answered within W clocks of being accepted
`endif

module props (input clk);
  (* anyseq *) wire rst;
  // AXI4 master side
  (* anyseq *) wire awvalid, wvalid, bready, arvalid, rready, wlast;
  (* anyseq *) wire [31:0] awaddr, wdata_s, araddr; (* anyseq *) wire [3:0] wstrb;
  (* anyseq *) wire [7:0] awlen, arlen; (* anyseq *) wire [2:0] awsize, arsize; (* anyseq *) wire [1:0] awburst, arburst;
  // the memory behind the word port
  (* anyseq *) wire mready; (* anyseq *) wire [31:0] mrdata; (* anyseq *) wire [95:0] mrdata_x;

  wire awready, wready, bvalid, arready, rvalid, rlast_o; wire [1:0] bresp, rresp; wire [31:0] rdata_s;
  wire [31:0] addr, wdata; wire [3:0] byteena; wire rden, wren, mem_advance, line;
  wire [95:0] wdata_x; wire [11:0] byteena_x;
  wire [2:0] d_st; wire d_we, d_bad, d_fast; wire [1:0] d_k; wire [7:0] d_left;

  axi_slave_word_bridge dut (.i_clk(clk), .i_rst(rst),
    .i_s_awvalid(awvalid), .o_s_awready(awready), .i_s_awaddr(awaddr), .i_s_awlen(awlen), .i_s_awsize(awsize), .i_s_awburst(awburst),
    .i_s_wvalid(wvalid), .o_s_wready(wready), .i_s_wdata(wdata_s), .i_s_wstrb(wstrb), .i_s_wlast(wlast),
    .o_s_bvalid(bvalid), .i_s_bready(bready), .o_s_bresp(bresp),
    .i_s_arvalid(arvalid), .o_s_arready(arready), .i_s_araddr(araddr), .i_s_arlen(arlen), .i_s_arsize(arsize), .i_s_arburst(arburst),
    .o_s_rvalid(rvalid), .i_s_rready(rready), .o_s_rdata(rdata_s), .o_s_rresp(rresp), .o_s_rlast(rlast_o),
    .o_addr(addr), .o_wdata(wdata), .o_byteena(byteena), .o_rden(rden), .o_wren(wren),
    .o_mem_advance(mem_advance), .i_ready(mready), .i_rdata(mrdata),
    .o_line(line), .o_wdata_x(wdata_x), .o_byteena_x(byteena_x), .i_rdata_x(mrdata_x),
    .dbg_st(d_st), .dbg_we(d_we), .dbg_bad(d_bad), .dbg_fast(d_fast), .dbg_k(d_k), .dbg_left(d_left));

  reg f_past_valid = 0;
  always @(posedge clk) f_past_valid <= 1;
  always @* if (!f_past_valid) assume(rst);

  // ---- the previous clock ----
  reg p_rst = 1, p_awvalid = 0, p_wvalid = 0, p_arvalid = 0, p_awready = 0, p_wready = 0, p_arready = 0, p_wlast = 0;
  reg p_bvalid = 0, p_bready = 0, p_rvalid = 0, p_rready = 0, p_mready = 0, p_mem_advance = 0, p_rlast_o = 0;
  reg p_rden = 0, p_wren = 0, p_active_i = 0, p_line = 0;
  reg [31:0] p_awaddr = 0, p_araddr = 0, p_wdata_s = 0, p_rdata_s = 0, p_mrdata = 0, p_addr = 0, p_wdata = 0;
  reg [95:0] p_mrdata_x = 0, p_wdata_x = 0;
  reg [3:0] p_wstrb = 0, p_byteena = 0; reg [11:0] p_byteena_x = 0; reg [1:0] p_bresp = 0, p_rresp = 0;
  reg [7:0] p_awlen = 0, p_arlen = 0; reg [2:0] p_awsize = 0, p_arsize = 0; reg [1:0] p_awburst = 0, p_arburst = 0;
  always @(posedge clk) begin
    p_rst <= rst; p_awvalid <= awvalid; p_wvalid <= wvalid; p_arvalid <= arvalid; p_wlast <= wlast;
    p_awready <= awready; p_wready <= wready; p_arready <= arready;
    p_bvalid <= bvalid; p_bready <= bready; p_rvalid <= rvalid; p_rready <= rready; p_rlast_o <= rlast_o;
    p_mready <= mready; p_mem_advance <= mem_advance; p_rden <= rden; p_wren <= wren; p_active_i <= rden || wren; p_line <= line;
    p_awaddr <= awaddr; p_araddr <= araddr; p_wdata_s <= wdata_s; p_wstrb <= wstrb;
    p_rdata_s <= rdata_s; p_mrdata <= mrdata; p_mrdata_x <= mrdata_x; p_addr <= addr; p_wdata <= wdata; p_wdata_x <= wdata_x;
    p_byteena <= byteena; p_byteena_x <= byteena_x; p_bresp <= bresp; p_rresp <= rresp;
    p_awlen <= awlen; p_arlen <= arlen; p_awsize <= awsize; p_arsize <= arsize; p_awburst <= awburst; p_arburst <= arburst;
  end

  wire aw_hs = awvalid && awready, w_hs = wvalid && wready, ar_hs = arvalid && arready;
  wire b_hs = bvalid && bready, r_hs = rvalid && rready;

  // a request the bridge serves: INCR, 4 bytes, aligned to 4 bytes
  function bad_of (input [2:0] size, input [1:0] burst, input [31:0] a);
    bad_of = size != 3'd2 || burst != 2'd1 || a[1:0] != 2'b00;
  endfunction

  // the transaction in flight, with what it asked for
  reg aw_seen = 0, ar_seen = 0, w_done = 0, req_bad = 0;
  reg [7:0] req_len = 0;
  reg [8:0] w_cnt = 0, r_cnt = 0;       // beats of W taken, beats of R given
  always @(posedge clk) begin
    if (rst) begin aw_seen <= 0; ar_seen <= 0; w_done <= 0; w_cnt <= 0; r_cnt <= 0; end
    else begin
      if (aw_hs) begin aw_seen <= 1; req_bad <= bad_of(awsize, awburst, awaddr); req_len <= awlen; w_cnt <= 0; end
      if (ar_hs) begin ar_seen <= 1; req_bad <= bad_of(arsize, arburst, araddr); req_len <= arlen; r_cnt <= 0; end
      if (w_hs) begin w_cnt <= w_cnt + 1; if (wlast) w_done <= 1; end
      if (r_hs) begin if (rlast_o) begin ar_seen <= 0; r_cnt <= 0; end else r_cnt <= r_cnt + 1; end
      if (b_hs) begin aw_seen <= 0; w_done <= 0; w_cnt <= 0; end
    end
  end

  // ---- the AXI4 master's contract: a valid stays, with its payload, until accepted; wlast ends the burst ----
  always @(posedge clk) if (f_past_valid && !p_rst) begin
    if (p_awvalid && !p_awready) assume(awvalid && awaddr == p_awaddr && awlen == p_awlen && awsize == p_awsize && awburst == p_awburst);
    if (p_wvalid  && !p_wready)  assume(wvalid  && wdata_s == p_wdata_s && wstrb == p_wstrb && wlast == p_wlast);
    if (p_arvalid && !p_arready) assume(arvalid && araddr == p_araddr && arlen == p_arlen && arsize == p_arsize && arburst == p_arburst);
  end
  // W only for a write whose AW was offered, and wlast on the beat that makes awlen + 1 beats
  always @* if (wvalid && !aw_seen) assume(awvalid);
  always @* if (wvalid) assume(wlast == (w_cnt[7:0] == (aw_seen ? req_len : awlen)));
  // a write is not started while another write or read is in flight, and a read waits for its answer
  always @* if (awvalid) assume(!aw_seen || b_hs);
  // lengths of 1 to 4 beats keep the proof small (the slave counts longer ones the same way)
  always @* begin assume(awlen <= 8'd3); assume(arlen <= 8'd3); end

  // ---- the memory's contract (the word contract of sdram_cpu_bridge) ----
  wire active = rden || wren;
  always @* if (mready) assume(active);
  always @(posedge clk) if (f_past_valid && !p_rst) begin
    if (p_mready && !p_mem_advance) assume(mready);
    if (p_mem_advance) assume(!mready);
    if (!p_mem_advance) assume(mrdata == p_mrdata && mrdata_x == p_mrdata_x);
  end

`ifdef FAIRNESS
  reg [3:0] m_w = 0, b_w = 0, r_w = 0, w_w = 0;
  always @(posedge clk) begin
    m_w <= (active && !mready) ? m_w + 1 : 0;
    b_w <= (bvalid && !bready) ? b_w + 1 : 0;
    r_w <= (rvalid && !rready) ? r_w + 1 : 0;
    w_w <= (aw_seen && !w_done && !wvalid) ? w_w + 1 : 0;
  end
  always @* begin assume(m_w < `K); assume(b_w < `K); assume(r_w < `K); assume(w_w < `K); end
`endif

  // ---- invariants of the state (what makes the proof inductive) ----
  // st: 0 idle, 1 beats of W, 2 access, 3 advance, 4 beat of R, 5 B
  always @* begin
    assert((d_st == 0) == !(aw_seen || ar_seen) || (d_st == 5 && 0));
    if (d_st != 0) assert(aw_seen || ar_seen);
    if (d_st == 1) assert(aw_seen && d_we);
    if (d_st == 5) assert(aw_seen && w_done);
    if (d_st == 4) assert(ar_seen);
    if (aw_seen) assert(d_we && d_bad == req_bad);
    if (ar_seen) assert(!d_we && d_bad == req_bad);
    if (d_st == 2 || d_st == 3) assert(!d_bad);
    if (d_fast) assert(!d_bad);
    if (d_st == 4 && d_fast) assert(d_k <= 3);
    // the counters of this file follow the state of the bridge
    if (aw_seen || ar_seen) assert(req_len <= 3 && d_left <= req_len);
    if (ar_seen) assert(d_fast ? (r_cnt == {7'b0, d_k}) : (r_cnt[7:0] + d_left == req_len));
    if (ar_seen) assert(r_cnt <= 3);
    if ((aw_seen || ar_seen) && d_fast) assert(req_len == 3);
    if (aw_seen && !d_bad && d_fast) begin
      if (d_st == 1) assert(w_cnt == {7'b0, d_k} && !w_done);
      if (d_st == 2 || d_st == 3 || d_st == 5) assert(w_cnt == 4 && w_done);
    end
    if (aw_seen && !d_bad && !d_fast) begin
      if (d_st == 1) assert(w_cnt[7:0] + d_left == req_len && !w_done);
      if (d_st == 2 || d_st == 3) assert(w_cnt[7:0] + d_left == req_len + 1);
    end
    if (aw_seen && d_bad && d_st == 1) assert(!w_done);
    if (d_st == 5) assert(w_done);
    if (!aw_seen) assert(!w_done && w_cnt == 0);
    if (!ar_seen) assert(r_cnt == 0);
    if (aw_seen) assert(w_cnt <= 4);
  end

  // ---- what the bridge must guarantee ----
  always @(posedge clk) if (f_past_valid && !p_rst) begin
    // a response stays, with its payload, until taken
    if (p_bvalid && !p_bready) assert(bvalid && bresp == p_bresp);
    if (p_rvalid && !p_rready) assert(rvalid && rresp == p_rresp && rdata_s == p_rdata_s && rlast_o == p_rlast_o);
    // the access on the word port holds until the memory answers and the pipeline moves
    if (p_active_i && !p_mem_advance) assert(rden == p_rden && wren == p_wren && addr == p_addr && line == p_line
                                              && wdata == p_wdata && byteena == p_byteena && wdata_x == p_wdata_x && byteena_x == p_byteena_x);
    // mem_advance is a single pulse
    if (p_mem_advance) assert(!mem_advance);
  end
  always @* begin
    assert(!(rden && wren));
    // a write access only after the AW and the beat(s) of W it needs were taken; a read after AR
    if (wren) assert(aw_seen && w_cnt != 0);
    if (wren && line) assert(w_cnt == 4 && req_len == 3);
    if (rden) assert(ar_seen);
    if (active && line) assert(req_len == 3 && addr[3:0] == 4'b0000);
    // a request that is not served never reaches the memory
    if (active) assert(!req_bad);
    // the memory is advanced only once it answered
    if (mem_advance) assert(mready && active);
    // a response only for a request whose beats are all in
    if (bvalid) assert(aw_seen && w_done);
    if (rvalid) assert(ar_seen);
    assert(!(bvalid && rvalid));
    // R: the last flag is on the last beat of the burst and on no other
    if (rvalid) assert(rlast_o == (r_cnt[7:0] == req_len));
    // always OKAY for what is served and SLVERR for what is not
    if (bvalid) assert(bresp == (req_bad ? 2'b10 : 2'b00));
    if (rvalid) assert(rresp == (req_bad ? 2'b10 : 2'b00));
    if (rvalid && req_bad) assert(rdata_s == 0);
    // one transaction at a time: nothing new is accepted while one is in flight
    if (aw_seen || ar_seen) assert(!awready && !arready);
    assert(!(aw_hs && ar_hs));
  end

`ifdef FAIRNESS
  reg [6:0] wait_c = 0;
  always @(posedge clk) wait_c <= (rst || !(aw_seen || ar_seen) || b_hs || (r_hs && rlast_o)) ? 0 : wait_c + 1;
  always @* if (!rst) assert(wait_c < `W);
`endif

`ifdef COVER
  always @* begin
    cover(f_past_valid && b_hs && !req_bad && req_len == 3);   // a four-beat write is answered
    cover(f_past_valid && r_hs && rlast_o && !req_bad && req_len == 3);  // a four-beat read ends
    cover(f_past_valid && b_hs && req_bad);                    // a refused write is answered
    cover(f_past_valid && r_hs && rlast_o && req_bad);         // a refused read ends
    cover(f_past_valid && b_hs && req_len == 1 && !req_bad);   // a two-beat write, word by word
    cover(f_past_valid && arvalid && !arready && awvalid);     // a read waits for a write
  end
`endif
endmodule
