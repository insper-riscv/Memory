// Propriedades do nor_flash_ctrl, verificadas na netlist Verilog que o GHDL sintetiza do VHDL, com um chip de 8 KB
// (13 bits de endereço), setores de 4 KB (dois), páginas de 8 bytes (duas palavras) e esperas curtas (a lógica é a
// mesma dos tamanhos e dos tempos da DE2-115). A configuração A usa uma borda em cada espera de leitura e de
// escrita; a B (-DCFG_B) usa esperas diferentes (3, 2, 2, 3, 5, 2 e 3 bordas) para provar que o número de bordas de
// cada fase segue o generic e não uma constante. O ambiente é livre (pedido de leitura, comando, dado do chip, RY e
// buffer de página), preso ao contrato por suposições: o pedido de leitura fica estável até o avanço, o avanço só
// vem com o pronto, e só o primeiro ciclo tem reset. O buffer de página devolve a palavra B (qualquer, constante) na
// posição wa (qualquer, constante) e 0xFFFFFFFF na outra, para a gravação percorrer só bytes que ela precisa gravar.
// Cada cenário (-DSC_READ, -DSC_ERASE, -DSC_PROGRAM, -DSC_CMD) liga só as entradas que ele usa e limita os
// comandos, para a prova chegar ao fim da operação em poucos ciclos; as propriedades são as mesmas.
// Os registradores wel, prot, is_erase, st e o RY sincronizado são expostos (dbg_*), e o chip é observado só pelos pinos.
module props (input clk);
`ifdef CFG_B
  localparam integer NF = 3, NN = 2, NWL = 2, NWH = 3, NBUSY = 5, NRP = 2, NRH = 3;
`else
  localparam integer NF = 1, NN = 1, NWL = 1, NWH = 1, NBUSY = 4, NRP = 1, NRH = 1;
`endif
  localparam [31:0] BASE = 32'h20000000;
  localparam [2:0] WREN = 3'd1, ERASE = 3'd2, PROGRAM = 3'd3, PROTECT = 3'd4, UNPROT = 3'd5;
  localparam [3:0] S_RST_ARM = 0, S_RST_LOW = 1, S_RST_HIGH = 2, S_IDLE = 3, S_RD = 4, S_RD_DONE = 5, S_FETCH = 6,
    S_PBYTE = 7, S_NEXT = 8, S_WSETUP = 9, S_WLOW = 10, S_WHIGH = 11, S_BUSY = 12, S_POLL = 13, S_FIN = 14;

  (* anyconst *) wire wa;
  (* anyconst *) wire [31:0] B;
  (* anyseq *) wire rst, ry;
  (* anyseq *) wire [7:0] fl_dq;
  // O cenário escolhe quais entradas são livres: a leitura sem comandos, e os comandos sem pedidos de leitura.
`ifdef SC_READ
  (* anyseq *) wire rden, line, advance;
  (* anyseq *) wire [31:0] addr;
  wire cmd_valid = 1'b0;
  wire [31:0] cmd_addr = 32'd0;
  wire [2:0] cmd_op = 3'd0;
`else
  wire rden = 1'b0, line = 1'b0, advance = 1'b0;
  wire [31:0] addr = 32'd0;
  (* anyseq *) wire cmd_valid;
  (* anyseq *) wire [31:0] cmd_addr;
  (* anyseq *) wire [2:0] cmd_op;
`endif

  wire ready, busy, cmd_busy, wel, refused, buf_idx, inval, dq_oe, ce_n, oe_n, we_n, rst_n, wp_n;
  wire [31:0] rdata, first, last;
  wire [95:0] rdata_x;
  wire [22:0] fl_addr;
  wire [7:0] fl_do;
  wire d_wel, d_is_erase, d_ry;
  wire [1:0] d_prot;
  wire [3:0] d_st;
  reg [31:0] buf_q = 32'hFFFFFFFF;

  nor_flash_ctrl dut (.i_clk(clk), .i_rst(rst), .i_addr(addr), .i_rden(rden), .i_line(line), .i_advance(advance),
    .o_ready(ready), .o_busy(busy), .o_rdata(rdata), .o_rdata_x(rdata_x),
    .i_cmd_valid(cmd_valid), .i_cmd_op(cmd_op), .i_cmd_addr(cmd_addr), .o_cmd_busy(cmd_busy), .o_wel(wel),
    .o_refused(refused), .o_buf_idx(buf_idx), .i_buf_data(buf_q),
    .o_inval_valid(inval), .o_inval_first(first), .o_inval_last(last),
    .o_fl_addr(fl_addr), .o_fl_dq(fl_do), .o_fl_dq_oe(dq_oe), .i_fl_dq(fl_dq), .o_fl_ce_n(ce_n), .o_fl_oe_n(oe_n),
    .o_fl_we_n(we_n), .o_fl_rst_n(rst_n), .o_fl_wp_n(wp_n), .i_fl_ry(ry),
    .dbg_wel(d_wel), .dbg_prot(d_prot), .dbg_is_erase(d_is_erase), .dbg_st(d_st), .dbg_ry_s(d_ry));

  // O buffer de página: leitura registrada.
  always @(posedge clk) buf_q <= (buf_idx == wa) ? B : 32'hFFFFFFFF;

  // ---- descrição do ciclo ----
  wire in_win = cmd_addr[25:13] == 0;
  wire sec = cmd_addr[12];
  wire op_ep = cmd_op == ERASE || cmd_op == PROGRAM;
  wire idle = d_st == S_IDLE;
  wire accept = !rst && cmd_valid && idle && wel && op_ep && in_win && !d_prot[sec];
  wire refuse = !rst && cmd_valid && idle && wel && op_ep && (!in_win || d_prot[sec]);
  wire ignored = !rst && cmd_valid && idle && !wel && op_ep;
  wire rd_in = addr[25:13] == 0;
  wire rd_start = !rst && idle && !cmd_valid && rden && rd_in;
  wire rd_out = !rst && idle && !cmd_valid && rden && !rd_in;
  wire op_state = d_st >= S_FETCH && d_st <= S_FIN;
  wire wr_state = d_st == S_WSETUP || d_st == S_WLOW || d_st == S_WHIGH;

  reg f_past_valid = 0;
  reg [3:0] p_st = 0;
  reg [7:0] sc = 0;
  reg p_ready = 0, p_advance = 0, p_rden = 0, p_line = 0, p_wel = 0, p_refused = 0, p_inval = 0, p_ry = 0;
  reg p_accept = 0, p_refuse = 0, p_ignored = 0, p_wren = 0, p_valid_idle = 0, p_valid_busy = 0, p_protect = 0, p_unprot = 0;
  reg p_oe_n = 1, p_we_n = 1, p_rst_n = 0, p_ce_n = 1, p_rd_out = 0, p_rd_start = 0;
  reg [1:0] p_prot = 0;
  reg p_sec = 0;
  reg [31:0] p_addr = 0;
  reg [22:0] p_fl_addr = 0;
  reg [7:0] p_fl_dq = 0;
  reg [127:0] p_line_q = 0;
  reg [7:0] a_run = 0, oe_cycles = 0, sr = 0, rl = 0;
  reg [31:0] r_addr = 0;
  reg r_line = 0, first_byte = 0;
  reg [3:0] pidx_q = 0;
  reg [2:0] acc_op = 0;
  reg [31:0] acc_addr = 0;
  reg [3:0] nprog = 0;
  reg [22:0] last_pa = 0;
  reg have_pa = 0;

  // Os pulsos de escrita já completos na operação ou no byte em andamento, contando o que acabou de terminar.
  wire [3:0] pidx = (d_st == S_IDLE || (p_st == S_POLL && d_st != S_POLL)) ? 4'd0 :
                    pidx_q + ((p_st == S_WHIGH && d_st != S_WHIGH) ? 4'd1 : 4'd0);
  wire [127:0] line_q = {rdata_x, rdata};
  wire [3:0] nonff = {B[31:24] != 8'hFF, B[23:16] != 8'hFF, B[15:8] != 8'hFF, B[7:0] != 8'hFF};
  wire [3:0] nonff_n = {3'd0, nonff[0]} + {3'd0, nonff[1]} + {3'd0, nonff[2]} + {3'd0, nonff[3]};

  always @(posedge clk) begin
    f_past_valid <= 1;
    p_st <= d_st;
    sc <= (d_st == p_st) ? sc + 1 : 1;
    p_ready <= ready; p_advance <= advance; p_rden <= rden; p_line <= line; p_wel <= d_wel; p_refused <= refused;
    p_inval <= inval; p_ry <= d_ry;
    p_accept <= accept; p_refuse <= refuse; p_ignored <= ignored;
    p_wren <= !rst && cmd_valid && idle && cmd_op == WREN;
    p_valid_idle <= !rst && cmd_valid && idle;
    p_valid_busy <= !rst && cmd_valid && !idle;
    p_protect <= !rst && cmd_valid && idle && cmd_op == PROTECT && in_win;
    p_unprot <= !rst && cmd_valid && idle && cmd_op == UNPROT && in_win;
    p_oe_n <= oe_n; p_we_n <= we_n; p_rst_n <= rst_n; p_ce_n <= ce_n; p_rd_out <= rd_out; p_rd_start <= rd_start;
    p_prot <= d_prot; p_sec <= sec; p_addr <= addr; p_fl_addr <= fl_addr; p_fl_dq <= fl_dq; p_line_q <= line_q;
    // O pedido de leitura em andamento.
    if (rd_start) begin r_addr <= line ? {addr[31:4], 4'd0} : {addr[31:2], 2'd0}; r_line <= line; end
    // Corrida de endereço constante e bordas com OE# baixo.
    a_run <= (!oe_n && fl_addr == p_fl_addr && !p_oe_n) ? a_run + 1 : 1;
    oe_cycles <= !oe_n ? oe_cycles + 1 : 0;
    // Bordas desde a subida de WE# e largura de RESET#.
    sr <= we_n ? (sr == 8'hFF ? sr : sr + 1) : 0;
    rl <= !rst_n ? rl + 1 : 0;
    // A operação em andamento: comando aceito, número de pulsos de escrita já completos, bytes gravados.
    if (accept) begin acc_op <= cmd_op; acc_addr <= cmd_addr; nprog <= 0; have_pa <= 0; end
    pidx_q <= pidx;
    if (p_st == S_WHIGH && d_st != S_WHIGH && pidx_q == 3 && !d_is_erase) begin
      nprog <= nprog + 1; last_pa <= p_fl_addr; have_pa <= 1;
    end
  end

  // ---- o ambiente ----
  always @* if (!f_past_valid) assume (rst);
  always @* if (f_past_valid) assume (!rst);
  // O pedido de leitura fica estável até o avanço, e o avanço só vem com o pronto.
  always @* if (f_past_valid && p_rden && !p_advance) assume (rden && addr == p_addr && line == p_line);
  always @* assume (!advance || ready);
`ifdef SC_ERASE
  always @* assume (cmd_op == WREN || cmd_op == ERASE);
`endif
`ifdef SC_PROGRAM
  // Um só byte do buffer precisa ser gravado.
  always @* assume (cmd_op == WREN || cmd_op == PROGRAM);
  always @* assume (nonff != 0 && (nonff & (nonff - 4'd1)) == 0);
`endif

  // Endereço e dado esperados no pulso de índice pidx (pulsos completos antes dele) de um apagar ou de uma gravação.
  wire [22:0] ua = 23'h0AAA, ub = 23'h0555;
  wire [22:0] exp_addr = d_is_erase ? ((pidx == 1 || pidx == 4) ? ub : (pidx == 5 ? {10'd0, acc_addr[12], 12'd0} : ua)) :
                                      ((pidx == 1) ? ub : ua);
  wire [7:0] exp_data = d_is_erase ? ((pidx == 0 || pidx == 3) ? 8'hAA : (pidx == 1 || pidx == 4) ? 8'h55 : pidx == 2 ? 8'h80 : 8'h30) :
                                     ((pidx == 0) ? 8'hAA : pidx == 1 ? 8'h55 : 8'hA0);
  wire [7:0] b_byte = fl_addr[1:0] == 0 ? B[7:0] : fl_addr[1:0] == 1 ? B[15:8] : fl_addr[1:0] == 2 ? B[23:16] : B[31:24];

  always @(posedge clk) if (f_past_valid) begin
    // 1. Os pinos: nunca WE# e OE# juntos, CE# baixo quando um deles está, o controlador só dirige o dado na escrita.
    assert (!(!we_n && !oe_n));
    assert (we_n || !ce_n);
    assert (oe_n || (!ce_n && !dq_oe));
    assert (!dq_oe || oe_n);
    assert (wp_n);
    assert ((d_st == S_WLOW) == !we_n);
    assert ((d_st == S_RD) == !oe_n);
    assert (dq_oe == wr_state);
    assert (!ce_n == (d_st == S_RD || wr_state));
    assert (fl_addr[22:13] == 0);
    assert (!rst_n == (d_st == S_RST_ARM || d_st == S_RST_LOW));
    // 2. RESET# baixo por NRP bordas além da armação, e o chip só é acessado depois de NRH bordas.
    if (!p_rst_n && rst_n) assert (rl == NRP + 2);
    if (p_st == S_RST_HIGH && d_st != S_RST_HIGH) assert (sc == NRH);
    if (d_st == S_RD || wr_state || d_st == S_BUSY || d_st == S_POLL) assert (rst_n);
`ifndef SC_READ
    // 3. A fase de cada ciclo de escrita dura o que os generics pedem.
    if (p_st == S_WSETUP && d_st != S_WSETUP) assert (sc == 1);
    if (p_st == S_WLOW && d_st != S_WLOW) assert (sc == NWL);
    if (p_st == S_WHIGH && d_st != S_WHIGH) assert (sc == NWH);
    if (p_st == S_BUSY && d_st != S_BUSY) assert (sc == NBUSY);
    // 4. A sequência dos ciclos de escrita do chip: endereço e dado de cada pulso, constantes durante o pulso.
    if (wr_state && pidx <= (d_is_erase ? 5 : 2)) begin
      assert (fl_addr == exp_addr && fl_do == exp_data);
    end
    // 5. O ciclo do byte gravado: dentro da página do comando, só do byte que o buffer manda gravar, em ordem.
    if (wr_state && !d_is_erase && pidx == 3) begin
      assert (fl_addr[12:3] == acc_addr[12:3]);
      assert (fl_addr[2] == wa);
      assert (fl_do == b_byte && fl_do != 8'hFF);
      if (have_pa) assert (fl_addr > last_pa);
    end
    assert (!wr_state || pidx <= (d_is_erase ? 5 : 3));
    // 6. Escreve só com o latch armado e em setor sem proteção; o comando da operação é o aceito.
    if (!we_n) begin assert (d_wel && !d_prot[acc_addr[12]]); assert (d_is_erase == (acc_op == ERASE)); end
    // 7. Depois do último pulso espera t_busy e só sai da espera de RY com RY alto.
    if (p_st == S_BUSY && d_st == S_POLL) assert (sr == NWH + NBUSY);
    if (p_st == S_POLL && d_st != S_POLL) assert (p_ry);
    if (d_st == S_BUSY) assert (pidx == (d_is_erase ? 6 : 4));
    // 8. O fim da operação: o pulso de invalidação traz a região e baixa o latch.
    if (inval) begin
      assert (p_st == S_FIN && d_st == S_IDLE && !d_wel);
      assert (first - BASE == (acc_op == ERASE ? {19'd0, acc_addr[12], 12'd0} : {19'd0, acc_addr[12:3], 3'd0}));
      assert (last - first == (acc_op == ERASE ? 4095 : 7));
      if (acc_op == PROGRAM) assert (nprog == nonff_n);
    end
    if (p_st == S_FIN) assert (d_st == S_IDLE);
`endif
`ifdef SC_READ
    // 9. Leitura: o dado de cada byte é o do pino no último ciclo da corrida do endereço, e o endereço avança de um.
    if (!p_oe_n && !oe_n && fl_addr != p_fl_addr) begin
      assert (fl_addr == p_fl_addr + 1);
      assert (a_run == (first_byte ? NF : NN));
    end
    if (!p_oe_n && (oe_n || fl_addr != p_fl_addr)) begin
      if (r_line) assert (line_q[{p_fl_addr[3:0], 3'd0} +: 8] == p_fl_dq);
      else assert (line_q[{p_fl_addr[1:0], 3'd0} +: 8] == p_fl_dq);
    end
    if (!p_oe_n && oe_n) begin
      assert (a_run == NN);
      assert (oe_cycles == NF + (r_line ? 15 : 3) * NN);
    end
    if (!oe_n && p_oe_n) assert (fl_addr[22:0] == r_addr[22:0]);
    // 10. Contrato da leitura: o pronto fica até o avanço, o dado não muda, o pedido fora da janela lê zero sem tocar no chip.
    if (p_ready && !p_advance) assert (ready && line_q == p_line_q);
    if (p_advance) assert (!ready);
    assert (busy == (d_st == S_RD));
    assert (ready == (d_st == S_RD_DONE));
    if (p_rd_out) assert (d_st == S_RD_DONE && ce_n && line_q[31:0] == 0 && (!p_line || line_q[127:32] == 0));
    if (p_rd_start) assert (d_st == S_RD);
`endif
    // 11. Comandos: o latch, a recusa, a proteção e a prioridade sobre a leitura.
    if (p_ignored) assert (d_st == S_IDLE && !d_wel && p_refused == refused && p_prot == d_prot);
    if (p_refuse) assert (d_st == S_IDLE && !d_wel && refused && p_prot == d_prot);
    if (p_accept) assert (d_st != S_IDLE && d_wel && !refused);
    if (p_wren) assert (d_wel && !refused && d_st == S_IDLE);
    if (p_protect) assert (d_prot[p_sec] && (d_prot & ~(2'd1 << p_sec)) == (p_prot & ~(2'd1 << p_sec)));
    if (p_unprot) assert (!d_prot[p_sec] && (d_prot & ~(2'd1 << p_sec)) == (p_prot & ~(2'd1 << p_sec)));
    if (p_valid_busy) assert (refused == p_refused && d_prot == p_prot);
    if (p_valid_idle && !p_accept) assert (d_st == S_IDLE);
    if (op_state) assert (d_wel);
    assert (cmd_busy == (d_st != S_IDLE));
    if (d_st == S_FIN) assert (d_wel);
  end

  // A primeira palavra de uma corrida de leitura: o primeiro byte tem a espera NF, os seguintes NN.
  always @(posedge clk) begin
    if (rd_start) first_byte <= 1;
    else if (!p_oe_n && !oe_n && fl_addr != p_fl_addr) first_byte <= 0;
  end

`ifdef COVER
  always @(posedge clk) if (f_past_valid) begin
`ifdef SC_ERASE
    cover (inval && acc_op == ERASE);
    cover (p_st == S_POLL && d_st != S_POLL);
`endif
`ifdef SC_PROGRAM
    cover (inval && acc_op == PROGRAM && nprog == 1);
`endif
`ifdef SC_CMD
    cover (p_refuse && d_prot != 0);
    cover (p_ignored);
    cover (p_unprot && !p_prot[p_sec]);
`endif
`ifdef SC_READ
    cover (ready && r_line && p_st == S_RD);
    cover (ready && !r_line && p_st == S_RD);
    cover (p_rd_out);
`endif
  end
`endif
endmodule
