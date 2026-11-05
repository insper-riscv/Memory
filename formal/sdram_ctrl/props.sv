// Propriedades do sdram_ctrl, verificadas na netlist Verilog que o GHDL sintetiza do VHDL. O mestre do
// pedido e o chip (dados lidos) são entradas livres; as asserções olham o barramento de comandos da SDRAM, que
// é o contrato com o chip. A prova roda com init_cycles e refresh_cycles pequenos (INIT e REFC), o que só
// encurta a espera de 200 us e o período de refresh; os tempos do chip (tRCD, tRP, tRC, tRFC, tMRD) são os do
// pacote sdram_pkg a 7 ns de período, ou seja, os do projeto: 3, 3, 9, 9 e 2 ciclos.
`ifndef INIT
`define INIT 6
`endif
`ifndef REFC
`define REFC 24
`endif
`ifndef REFSLACK
`define REFSLACK 22   // espera máxima de um refresh atrasado por um acesso em curso
`endif
`ifndef RESP
`define RESP 60       // um pedido é respondido em até RESP ciclos
`endif

module props (input clk);
  localparam C_RCD = 3, C_RP = 3, C_RC = 9, C_RFC = 9, T_MRD = 2, N_INIT_REF = 8;
  localparam [3:0] NOP = 4'b0111, ACTIVE = 4'b0011, READ = 4'b0101, WRITE = 4'b0100, PRE = 4'b0010, REF = 4'b0001, LMR = 4'b0000;
  localparam [12:0] MODE = 13'b0000000110001;

  (* anyseq *) wire rst, req_tog, we, line;
  (* anyseq *) wire [23:0] addr;
  (* anyseq *) wire [31:0] wdata;
  (* anyseq *) wire [3:0] be;
  (* anyseq *) wire [95:0] wdata_x;
  (* anyseq *) wire [11:0] be_x;
  (* anyseq *) wire [15:0] dq_in;
  wire ack_tog, init_done, cke, cs_n, ras_n, cas_n, we_n, dq_oe;
  wire [31:0] rdata;
  wire [95:0] rdata_x;
  wire [1:0] ba, dqm;
  wire [12:0] a;
  wire [15:0] dq_out;

  sdram_ctrl dut (.i_clk(clk), .i_rst(rst), .i_req_tog(req_tog), .o_ack_tog(ack_tog), .o_init_done(init_done),
    .i_we(we), .i_addr(addr), .i_wdata(wdata), .i_be(be), .o_rdata(rdata), .i_line(line), .i_wdata_x(wdata_x),
    .i_be_x(be_x), .o_rdata_x(rdata_x), .o_dram_cke(cke), .o_dram_cs_n(cs_n), .o_dram_ras_n(ras_n),
    .o_dram_cas_n(cas_n), .o_dram_we_n(we_n), .o_dram_ba(ba), .o_dram_addr(a), .o_dram_dqm(dqm),
    .o_dram_dq_out(dq_out), .o_dram_dq_oe(dq_oe), .i_dram_dq_in(dq_in));

  wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
  // O primeiro ciclo é o do reset: os registradores de saída ainda não têm valor, e esse ciclo não conta.
  reg f_past_valid = 0;
  wire non_nop = f_past_valid && cmd != NOP;

  reg p_req = 0, p_ack = 0, p_we = 0, p_line = 0;
  reg [23:0] p_addr = 0;
  reg [31:0] p_wdata = 0;
  reg [3:0] p_be = 0;
  reg [95:0] p_wx = 0;
  reg [11:0] p_bex = 0;
  // Fase da inicialização: 0 espera o PRECHARGE, 1 os 8 refreshes, 2 o LOAD MODE, 3 pronto.
  reg [1:0] ph = 0;
  reg [3:0] nref = 0;
  reg [9:0] since_rst = 0;
  // Ciclos desde o último comando (e qual foi) e desde o último ACTIVE; saturam.
  reg [7:0] dist = 8'hFF, since_act = 8'hFF, since_ref = 0, wait_resp = 0;
  reg [3:0] last = NOP;

  always @(posedge clk) begin
    f_past_valid <= 1;
    p_req <= req_tog; p_ack <= ack_tog; p_we <= we; p_line <= line; p_addr <= addr; p_wdata <= wdata; p_be <= be;
    p_wx <= wdata_x; p_bex <= be_x;
    since_rst <= (since_rst == 10'h3FF) ? since_rst : since_rst + 1;
    dist <= non_nop ? 8'd1 : ((dist == 8'hFF) ? dist : dist + 1);
    since_act <= (f_past_valid && cmd == ACTIVE) ? 8'd1 : ((since_act == 8'hFF) ? since_act : since_act + 1);
    if (non_nop) last <= cmd;
    if (non_nop && f_past_valid) begin
      if (ph == 0) ph <= 1;
      else if (ph == 1) begin nref <= nref + 1; if (nref == N_INIT_REF - 1) ph <= 2; end
      else if (ph == 2) ph <= 3;
    end
    since_ref <= ((f_past_valid && cmd == REF) || !init_done) ? 8'd0 : ((since_ref == 8'hFF) ? since_ref : since_ref + 1);
    wait_resp <= (req_tog != ack_tog && init_done) ? ((wait_resp == 8'hFF) ? wait_resp : wait_resp + 1) : 0;
  end

  // ---- o ambiente ----
  always @* if (!f_past_valid) assume (rst && !req_tog);
  always @* if (f_past_valid) assume (!rst);
  // o mestre inverte o toggle só depois da resposta e segura a carga até lá
  always @(posedge clk) if (f_past_valid) begin
    if (req_tog != p_req) assume (p_req == p_ack);
    if (p_req != p_ack) assume (req_tog == p_req && we == p_we && line == p_line && addr == p_addr && wdata == p_wdata
      && be == p_be && wdata_x == p_wx && be_x == p_bex);
  end

  always @(posedge clk) if (f_past_valid) begin
    // 1. Inicialização completa antes do primeiro acesso: espera de INIT ciclos, PRECHARGE de todos os bancos, oito
    //    REFRESH, LOAD MODE com o registrador de modo do projeto; nada mais sai enquanto isso não acaba.
    if (non_nop && ph == 0) assert (cmd == PRE && a[10] && since_rst >= `INIT);
    if (non_nop && ph == 1) assert (cmd == REF);
    if (non_nop && ph == 2) assert (cmd == LMR && a == MODE);
    // 2. A inicialização termina com o LOAD MODE: o sinal de pronto sobe com ele e nunca antes.
    if (init_done) assert (ph == 3 || (ph == 2 && cmd == LMR));
    if (ph == 3) assert (init_done);
    // 3. Tempos do chip: nenhum comando antes de tRP depois de um PRECHARGE, de tRFC depois de um REFRESH, de tMRD depois do
    //    LOAD MODE, e leitura ou escrita só depois de tRCD do ACTIVE.
    if (non_nop && last == PRE) assert (dist >= C_RP);
    if (non_nop && last == REF) assert (dist >= C_RFC);
    if (non_nop && last == LMR) assert (dist >= T_MRD);
    if (cmd == READ || cmd == WRITE) assert (since_act >= C_RCD);
    // 4. Entre dois ACTIVE, ou um ACTIVE e um REFRESH, passa o tempo de linha tRC (tRAS + tRP).
    if (cmd == ACTIVE || cmd == REF) assert (since_act >= C_RC);
    // 5. Um refresh sai dentro do período: no pior caso o do período mais o tempo de um acesso em curso.
    assert (since_ref <= `REFC + `REFSLACK);
    // 6. O ack só inverte para responder um pedido pendente, e todo pedido é respondido dentro de RESP ciclos.
    if (ack_tog != p_ack) assert (p_req != p_ack && ack_tog == p_req);
    assert (wait_resp <= `RESP);
  end

`ifdef COVER
  always @(posedge clk) if (f_past_valid) begin
    cover (init_done && cmd == REF);
    cover (cmd == READ && line);
    cover (cmd == WRITE && !line);
    cover (cmd == WRITE && line);
    cover (init_done && ack_tog != p_ack && we);
  end
`endif
endmodule
