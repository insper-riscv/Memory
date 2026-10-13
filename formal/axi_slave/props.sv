// Properties of axi_slave_word_bridge, checked on the Verilog netlist GHDL synthesizes from the VHDL.
// The AXI4-Lite master and the memory behind the word port are free inputs held to their contracts by
// assumptions; the assertions are what the bridge itself must guarantee.
`ifndef K
`define K 3      // the master and the memory answer within K clocks (liveness only)
`endif
`ifndef W
`define W 12     // a request is answered within W clocks of being accepted
`endif

module props (input clk);
  (* anyseq *) wire rst;
  // AXI4-Lite master side
  (* anyseq *) wire awvalid, wvalid, bready, arvalid, rready;
  (* anyseq *) wire [31:0] awaddr, wdata_s, araddr; (* anyseq *) wire [3:0] wstrb;
  // the memory behind the word port
  (* anyseq *) wire mready; (* anyseq *) wire [31:0] mrdata;

  wire awready, wready, bvalid, arready, rvalid; wire [1:0] bresp, rresp; wire [31:0] rdata_s;
  wire [31:0] addr, wdata; wire [3:0] byteena; wire rden, wren, mem_advance;
  wire [1:0] d_st; wire d_aw, d_w, d_we;   // state registers, exposed in the verification copy of the netlist

  axi_slave_word_bridge dut (.clk(clk), .rst(rst),
    .s_awvalid(awvalid), .s_awready(awready), .s_awaddr(awaddr),
    .s_wvalid(wvalid), .s_wready(wready), .s_wdata(wdata_s), .s_wstrb(wstrb),
    .s_bvalid(bvalid), .s_bready(bready), .s_bresp(bresp),
    .s_arvalid(arvalid), .s_arready(arready), .s_araddr(araddr),
    .s_rvalid(rvalid), .s_rready(rready), .s_rdata(rdata_s), .s_rresp(rresp),
    .addr(addr), .wdata(wdata), .byteena(byteena), .rden(rden), .wren(wren),
    .mem_advance(mem_advance), .ready(mready), .rdata(mrdata),
    .dbg_st(d_st), .dbg_aw_got(d_aw), .dbg_w_got(d_w), .dbg_we(d_we));

  reg f_past_valid = 0;
  always @(posedge clk) f_past_valid <= 1;
  always @* if (!f_past_valid) assume(rst);

  // ---- the previous clock ----
  reg p_rst = 1, p_awvalid = 0, p_wvalid = 0, p_arvalid = 0, p_awready = 0, p_wready = 0, p_arready = 0;
  reg p_bvalid = 0, p_bready = 0, p_rvalid = 0, p_rready = 0, p_mready = 0, p_mem_advance = 0;
  reg p_rden = 0, p_wren = 0, p_active_i = 0;
  reg [31:0] p_awaddr = 0, p_araddr = 0, p_wdata_s = 0, p_rdata_s = 0, p_mrdata = 0, p_addr = 0, p_wdata = 0;
  reg [3:0] p_wstrb = 0, p_byteena = 0; reg [1:0] p_bresp = 0, p_rresp = 0;
  always @(posedge clk) begin
    p_rst <= rst; p_awvalid <= awvalid; p_wvalid <= wvalid; p_arvalid <= arvalid;
    p_awready <= awready; p_wready <= wready; p_arready <= arready;
    p_bvalid <= bvalid; p_bready <= bready; p_rvalid <= rvalid; p_rready <= rready;
    p_mready <= mready; p_mem_advance <= mem_advance; p_rden <= rden; p_wren <= wren; p_active_i <= rden || wren;
    p_awaddr <= awaddr; p_araddr <= araddr; p_wdata_s <= wdata_s; p_wstrb <= wstrb;
    p_rdata_s <= rdata_s; p_mrdata <= mrdata; p_addr <= addr; p_wdata <= wdata; p_byteena <= byteena;
    p_bresp <= bresp; p_rresp <= rresp;
  end

  wire aw_hs = awvalid && awready, w_hs = wvalid && wready, ar_hs = arvalid && arready;
  wire b_hs = bvalid && bready, r_hs = rvalid && rready;

  // what the bridge accepted and has not answered, with the payload it must pass on
  reg aw_seen = 0, w_seen = 0, ar_seen = 0;
  reg [31:0] cap_aw = 0, cap_wd = 0, cap_ar = 0; reg [3:0] cap_ws = 0;
  always @(posedge clk) begin
    if (rst) begin aw_seen <= 0; w_seen <= 0; ar_seen <= 0; end
    else begin
      if (aw_hs) begin aw_seen <= 1; cap_aw <= awaddr; end
      if (w_hs)  begin w_seen  <= 1; cap_wd <= wdata_s; cap_ws <= wstrb; end
      if (ar_hs) begin ar_seen <= 1; cap_ar <= araddr; end
      if (b_hs) begin aw_seen <= 0; w_seen <= 0; end
      if (r_hs) ar_seen <= 0;
    end
  end

  // ---- the AXI4-Lite master's contract: a valid stays, with its payload, until accepted ----
  always @(posedge clk) if (f_past_valid && !p_rst) begin
    if (p_awvalid && !p_awready) assume(awvalid && awaddr == p_awaddr);
    if (p_wvalid  && !p_wready)  assume(wvalid  && wdata_s == p_wdata_s && wstrb == p_wstrb);
    if (p_arvalid && !p_arready) assume(arvalid && araddr == p_araddr);
  end

  // ---- the memory's contract (the word contract of sdram_cpu_bridge) ----
  wire active = rden || wren;
  always @* if (mready) assume(active);                       // an answer only to an access
  always @(posedge clk) if (f_past_valid && !p_rst) begin
    if (p_mready && !p_mem_advance) assume(mready);          // ready is a level until mem_advance
    if (p_mem_advance) assume(!mready);                      // and the memory is free the clock after
    if (!p_mem_advance) assume(mrdata == p_mrdata);          // read data moves only on that edge
  end

`ifdef FAIRNESS
  // the memory answers within K clocks, and the master takes a response within K clocks
  reg [3:0] m_w = 0, b_w = 0, r_w = 0, a_w = 0;
  always @(posedge clk) begin
    m_w <= (active && !mready) ? m_w + 1 : 0;
    b_w <= (bvalid && !bready) ? b_w + 1 : 0;
    r_w <= (rvalid && !rready) ? r_w + 1 : 0;
  end
  always @* begin assume(m_w < `K); assume(b_w < `K); assume(r_w < `K); end
`endif

  // ---- invariants of the state (what makes the proof inductive) ----
  // st: 0 idle, 1 access, 2 advance, 3 response
  wire rd_seen_state = d_st != 0 && !d_we;
  always @* begin
    assert(aw_seen == d_aw && w_seen == d_w);
    assert(ar_seen == rd_seen_state);
    if (d_st != 0) begin
      if (d_we) assert(d_aw && d_w);
      else      assert(!d_aw && !d_w);
    end
    if (d_st == 0) assert(!ar_seen);
    // the payload on the word port is what was accepted
    if (aw_seen) assert(addr == cap_aw);
    if (w_seen)  assert(wdata == cap_wd && byteena == cap_ws);
    if (ar_seen) assert(addr == cap_ar && byteena == 4'hF);
  end

  // ---- what the bridge must guarantee ----
  always @(posedge clk) if (f_past_valid && !p_rst) begin
    // a response stays, with its payload, until taken
    if (p_bvalid && !p_bready) assert(bvalid && bresp == p_bresp);
    if (p_rvalid && !p_rready) assert(rvalid && rresp == p_rresp && rdata_s == p_rdata_s);
    // the access on the word port holds until the memory answers and the pipeline moves
    if (p_active_i && !p_mem_advance) assert(rden == p_rden && wren == p_wren && addr == p_addr
                                              && wdata == p_wdata && byteena == p_byteena);
    // mem_advance is a single pulse
    if (p_mem_advance) assert(!mem_advance);
  end
  always @* begin
    assert(!(rden && wren));
    // a write access only after the whole write request was accepted, with what was accepted
    if (wren) assert(aw_seen && w_seen && addr == cap_aw && wdata == cap_wd && byteena == cap_ws);
    // a read access only after the read request, at its address, for the whole word
    if (rden) assert(ar_seen && addr == cap_ar && byteena == 4'hF);
    // the memory is advanced only once it answered
    if (mem_advance) assert(mready && active);
    // a response only for an accepted request, and always OKAY
    if (bvalid) assert(aw_seen && w_seen);
    if (rvalid) assert(ar_seen);
    assert(bresp == 0 && rresp == 0);
    assert(!(bvalid && rvalid));
    // one transaction at a time: nothing new is accepted while one is in flight
    if (aw_seen) assert(!awready);
    if (w_seen)  assert(!wready);
    if (aw_seen || w_seen || ar_seen) assert(!arready);
    if (ar_seen) assert(!awready && !wready);
  end

`ifdef FAIRNESS
  // an accepted request is answered within W clocks
  reg [5:0] wait_c = 0;
  always @(posedge clk) wait_c <= (rst || !((aw_seen && w_seen) || ar_seen) || bvalid || rvalid) ? 0 : wait_c + 1;
  always @* if (!rst) assert(wait_c < `W);
`endif

`ifdef COVER
  always @* begin
    cover(f_past_valid && b_hs);                        // a write is answered
    cover(f_past_valid && r_hs);                        // a read is answered
    cover(f_past_valid && wvalid && w_hs && !aw_seen);  // W accepted before AW
    cover(f_past_valid && aw_hs && !w_seen);            // AW accepted before W
    cover(f_past_valid && arvalid && !arready && (awvalid || wvalid)); // a read waits for a write
  end
`endif
endmodule
