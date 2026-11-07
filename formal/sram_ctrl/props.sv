// Propriedades do sram_ctrl, verificadas na netlist Verilog que o GHDL sintetiza do VHDL, com um chip de 64 bytes
// (32 meias palavras de 16 bits) e esperas curtas (a lógica é a mesma dos 2 MB e dos tempos da DE2-115). A configuração
// A usa um ciclo em cada fase; a B (-DCFG_B) usa 3 ciclos em cada fase de leitura e de escrita, para provar
// que o número de ciclos segue os generics. O cenário -DSC_READ liga só o pedido de leitura e -DSC_WRITE só o de escrita.
// O ambiente é livre (endereço, dado, habilita de bytes, dado do chip), preso ao contrato por suposições: o pedido fica
// estável até o avanço, o avanço só vem com o pronto, e só o primeiro ciclo tem reset. Uma meia palavra qualquer, mas
// constante, do pedido (wh) é vigiada: o habilita de bytes e o dado dela são os que o pino mostra quando ela é escrita,
// e o dado do pino na leitura dela é o que o núcleo recebe depois do avanço.
module props (input clk);
`ifdef CFG_B
  localparam integer NRD = 3, NWL = 3, NWH = 3;
`else
  localparam integer NRD = 1, NWL = 1, NWH = 1;
`endif
  localparam [2:0] S_IDLE = 0, S_RD = 1, S_WSEL = 2, S_WSETUP = 3, S_WLOW = 4, S_WHIGH = 5, S_DONE = 6;

  (* anyconst *) wire [2:0] wh;
  (* anyseq *) wire rst, advance, line;
  (* anyseq *) wire [31:0] addr, wdata;
  (* anyseq *) wire [3:0] byteena;
  (* anyseq *) wire [95:0] wdata_x;
  (* anyseq *) wire [11:0] byteena_x;
  (* anyseq *) wire [15:0] dq_in;
`ifdef SC_READ
  (* anyseq *) wire rden;
  wire wren = 1'b0;
`else
  wire rden = 1'b0;
  (* anyseq *) wire wren;
`endif

  wire ready, ce_n, oe_n, we_n, lb_n, ub_n, dq_oe;
  wire [31:0] rdata;
  wire [95:0] rdata_x;
  wire [19:0] sa;
  wire [15:0] sdq;
  wire [2:0] d_st;

  sram_ctrl dut (.i_clk(clk), .i_rst(rst), .i_addr(addr), .i_wdata(wdata), .i_byteena(byteena), .i_rden(rden), .i_wren(wren),
    .i_advance(advance), .o_ready(ready), .o_rdata(rdata), .i_line(line), .i_wdata_x(wdata_x), .i_byteena_x(byteena_x),
    .o_rdata_x(rdata_x), .o_sram_addr(sa), .o_sram_dq(sdq), .o_sram_dq_oe(dq_oe), .i_sram_dq(dq_in), .o_sram_ce_n(ce_n),
    .o_sram_oe_n(oe_n), .o_sram_we_n(we_n), .o_sram_lb_n(lb_n), .o_sram_ub_n(ub_n), .dbg_st(d_st));

  wire [127:0] all_w = {wdata_x, wdata};
  wire [15:0] all_be = {byteena_x, byteena};
  wire [127:0] rd_all = {rdata_x, rdata};
  wire idle = d_st == S_IDLE;
  wire in_win = addr[25:6] == 0;
  wire start = !rst && idle && (rden || wren);
  wire [4:0] base_h = line ? {addr[5:4], 3'd0} : {addr[5:2], 1'd0};
  wire [15:0] w_d = all_w[{wh, 4'd0} +: 16];
  wire [1:0] w_be = all_be[{wh, 1'd0} +: 2];

  reg f_past_valid = 0;
  reg [2:0] p_st = 0;
  reg [7:0] sc = 0;
  reg p_ready = 0, p_advance = 0, p_start = 0, p_start_out = 0, p_we_n = 1, p_oe_n = 1, p_ce_n = 1;
  reg p_rden = 0, p_wren = 0, p_line = 0;
  reg [31:0] p_addr = 0, p_wdata = 0, p_rdata = 0;
  reg [127:0] p_rd_all = 0;
  reg [19:0] p_sa = 0;
  reg [15:0] p_dq_in = 0, dq_in_q = 0;
  reg [4:0] r_base = 0;
  reg r_line = 0, r_wr = 0, r_out = 0;
  reg [1:0] r_be = 0;
  reg [15:0] r_d = 0, cap = 0;

  reg [3:0] wcount = 0, pulses = 0;
  reg [7:0] a_run = 0;
  reg [4:0] last_pa = 0;
  reg have_pa = 0;
  wire [3:0] last_h_r = r_line ? 4'd7 : 4'd1;

  always @(posedge clk) begin
    f_past_valid <= 1;
    p_st <= d_st;
    sc <= (d_st == p_st) ? sc + 1 : 1;
    p_ready <= ready; p_advance <= advance; p_start <= start && in_win; p_start_out <= start && !in_win;
    p_we_n <= we_n; p_oe_n <= oe_n; p_ce_n <= ce_n; p_rden <= rden; p_wren <= wren; p_line <= line;
    p_addr <= addr; p_wdata <= wdata; p_rdata <= rdata; p_rd_all <= rd_all; p_sa <= sa; p_dq_in <= dq_in; dq_in_q <= dq_in;
    if (start) begin r_base <= base_h; r_line <= line; r_wr <= wren; r_out <= !in_win; r_be <= w_be; wcount <= 0; pulses <= 0; have_pa <= 0; end
    // Corrida do endereço com OE# baixo.
    a_run <= (!oe_n && sa == p_sa && !p_oe_n) ? a_run + 1 : 1;
    // Pulsos de escrita: cada subida de WE#.
    if (!p_oe_n && (oe_n || sa != p_sa) && (p_sa[4:0] - r_base) == {2'd0, wh}) cap <= p_dq_in;
    if (!p_we_n && we_n) begin
      pulses <= pulses + 1; last_pa <= p_sa[4:0]; have_pa <= 1;
      if ((p_sa[4:0] - r_base) == {2'd0, wh}) wcount <= wcount + 1;
    end
  end

  // ---- o ambiente ----
  always @* if (!f_past_valid) assume (rst);
  always @* if (f_past_valid) assume (!rst);
  always @* assume (!advance || ready);
`ifdef SC_WRITE
`ifdef CFG_B
  always @* assume (!line);
`endif
`endif

  always @(posedge clk) if (f_past_valid) begin
    // 1. Os pinos: nunca WE# e OE# juntos, CE# baixo quando um deles está, o controlador só dirige o dado na escrita.
    assert (!(!we_n && !oe_n));
    assert (we_n || !ce_n);
    assert (oe_n || (!ce_n && !dq_oe));
    assert (!dq_oe || oe_n);
    assert ((d_st == S_WLOW) == !we_n);
    assert ((d_st == S_RD) == !oe_n);
    assert (!dq_oe || d_st == S_WSEL || d_st == S_WSETUP || d_st == S_WLOW || d_st == S_WHIGH);
    assert (!(d_st == S_WSETUP || d_st == S_WLOW || d_st == S_WHIGH) || dq_oe);
    if (d_st != S_WSEL) assert (!ce_n == (d_st == S_RD || d_st == S_WSETUP || d_st == S_WLOW || d_st == S_WHIGH));
    assert (sa[19:5] == 0);
    // 2. Os bytes: a leitura habilita os dois, a escrita pelo menos um e só os do habilita de bytes.
    if (d_st == S_RD) assert (!lb_n && !ub_n);
    if (!we_n) assert (!lb_n || !ub_n);
    // 3. As fases de uma escrita duram o que os generics pedem.
    if (p_st == S_WSETUP && d_st != S_WSETUP) assert (sc == 1);
    if (p_st == S_WLOW && d_st != S_WLOW) assert (sc == NWL);
    if (p_st == S_WHIGH && d_st != S_WHIGH) assert (sc == NWH);
    // 4. Cada meia palavra lida leva NRD ciclos, o endereço avança de uma meia palavra e começa no alinhado.
    if (!p_oe_n && !oe_n && sa != p_sa) begin assert (sa == p_sa + 1); assert (a_run == NRD); end
    if (!p_oe_n && oe_n) assert (a_run == NRD);
    if (!oe_n && p_oe_n) assert (sa[4:0] == r_base);
    // 5. O dado que o núcleo recebe é o dos pinos no último ciclo da corrida da meia palavra vigiada.
    if (p_advance && p_st == S_DONE && !r_wr && !r_out) assert (rd_all[{wh, 4'd0} +: 16] == cap || {1'b0, wh} > last_h_r);
    // 6. Escrita: só meias palavras com algum byte habilitado, em ordem crescente, dentro do pedido e da janela.
    if (!p_we_n && we_n) begin
      assert (p_sa[4:0] - r_base <= {1'b0, last_h_r});
      if (have_pa) assert (p_sa[4:0] > last_pa);
      assert (!r_out);
    end
    // 7. A meia palavra vigiada é escrita uma vez, com os bytes e o dado do habilita dela.
    if (!we_n && (sa[4:0] - r_base) == {2'd0, wh}) begin
      assert (lb_n == !r_be[0] && ub_n == !r_be[1]);
      assert ((r_be[0] ? sdq[7:0] == r_d[7:0] : 1) && (r_be[1] ? sdq[15:8] == r_d[15:8] : 1));
    end
    if (p_st == S_WSEL && d_st == S_DONE && r_wr && !r_out) assert (wcount == ((r_be != 0 && {1'b0, wh} <= last_h_r) ? 1 : 0));
    if (r_out && d_st != S_IDLE) assert (ce_n && we_n && oe_n);
    // 8. O contrato: o pronto fica até o avanço, o dado só muda no avanço, o acesso fora da janela lê zero.
    if (p_ready && !p_advance) assert (ready);
    if (p_advance) assert (!ready);
    assert (ready == (d_st == S_DONE));
    if (!p_advance) assert (rd_all == p_rd_all);
    if (p_start_out) assert (d_st == S_DONE && ce_n);
    if (p_advance && r_out && !r_wr) assert (rd_all[{wh, 4'd0} +: 16] == 0);
    if (p_start) assert (d_st == (r_wr ? S_WSEL : S_RD));
  end

  // O dado da meia palavra vigiada de um pedido de escrita, guardado no início do pedido.
  always @(posedge clk) if (start) r_d <= w_d;

`ifdef COVER
  always @(posedge clk) if (f_past_valid) begin
`ifdef SC_READ
    cover (p_advance && p_st == S_DONE && !r_wr && !r_out && r_line);
    cover (p_advance && p_st == S_DONE && !r_wr && !r_out && !r_line);
    cover (p_start_out);
`endif
`ifdef SC_WRITE
    cover (p_st == S_WSEL && d_st == S_DONE && r_wr && !r_out && wcount == 1 && r_line);
    cover (p_st == S_WSEL && d_st == S_DONE && r_wr && !r_out && wcount == 0 && r_be == 0);
    cover (p_start_out);
`endif
  end
`endif
endmodule
