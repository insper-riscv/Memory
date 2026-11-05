// Propriedades do flash_cmd_port, verificadas na netlist Verilog que o GHDL sintetiza do VHDL, com um chip de 64
// bytes, setores de 16 bytes (quatro palavras), páginas de 8 bytes (duas palavras) e esperas de 1 borda (a lógica
// é a mesma dos tamanhos de 1 MB, 4 KB e 256 B). O comando de entrada e o dado de fora são entradas livres, presas
// ao contrato por suposições. A memória de armazenamento e o buffer de página são modelados aqui: uma palavra
// vigiada (wa, constante mas qualquer) tem o valor guardado em shadow (inicial qualquer), que a escrita atualiza e a leitura
// registrada devolve; o buffer devolve B (constante mas qualquer) na posição de wa. As demais palavras são livres.
// Três registradores (dbg_*, adicionados a uma cópia da netlist) são expostos: o latch, a proteção e o tipo da
// operação em andamento.
module props (input clk);
  localparam [31:0] BASE = 32'h20000000;
  localparam integer ERASE_CLOCKS = 14, PROGRAM_CLOCKS = 8;
  localparam [2:0] WREN = 3'd1, ERASE = 3'd2, PROGRAM = 3'd3, PROTECT = 3'd4, UNPROT = 3'd5;
  (* anyconst *) wire [3:0] wa;
  (* anyconst *) wire [31:0] B;
  (* anyseq *) wire rst, cmd_valid;
  (* anyseq *) wire [2:0] cmd_op;
  (* anyseq *) wire [31:0] cmd_addr, other_mem, other_buf;
  wire busy, wel, refused, mem_we, inval;
  wire [31:0] mem_addr, mem_wdata, first, last;
  wire buf_idx;
  wire d_wel, d_is_erase;
  wire [3:0] d_prot;

  (* anyinit *) reg [31:0] shadow;
  reg [31:0] mem_q = 0, buf_q = 0;

  flash_cmd_port dut (.i_clk(clk), .i_rst(rst), .i_cmd_valid(cmd_valid), .i_cmd_op(cmd_op), .i_cmd_addr(cmd_addr),
    .o_busy(busy), .o_wel(wel), .o_refused(refused), .o_buf_idx(buf_idx), .i_buf_data(buf_q),
    .o_mem_addr(mem_addr), .o_mem_we(mem_we), .o_mem_wdata(mem_wdata), .i_mem_data(mem_q),
    .o_inval_valid(inval), .o_inval_first(first), .o_inval_last(last),
    .dbg_wel(d_wel), .dbg_prot(d_prot), .dbg_is_erase(d_is_erase));

  // O armazenamento: a escrita atualiza a palavra vigiada, e a leitura registrada devolve o valor dela.
  always @(posedge clk) begin
    if (mem_we && mem_addr[5:2] == wa) shadow <= mem_wdata;
    if (mem_we) mem_q <= mem_wdata;
    else mem_q <= (mem_addr[5:2] == wa) ? shadow : other_mem;
    buf_q <= (buf_idx == wa[0]) ? B : other_buf;
  end

  // Descrição do comando de entrada, no mesmo ciclo.
  wire in_win = cmd_addr[25:6] == 0;
  wire [1:0] sec = cmd_addr[5:4];
  wire op_ep = cmd_op == ERASE || cmd_op == PROGRAM;
  wire accept = !rst && cmd_valid && !busy && wel && op_ep && in_win && !d_prot[sec];
  wire refuse = !rst && cmd_valid && !busy && wel && op_ep && (!in_win || d_prot[sec]);
  wire ignored = !rst && cmd_valid && !busy && !wel && op_ep;

  reg f_past_valid = 0;
  reg p_busy = 0, p_wel = 0, p_refused = 0, p_accept = 0, p_refuse = 0, p_ignored = 0, p_wren = 0, p_inval = 0;
  reg p_valid = 0, p_protect = 0, p_unprot = 0, p_mem_we = 0;
  reg [3:0] p_prot = 0;
  reg [1:0] p_sec = 0;
  reg [3:0] busy_clocks = 0;
  reg [3:0] w_cnt = 0;
  reg [31:0] w_first = 0, w_next = 0;
  always @(posedge clk) begin
    f_past_valid <= 1;
    p_busy <= busy; p_wel <= wel; p_refused <= refused; p_accept <= accept; p_refuse <= refuse; p_ignored <= ignored;
    p_wren <= !rst && cmd_valid && !busy && cmd_op == WREN; p_inval <= inval; p_valid <= !rst && cmd_valid && !busy;
    p_protect <= cmd_op == PROTECT && in_win; p_unprot <= cmd_op == UNPROT && in_win;
    p_prot <= d_prot; p_sec <= sec; p_mem_we <= mem_we;
    busy_clocks <= busy ? busy_clocks + 1 : 0;
    if (mem_we) begin
      if (w_cnt == 0) w_first <= mem_addr;
      w_cnt <= w_cnt + 1;
      w_next <= mem_addr + 4;
    end
    if (inval) w_cnt <= 0;
  end

  // ---- o ambiente ----
  always @* if (!f_past_valid) assume (rst);
  always @* if (f_past_valid) assume (!rst);

  always @(posedge clk) if (f_past_valid) begin
    // 1. Escreve só ocupado, e só com o latch armado e em setor sem proteção.
    if (mem_we) assert (busy && wel && !d_prot[mem_addr[5:4]]);
    // 2. Um apagar escreve só uns, e uma gravação escreve o E bit a bit do conteúdo com a palavra do buffer.
    if (mem_we && d_is_erase) assert (mem_wdata == 32'hFFFFFFFF);
    if (mem_we && !d_is_erase && mem_addr[5:2] == wa) assert (mem_wdata == (shadow & B));
    // 3. Ocupado implica latch armado; terminada a operação, o latch cai e sai um pulso de invalidação.
    if (busy) assert (wel);
    if (p_busy && !busy) assert (inval && !wel);
    if (inval) assert (p_busy && !busy && !mem_we);
    // 4. Comando sem latch é ignorado por inteiro.
    if (p_ignored) assert (!busy && !wel && p_refused == refused && p_prot == d_prot);
    // 5. Recusa: setor protegido ou fora da janela não ocupa o chip, derruba o latch e sobe a recusa.
    if (p_refuse) assert (!busy && !wel && refused && p_prot == d_prot);
    // 6. Aceita: ocupa o chip, sem recusa.
    if (p_accept) assert (busy && !refused);
    // 7. Habilitar escrita arma o latch e limpa a recusa.
    if (p_wren) assert (wel && !refused);
    // 8. Proteger e desproteger mexem só no bit do setor; sem esses comandos a proteção não muda.
    if (p_protect && p_valid) begin
      assert (d_prot[p_sec]);
      assert ((d_prot & ~(4'd1 << p_sec)) == (p_prot & ~(4'd1 << p_sec)));
    end else if (p_unprot && p_valid) begin
      assert (!d_prot[p_sec]);
      assert ((d_prot & ~(4'd1 << p_sec)) == (p_prot & ~(4'd1 << p_sec)));
    end else assert (d_prot == p_prot);
    // 9. Ocupado, nenhum comando muda o latch nem a recusa.
    if (p_busy && busy) assert (wel && refused == p_refused);
    // 10. Sem ocupado não há escrita; a escrita só vem depois do endereço (duas bordas).
    if (!busy) assert (!mem_we);
    // 11. A espera é limitada: o apagar ocupa ERASE_CLOCKS bordas e a gravação PROGRAM_CLOCKS.
    if (busy && d_is_erase) assert (busy_clocks < ERASE_CLOCKS);
    if (busy && !d_is_erase) assert (busy_clocks < PROGRAM_CLOCKS);
    // 12. No pulso, a região invalidada é exatamente a das palavras escritas, em ordem, alinhada ao setor ou à página.
    if (inval) begin
      assert (w_cnt * 4 == last - first + 1);
      assert (w_first == first - BASE);
      assert (first[3:0] == 4'd0 || !d_is_erase);
      assert (first[2:0] == 3'd0);
      assert (d_is_erase ? (last - first == 15) : (last - first == 7));
    end
    if (mem_we && w_cnt != 0) assert (mem_addr == w_next);
  end

`ifdef COVER
  always @(posedge clk) if (f_past_valid) begin
    cover (p_accept && d_is_erase);
    cover (p_accept && !d_is_erase);
    cover (p_refuse && d_prot != 0);
    cover (p_ignored);
    cover (inval && last - first == 7);
    cover (mem_we && !d_is_erase && mem_addr[5:2] == wa && (shadow & B) != 32'hFFFFFFFF && (shadow & B) != shadow);
    cover (busy_clocks == ERASE_CLOCKS - 1 && busy);
  end
`endif
endmodule
