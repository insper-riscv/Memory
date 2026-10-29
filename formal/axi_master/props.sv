// Properties of axi_master_bridge, checked on the Verilog netlist GHDL synthesizes from the VHDL.
// The core and the AXI4 slave are free inputs held to their contracts by assumptions; the assertions
// are what the bridge itself must guarantee. A few registers (dbg_*, added to a copy of the netlist)
// are exposed for the invariants that make the proof inductive.
`ifndef K
`define K 3      // the slave accepts, answers and gives each beat within K clocks (liveness only)
`endif
`ifndef W
`define W 20     // an access is done within W clocks of reaching the port
`endif

module props (input clk);
  (* anyseq *) wire rst;
  // core side
  (* anyseq *) wire [31:0] addr, wdata; (* anyseq *) wire [3:0] byteena;
  (* anyseq *) wire rden, wren, mem_advance, line;
  (* anyseq *) wire [95:0] wdata_x; (* anyseq *) wire [11:0] byteena_x;
  // AXI side, driven by the slave
  (* anyseq *) wire awready, wready, arready, bvalid, rvalid, rlast_s;
  (* anyseq *) wire [1:0] bresp, rresp; (* anyseq *) wire [31:0] rdata_s;

  wire [1:0] d_st, d_beat, d_last; wire d_awv, d_wv, d_arv, d_we;
  wire [95:0] d_wdx; wire [11:0] d_bex;
  wire ready, err; wire [31:0] rdata; wire [95:0] rdata_x;
  wire awvalid, wvalid, bready, arvalid, rready, wlast;
  wire [31:0] awaddr, wdata_m, araddr; wire [2:0] awprot, arprot, awsize, arsize; wire [3:0] wstrb;
  wire [7:0] awlen, arlen; wire [1:0] awburst, arburst;

  axi_master_bridge dut (.i_clk(clk), .i_rst(rst),
    .i_addr(addr), .i_wdata(wdata), .i_byteena(byteena), .i_rden(rden), .i_wren(wren), .i_mem_advance(mem_advance),
    .o_ready(ready), .o_rdata(rdata), .i_line(line), .i_wdata_x(wdata_x), .i_byteena_x(byteena_x), .o_rdata_x(rdata_x), .o_err(err),
    .o_m_awvalid(awvalid), .i_m_awready(awready), .o_m_awaddr(awaddr), .o_m_awlen(awlen), .o_m_awsize(awsize), .o_m_awburst(awburst), .o_m_awprot(awprot),
    .o_m_wvalid(wvalid), .i_m_wready(wready), .o_m_wdata(wdata_m), .o_m_wstrb(wstrb), .o_m_wlast(wlast),
    .i_m_bvalid(bvalid), .o_m_bready(bready), .i_m_bresp(bresp),
    .o_m_arvalid(arvalid), .i_m_arready(arready), .o_m_araddr(araddr), .o_m_arlen(arlen), .o_m_arsize(arsize), .o_m_arburst(arburst), .o_m_arprot(arprot),
    .i_m_rvalid(rvalid), .o_m_rready(rready), .i_m_rdata(rdata_s), .i_m_rresp(rresp), .i_m_rlast(rlast_s),
    .dbg_st(d_st), .dbg_awv(d_awv), .dbg_wv(d_wv), .dbg_arv(d_arv), .dbg_we(d_we),
    .dbg_beat(d_beat), .dbg_last(d_last), .dbg_wdx(d_wdx), .dbg_bex(d_bex));

  reg f_past_valid = 0;
  always @(posedge clk) f_past_valid <= 1;
  always @* if (!f_past_valid) assume(rst);

  // ---- the previous clock ----
  reg p_rst = 1, p_rden = 0, p_wren = 0, p_mem_advance = 0, p_ready = 0, p_line = 0;
  reg [31:0] p_addr = 0, p_wdata = 0, p_rdata = 0; reg [3:0] p_byteena = 0;
  reg [95:0] p_wdata_x = 0, p_rdata_x = 0; reg [11:0] p_byteena_x = 0;
  reg p_awvalid = 0, p_wvalid = 0, p_arvalid = 0, p_awready = 0, p_wready = 0, p_arready = 0, p_wlast = 0;
  reg p_bvalid = 0, p_bready = 0, p_rvalid = 0, p_rready = 0, p_rlast_s = 0;
  reg [31:0] p_awaddr = 0, p_araddr = 0, p_wdata_m = 0, p_rdata_s = 0; reg [3:0] p_wstrb = 0;
  reg [2:0] p_awprot = 0, p_arprot = 0; reg [1:0] p_bresp = 0, p_rresp = 0, p_beat = 0;
  always @(posedge clk) begin
    p_rst <= rst; p_rden <= rden; p_wren <= wren; p_mem_advance <= mem_advance; p_ready <= ready; p_line <= line;
    p_addr <= addr; p_wdata <= wdata; p_byteena <= byteena; p_rdata <= rdata;
    p_wdata_x <= wdata_x; p_byteena_x <= byteena_x; p_rdata_x <= rdata_x;
    p_awvalid <= awvalid; p_wvalid <= wvalid; p_arvalid <= arvalid; p_wlast <= wlast;
    p_awready <= awready; p_wready <= wready; p_arready <= arready;
    p_bvalid <= bvalid; p_bready <= bready; p_rvalid <= rvalid; p_rready <= rready; p_rlast_s <= rlast_s;
    p_awaddr <= awaddr; p_araddr <= araddr; p_wdata_m <= wdata_m; p_wstrb <= wstrb;
    p_awprot <= awprot; p_arprot <= arprot; p_bresp <= bresp; p_rresp <= rresp; p_rdata_s <= rdata_s;
    p_beat <= d_beat;
  end

  wire aw_hs = awvalid && awready, w_hs = wvalid && wready, ar_hs = arvalid && arready;
  wire b_hs = bvalid && bready, r_hs = rvalid && rready;

  // what the slave has been given and not yet answered: the whole write (AW and every beat of W, the
  // last one with wlast) or the read request; and the beats of R already taken
  reg aw_seen = 0, w_seen = 0, ar_seen = 0;
  reg [1:0] r_cnt = 0;                  // beats of R taken so far in this read
  reg [7:0] ar_len_l = 0;               // the length the read asked for
  always @(posedge clk) begin
    if (rst) begin aw_seen <= 0; w_seen <= 0; ar_seen <= 0; r_cnt <= 0; end
    else begin
      if (aw_hs) aw_seen <= 1;
      if (w_hs && wlast) w_seen <= 1;
      if (ar_hs) begin ar_seen <= 1; r_cnt <= 0; ar_len_l <= arlen; end
      if (b_hs) begin aw_seen <= 0; w_seen <= 0; end
      if (r_hs) begin if (rlast_s) ar_seen <= 0; else r_cnt <= r_cnt + 1; end
    end
  end

  // ---- the core's contract: the access sits on the port until the pipeline moves ----
  wire active = rden || wren, p_active = p_rden || p_wren;
  always @* assume(!(rden && wren));
  always @(posedge clk) if (f_past_valid && !p_rst && p_active && !p_mem_advance)
    assume(rden == p_rden && wren == p_wren && addr == p_addr && wdata == p_wdata && byteena == p_byteena
           && line == p_line && wdata_x == p_wdata_x && byteena_x == p_byteena_x);

  // ---- the AXI4 slave's contract ----
  // a response only after the whole request was accepted (in an earlier clock), one per request
  always @* if (bvalid) assume(aw_seen && w_seen);
  always @* if (rvalid) assume(ar_seen);
  // R: the last flag is on the last beat and on no other, and the beats never exceed the length asked
  always @* if (rvalid) assume(rlast_s == (r_cnt == ar_len_l[1:0]));
  always @* assume(ar_len_l == 0 || ar_len_l == 3);
  // a valid stays, with the same payload, until accepted
  always @(posedge clk) if (f_past_valid && !p_rst) begin
    if (p_bvalid && !p_bready) assume(bvalid && bresp == p_bresp);
    if (p_rvalid && !p_rready) assume(rvalid && rresp == p_rresp && rdata_s == p_rdata_s && rlast_s == p_rlast_s);
  end
  // nothing is valid across a reset of the slave side
  always @(posedge clk) if (f_past_valid && p_rst) assume(!bvalid && !rvalid);

`ifdef FAIRNESS
  reg [3:0] aw_w = 0, w_w = 0, ar_w = 0, b_w = 0, r_w = 0, mem_w = 0;
  always @(posedge clk) begin
    aw_w <= (awvalid && !awready) ? aw_w + 1 : 0;
    w_w  <= (wvalid && !wready)   ? w_w + 1  : 0;
    ar_w <= (arvalid && !arready) ? ar_w + 1 : 0;
    b_w  <= (aw_seen && w_seen && !bvalid) ? b_w + 1 : 0;
    r_w  <= (ar_seen && !rvalid) ? r_w + 1 : 0;
    mem_w <= (ready && !mem_advance) ? mem_w + 1 : 0;
  end
  always @* begin
    assume(aw_w < `K); assume(w_w < `K); assume(ar_w < `K); assume(b_w < `K); assume(r_w < `K);
    assume(mem_w < 1); // the core moves the pipeline the clock after ready
  end
`endif

  reg [95:0] cap_wdx = 0; reg [11:0] cap_bex = 0; reg cap_line = 0;
  wire p_active_w = p_rden || p_wren;
  always @(posedge clk) if (f_past_valid && p_active_w && (awvalid && !p_awvalid || arvalid && !p_arvalid)) begin
    cap_wdx <= p_wdata_x; cap_bex <= p_byteena_x; cap_line <= p_line;
  end

  // the copies as they are in this clock: the clock after the access starts they are still being taken
  wire start_w = awvalid && !p_awvalid || arvalid && !p_arvalid;
  wire [95:0] now_wdx = start_w ? p_wdata_x : cap_wdx;
  wire [11:0] now_bex = start_w ? p_byteena_x : cap_bex;
  wire now_line = start_w ? p_line : cap_line;

  // ---- invariants of the state (what makes the proof inductive) ----
  // st: 0 idle, 1 write, 2 read, 3 done
  always @* begin
    if (d_st == 0 || d_st == 3) assert(!d_awv && !d_wv && !d_arv);
    if (d_st == 1) assert(!d_arv);
    if (d_st == 2) assert(!d_awv && !d_wv);
    if (d_st == 3) assert(!rready && !bready);
    assert(awvalid == d_awv && wvalid == d_wv && arvalid == d_arv);
    assert(d_last == 0 || d_last == 3);
    assert(d_beat <= d_last);
    if (d_st == 1) assert(!ar_seen);
    if (d_st == 2) assert(!aw_seen && !w_seen);
    if (d_st == 1 && d_awv) assert(!aw_seen);
    if (d_st == 1 && !d_awv) assert(aw_seen);
    if (d_st == 1 && d_wv)  assert(!w_seen);
    if (d_st == 1 && !d_wv) assert(w_seen && d_beat == 0);
    if (d_st == 2 && d_arv)  assert(!ar_seen && d_beat == 0);
    if (d_st == 2 && !d_arv) assert(ar_seen);
    if (d_st == 2) assert(ar_len_l == 0 && d_last == 0 || ar_len_l == 3 && d_last == 3 || d_arv);
    if (d_st == 2 && !d_arv) assert(d_beat == r_cnt);
    if (d_st == 0 || d_st == 3) assert(!aw_seen && !w_seen && !ar_seen);
    // the words after the first are what the core gave, kept (for the beats of W still to go)
    if (d_st == 1) assert(d_wdx == now_wdx && d_bex == now_bex);
    if (d_st == 1 || d_st == 2) assert(d_last == (now_line ? 3 : 0));
  end

  // ---- what the bridge must guarantee ----
  always @(posedge clk) if (f_past_valid && !p_rst) begin
    // AXI: a valid is not withdrawn, and its payload does not change, until the ready
    if (p_awvalid && !p_awready) assert(awvalid && awaddr == p_awaddr && awprot == p_awprot);
    if (p_wvalid  && !p_wready)  assert(wvalid  && wdata_m == p_wdata_m && wstrb == p_wstrb && wlast == p_wlast);
    if (p_arvalid && !p_arready) assert(arvalid && araddr == p_araddr && arprot == p_arprot);
    // the request carries what the core had on the port when the access started
    if (awvalid && !p_awvalid) assert(p_wren && awaddr == {p_addr[31:2], 2'b00} && awlen == (p_line ? 3 : 0));
    if (wvalid  && !p_wvalid)  assert(p_wren && wdata_m == p_wdata && wstrb == p_byteena);
    if (arvalid && !p_arvalid) assert(p_rden && !p_wren && araddr == {p_addr[31:2], 2'b00} && arlen == (p_line ? 3 : 0));
    // each request is offered once per access: accepted, it is not offered again
    if (p_awvalid && p_awready) assert(!awvalid);
    if (p_arvalid && p_arready) assert(!arvalid);
    // the beats of W go in order, the last one with wlast, and then W stops
    if (p_wvalid && p_wready && !p_wlast) assert(wvalid && d_beat == p_beat + 1);
    if (p_wvalid && p_wready && p_wlast)  assert(!wvalid);
    // the core's contract: ready is a level until mem_advance, and rdata moves only then
    if (p_ready && !p_mem_advance) assert(ready);
    if (!p_mem_advance) assert(rdata == p_rdata && rdata_x == p_rdata_x);
  end
  always @* begin
    // one access at a time, a read and a write never overlap
    assert(!((awvalid || wvalid) && arvalid));
    // the burst is the one asked for: INCR, 4 bytes, one beat or four
    assert(awsize == 2 && arsize == 2 && awburst == 1 && arburst == 1);
    assert(awlen == 0 || awlen == 3); assert(arlen == 0 || arlen == 3);
    if (wvalid) assert(wlast == (d_beat == d_last));
    // a response is taken only after the request it answers was accepted
    if (bready) assert(!awvalid && !wvalid);
    if (rready) assert(!arvalid);
    // ready only with the request answered; nothing is on the bus then
    if (ready) assert(!awvalid && !wvalid && !arvalid && !bready && !rready);
    assert(awprot == 0 && arprot == 0);
    if (err) assert(ready);
  end
  always @* begin
    if (b_hs) assert(aw_seen && w_seen);
    if (r_hs) assert(ar_seen);
  end

`ifdef FAIRNESS
  reg [6:0] wait_c = 0;
  always @(posedge clk) wait_c <= (rst || ready || !active) ? 0 : wait_c + 1;
  always @* if (!rst) assert(wait_c < `W);
`endif

`ifdef COVER
  always @* begin
    cover(f_past_valid && p_rden && !p_line && ready);   // a word read completes
    cover(f_past_valid && p_rden && p_line && ready);    // a line read completes
    cover(f_past_valid && p_wren && !p_line && ready);   // a word write completes
    cover(f_past_valid && p_wren && p_line && ready);    // a line write completes
    cover(f_past_valid && wvalid && !awvalid);           // W still offered after AW was accepted
    cover(f_past_valid && awvalid && !wvalid);           // AW still offered after W was accepted
    cover(f_past_valid && err);                          // an error response reaches the core
  end
`endif
endmodule
