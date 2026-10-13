// Properties of axil_master_bridge, checked on the Verilog netlist GHDL synthesizes from the VHDL.
// Only the ports are used. The core and the AXI4-Lite slave are free inputs held to their contracts
// by assumptions; the assertions are what the bridge itself must guarantee.
`ifndef K
`define K 3      // the slave accepts and answers within K clocks (liveness only)
`endif
`ifndef W
`define W 12     // an access is done within W clocks of reaching the port
`endif

module props (input clk);
  (* anyseq *) wire rst;
  // core side
  (* anyseq *) wire [31:0] addr, wdata; (* anyseq *) wire [3:0] byteena;
  (* anyseq *) wire rden, wren, mem_advance;
  // AXI side, driven by the slave
  (* anyseq *) wire awready, wready, arready, bvalid, rvalid;
  (* anyseq *) wire [1:0] bresp, rresp; (* anyseq *) wire [31:0] rdata_s;

  wire [1:0] d_st; wire d_awv, d_wv, d_arv, d_we;   // state registers, exposed in the verification copy of the netlist
  wire ready, err; wire [31:0] rdata;
  wire awvalid, wvalid, bready, arvalid, rready;
  wire [31:0] awaddr, wdata_m, araddr; wire [2:0] awprot, arprot; wire [3:0] wstrb;

  axil_master_bridge dut (.clk(clk), .rst(rst),
    .addr(addr), .wdata(wdata), .byteena(byteena), .rden(rden), .wren(wren), .mem_advance(mem_advance),
    .ready(ready), .rdata(rdata), .err(err),
    .m_awvalid(awvalid), .m_awready(awready), .m_awaddr(awaddr), .m_awprot(awprot),
    .m_wvalid(wvalid), .m_wready(wready), .m_wdata(wdata_m), .m_wstrb(wstrb),
    .m_bvalid(bvalid), .m_bready(bready), .m_bresp(bresp),
    .m_arvalid(arvalid), .m_arready(arready), .m_araddr(araddr), .m_arprot(arprot),
    .m_rvalid(rvalid), .m_rready(rready), .m_rdata(rdata_s), .m_rresp(rresp),
    .dbg_st(d_st), .dbg_awv(d_awv), .dbg_wv(d_wv), .dbg_arv(d_arv), .dbg_we(d_we));

  reg f_past_valid = 0;
  always @(posedge clk) f_past_valid <= 1;
  always @* if (!f_past_valid) assume(rst);

  // ---- the previous clock ----
  reg p_rst = 1, p_rden = 0, p_wren = 0, p_mem_advance = 0, p_ready = 0;
  reg [31:0] p_addr = 0, p_wdata = 0, p_rdata = 0; reg [3:0] p_byteena = 0;
  reg p_awvalid = 0, p_wvalid = 0, p_arvalid = 0, p_awready = 0, p_wready = 0, p_arready = 0;
  reg p_bvalid = 0, p_bready = 0, p_rvalid = 0, p_rready = 0;
  reg [31:0] p_awaddr = 0, p_araddr = 0, p_wdata_m = 0, p_rdata_s = 0; reg [3:0] p_wstrb = 0;
  reg [2:0] p_awprot = 0, p_arprot = 0; reg [1:0] p_bresp = 0, p_rresp = 0;
  always @(posedge clk) begin
    p_rst <= rst; p_rden <= rden; p_wren <= wren; p_mem_advance <= mem_advance; p_ready <= ready;
    p_addr <= addr; p_wdata <= wdata; p_byteena <= byteena; p_rdata <= rdata;
    p_awvalid <= awvalid; p_wvalid <= wvalid; p_arvalid <= arvalid;
    p_awready <= awready; p_wready <= wready; p_arready <= arready;
    p_bvalid <= bvalid; p_bready <= bready; p_rvalid <= rvalid; p_rready <= rready;
    p_awaddr <= awaddr; p_araddr <= araddr; p_wdata_m <= wdata_m; p_wstrb <= wstrb;
    p_awprot <= awprot; p_arprot <= arprot; p_bresp <= bresp; p_rresp <= rresp; p_rdata_s <= rdata_s;
  end

  wire aw_hs = awvalid && awready, w_hs = wvalid && wready, ar_hs = arvalid && arready;
  wire b_hs = bvalid && bready, r_hs = rvalid && rready;

  // what the slave has been given and not yet answered
  reg aw_seen = 0, w_seen = 0, ar_seen = 0;
  always @(posedge clk) begin
    if (rst) begin aw_seen <= 0; w_seen <= 0; ar_seen <= 0; end
    else begin
      if (aw_hs) aw_seen <= 1;
      if (w_hs)  w_seen  <= 1;
      if (ar_hs) ar_seen <= 1;
      if (b_hs) begin aw_seen <= 0; w_seen <= 0; end
      if (r_hs) ar_seen <= 0;
    end
  end

  // ---- the core's contract: the access sits on the port until the pipeline moves ----
  wire active = rden || wren, p_active = p_rden || p_wren;
  always @* assume(!(rden && wren));
  always @(posedge clk) if (f_past_valid && !p_rst && p_active && !p_mem_advance)
    assume(rden == p_rden && wren == p_wren && addr == p_addr && wdata == p_wdata && byteena == p_byteena);

  // ---- the AXI4-Lite slave's contract ----
  // a response only after the whole request was accepted (in an earlier clock), one per request
  always @* if (bvalid) assume(aw_seen && w_seen);
  always @* if (rvalid) assume(ar_seen);
  // a valid stays, with the same payload, until accepted
  always @(posedge clk) if (f_past_valid && !p_rst) begin
    if (p_bvalid && !p_bready) assume(bvalid && bresp == p_bresp);
    if (p_rvalid && !p_rready) assume(rvalid && rresp == p_rresp && rdata_s == p_rdata_s);
  end
  // nothing is valid across a reset of the slave side: after reset the slave has no old response
  always @(posedge clk) if (f_past_valid && p_rst) assume(!bvalid && !rvalid);

`ifdef FAIRNESS
  // the slave accepts and answers within K clocks
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

  // ---- invariants of the state (what makes the proof inductive) ----
  // st: 0 idle, 1 write, 2 read, 3 done
  always @* begin
    if (d_st == 0 || d_st == 3) assert(!d_awv && !d_wv && !d_arv);
    if (d_st == 1) assert(!d_arv);
    if (d_st == 2) assert(!d_awv && !d_wv);
    if (d_st == 3) assert(!rready && !bready);
    assert(awvalid == d_awv && wvalid == d_wv && arvalid == d_arv);
    // what the slave was given matches the state
    if (d_st == 1) assert(!ar_seen);
    if (d_st == 2) assert(!aw_seen && !w_seen);
    if (d_st == 1 && d_awv) assert(!aw_seen);
    if (d_st == 1 && d_wv)  assert(!w_seen);
    if (d_st == 1 && !d_awv) assert(aw_seen);
    if (d_st == 1 && !d_wv)  assert(w_seen);
    if (d_st == 2 && d_arv)  assert(!ar_seen);
    if (d_st == 2 && !d_arv) assert(ar_seen);
    if (d_st == 0 || d_st == 3) assert(!aw_seen && !w_seen && !ar_seen);
  end

  // ---- what the bridge must guarantee ----
  always @(posedge clk) if (f_past_valid && !p_rst) begin
    // AXI: a valid is not withdrawn, and its payload does not change, until the ready
    if (p_awvalid && !p_awready) assert(awvalid && awaddr == p_awaddr && awprot == p_awprot);
    if (p_wvalid  && !p_wready)  assert(wvalid  && wdata_m == p_wdata_m && wstrb == p_wstrb);
    if (p_arvalid && !p_arready) assert(arvalid && araddr == p_araddr && arprot == p_arprot);
    // the request carries what the core had on the port when the access started
    if (awvalid && !p_awvalid) assert(p_wren && awaddr == p_addr);
    if (wvalid  && !p_wvalid)  assert(p_wren && wdata_m == p_wdata && wstrb == p_byteena);
    if (arvalid && !p_arvalid) assert(p_rden && !p_wren && araddr == p_addr);
    // each request is offered once per access: accepted, it is not offered again
    if (p_awvalid && p_awready) assert(!awvalid);
    if (p_wvalid  && p_wready)  assert(!wvalid);
    if (p_arvalid && p_arready) assert(!arvalid);
    // the core's contract: ready is a level until mem_advance, and rdata moves only then
    if (p_ready && !p_mem_advance) assert(ready);
    if (!p_mem_advance) assert(rdata == p_rdata);
  end
  always @* begin
    // one access at a time, a read and a write never overlap
    assert(!((awvalid || wvalid) && arvalid));
    // a response is taken only after the request it answers was accepted
    if (bready) assert(!awvalid && !wvalid);
    if (rready) assert(!arvalid);
    // ready only with the request answered; nothing is on the bus then
    if (ready) assert(!awvalid && !wvalid && !arvalid && !bready && !rready);
    assert(awprot == 0 && arprot == 0);
    if (err) assert(ready);
  end
  // a response handshake only ever happens in the state that waits for it
  always @* begin
    if (b_hs) assert(aw_seen && w_seen);
    if (r_hs) assert(ar_seen);
  end

`ifdef FAIRNESS
  // an access that reached the port is done within W clocks
  reg [5:0] wait_c = 0;
  always @(posedge clk) wait_c <= (rst || ready || !active) ? 0 : wait_c + 1;
  always @* if (!rst) assert(wait_c < `W);
`endif

`ifdef COVER
  always @* begin
    cover(f_past_valid && p_rden && ready);     // a read completes
    cover(f_past_valid && p_wren && ready);     // a write completes
    cover(f_past_valid && wvalid && !awvalid);  // W still offered after AW was accepted
    cover(f_past_valid && awvalid && !wvalid);  // AW still offered after W was accepted
    cover(f_past_valid && err);                 // an error response reaches the core
  end
`endif
endmodule
