// Propriedades do dcache em modo write-through, verificadas na netlist Verilog que o GHDL sintetiza do VHDL, com
// size_bits = 256 (duas linhas de 128 bits; a lógica é a mesma de qualquer tamanho). O núcleo e a memória de baixo
// são entradas livres, presas ao contrato por suposições. Um endereço vigiado (wa, constante mas qualquer) faz o
// papel da memória de baixo: Mw é a palavra de wa nela, atualizada por toda escrita que ela aceita (com a máscara
// de bytes) e devolvida em toda leitura ou preenchimento de linha que a contém. V é a palavra de wa como o núcleo
// a escreveu. Modos, por define:
//   DATA  a ordem dos stores e o dado de cada acerto, sem flush;
//   INV   a invalidação por flush deixa todas as linhas inválidas;
//   REGION a memória de baixo muda a palavra vigiada quando uma invalidação por região cobre a linha dela (o que o
//         controlador de FLASH faz depois de apagar ou gravar), e nenhum load devolve o dado velho a partir do
//         quarto ciclo depois do pulso, nem o preenchimento que estava em andamento.
`ifndef WINDOW
`define WINDOW 26
`endif
module props (input clk);
  // Largura da janela da tag (window_bits do DUT): 26 é 64 MiB e 27 é 128 MiB.
  localparam WIN = `WINDOW;
  localparam [5:0] BASE_SDRAM = 6'b010000, BASE_FLASH = 6'b001000;
  localparam [31:0] ROM_BASE = 32'h20000000, ROM_END = 32'h40000000;
  (* anyconst *) wire [31:0] wa;
  (* anyseq *) wire rst, rden, wren, mem_advance, flush, invalidate, bypass, d_ready;
  (* anyseq *) wire [31:0] addr, wdata, d_rdata;
  (* anyseq *) wire [3:0] byteena;
  (* anyseq *) wire [95:0] d_rdata_x;
  wire ready, miss, flush_done, busy, d_rden, d_wren, d_adv, d_line, d_inv_run;
  wire [1:0] d_valid;
  wire [31:0] rdata, d_addr, d_wdata;
  wire [3:0] d_be;
  wire [95:0] d_wdata_x;
`ifdef REGION
  (* anyseq *) wire inval_region;
  (* anyseq *) wire [31:0] ifirst, ilast, Mnew;
`else
  wire inval_region = 0;
  wire [31:0] ifirst = 0, ilast = 0;
`endif

  dcache dut (.i_clk(clk), .i_rst(rst), .i_addr(addr), .i_wdata(wdata), .i_byteena(byteena), .i_rden(rden), .i_wren(wren),
    .i_mem_advance(mem_advance), .o_ready(ready), .o_rdata(rdata), .i_flush(flush), .i_invalidate(invalidate), .i_inval_region(inval_region), .i_inval_first(ifirst), .i_inval_last(ilast), .o_miss(miss),
    .i_bypass(bypass), .o_flush_done(flush_done), .o_busy(busy), .o_d_addr(d_addr), .o_d_wdata(d_wdata), .o_d_byteena(d_be),
    .o_d_rden(d_rden), .o_d_wren(d_wren), .o_d_advance(d_adv), .i_d_ready(d_ready), .i_d_rdata(d_rdata), .o_d_line(d_line),
    .o_d_wdata_x(d_wdata_x), .i_d_rdata_x(d_rdata_x), .dbg_valid(d_valid), .dbg_inv_run(d_inv_run));

  function in_rom (input [31:0] x);
    in_rom = x >= ROM_BASE && x < ROM_END;
  endfunction
  function [31:0] merge (input [31:0] old, input [31:0] nw, input [3:0] be);
    merge = {be[3] ? nw[31:24] : old[31:24], be[2] ? nw[23:16] : old[23:16], be[1] ? nw[15:8] : old[15:8], be[0] ? nw[7:0] : old[7:0]};
  endfunction

  // O endereço vigiado como a memória de baixo o vê: a palavra e a linha, e a posição da palavra na linha.
  wire [5:0] wbase = in_rom(wa) ? BASE_FLASH : BASE_SDRAM;
  wire [31:0] wword = {wbase[5:WIN-26], wa[WIN-1:2], 2'b00};
  wire [1:0] k = wa[3:2];

  wire covers_line = inval_region && ilast[31:4] >= ifirst[31:4] && wa[31:4] >= ifirst[31:4] && wa[31:4] <= ilast[31:4];
  (* anyinit *) reg [31:0] Mw;
  (* anyinit *) reg [31:0] V;
  reg f_past_valid = 0;
  reg p_req = 0, p_adv = 0, p_rden = 0, p_wren = 0, p_ready = 0, chk = 0;
  reg [31:0] p_addr = 0, p_wdata = 0, snap = 0;
  reg [3:0] p_be = 0;
  reg [3:0] f_wait = 0;
  wire hit_w = addr[31:2] == wa[31:2];

  always @(posedge clk) begin
    f_past_valid <= 1;
    p_req <= rden || wren; p_adv <= mem_advance; p_rden <= rden; p_wren <= wren; p_ready <= ready;
    p_addr <= addr; p_wdata <= wdata; p_be <= byteena;
    f_wait <= ((d_rden || d_wren) && !d_ready) ? f_wait + 1 : 0;
    // a memória de baixo aceita uma escrita da palavra vigiada
    if (d_wren && d_ready && !d_line && d_addr[31:2] == wword[31:2]) Mw <= merge(Mw, d_wdata, d_be);
`ifdef REGION
    // a região cobre a linha vigiada: a memória de baixo passa a ter outro dado nela
    if (covers_line) Mw <= Mnew;
`endif
    // o núcleo escreveu a palavra vigiada
    if (ready && mem_advance && wren && hit_w) V <= merge(V, wdata, byteena);
    // uma leitura da palavra vigiada foi concluída: o dado sai no ciclo seguinte
    chk <= ready && mem_advance && rden && hit_w;
    snap <= V;
  end

  // ---- o ambiente ----
  always @* if (!f_past_valid) assume (rst);
  always @* if (f_past_valid) assume (!rst);
  initial assume (V == Mw);
  // os endereços do núcleo ficam na mesma janela (2**WIN bytes, 64 MiB por padrão) do endereço vigiado
  always @* assume (addr[31:WIN] == wa[31:WIN]);
  // fora da região da flash: um store na região da flash é um comando à flash, vai à memória de baixo e não ao cache
  always @* assume (!in_rom(wa));
  always @* assume (!(rden && wren));
  always @* assume (!bypass);
  // o núcleo mantém o pedido até ser atendido, e consome a resposta no ciclo em que ela chega
  always @* assume (mem_advance == ready);
  always @(posedge clk) if (f_past_valid && p_req && !p_ready)
    assume (rden == p_rden && wren == p_wren && addr == p_addr && wdata == p_wdata && byteena == p_be);
`ifndef INV
  always @* assume (!flush && !invalidate);
`endif
`ifdef REGION
  // a região só tem loads: o núcleo não escreve, e a palavra de baixo muda só pela região
  always @* assume (!wren);
`endif
  // a memória de baixo responde só a um pedido ativo, em até 2 ciclos, e devolve a palavra vigiada onde ela está
  always @* begin
    if (d_ready) assume (d_rden || d_wren);
    assume (!(f_wait == 2 && (d_rden || d_wren)));
    // (o preenchimento lê os dados depois da resposta, com o pedido já baixado: vale pelo último endereço pedido)
    if (d_addr[31:4] == wword[31:4]) begin
      if (k == 2'd0) assume (d_rdata == Mw);
      else assume (d_rdata_x[32 * (k - 1) +: 32] == Mw);
    end
  end

`ifdef DATA
  always @(posedge clk) if (f_past_valid) begin
    // 1. Um store aceito chega à memória de baixo antes de ser reconhecido, uma vez, com os bytes certos: a palavra
    //    de baixo é a que o núcleo escreveu.
    if (ready && wren && hit_w) assert (Mw == merge(V, wdata, byteena));
    // 2. Um load da palavra vigiada devolve a última escrita (a palavra de baixo), venha do acerto ou do preenchimento.
    if (chk) assert (rdata == snap);
    // 3. Os pedidos à memória de baixo são bem formados: leitura só de linha inteira alinhada, escrita só de palavra,
    //    nunca as duas juntas, e o avanço é a resposta dela.
    if (d_rden) assert (d_line && d_addr[3:0] == 4'b0000);
    if (d_wren) assert (!d_line);
    assert (!(d_rden && d_wren));
    assert (d_adv == d_ready);
    // 4. O pronto só vem com o pedido do núcleo ativo.
    if (ready) assert (rden || wren);
  end
`endif

`ifdef REGION
  reg [2:0] r_age = 3'd7, r_age_q = 3'd7;
  reg [31:0] snap_m = 0;
  reg seen_region = 0;
  always @(posedge clk) begin
    if (covers_line) seen_region <= 1;
    if (covers_line) r_age <= 0; else if (r_age != 3'd7) r_age <= r_age + 1;
    r_age_q <= r_age;
    snap_m <= Mw;
  end
  always @(posedge clk) if (f_past_valid) begin
    // 6. Um load da palavra vigiada concluído a partir do quarto ciclo depois da região devolve o dado atual da
    //    memória de baixo, venha do acerto ou de um preenchimento (o que estava em andamento é descartado).
    if (chk && r_age_q >= 3) assert (rdata == snap_m);
    assert (d_adv == d_ready);
  end
`endif

`ifdef INV
  always @(posedge clk) if (f_past_valid) begin
    // 5. Um flush com invalidação deixa todas as linhas inválidas quando termina.
    if (flush_done && d_inv_run) assert (d_valid == 2'b00);
  end
`endif

`ifdef COVER
  reg fill_seen = 0;
  always @(posedge clk) if (f_past_valid) begin
    if (d_rden) fill_seen <= 1;
    cover (chk && fill_seen && snap != 32'h0);
`ifndef REGION
    cover (ready && wren && hit_w && Mw != 0);
`endif
    cover (ready && rden && hit_w && !d_rden && fill_seen);
`ifdef INV
    cover (flush_done && d_inv_run);
`endif
`ifdef REGION
    cover (covers_line && Mnew != Mw);
    cover (chk && seen_region && r_age_q >= 3 && snap_m != 32'h0);
`endif
  end
`endif
endmodule
