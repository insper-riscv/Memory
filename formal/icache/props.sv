// Propriedades do icache, verificadas na netlist Verilog que o GHDL sintetiza do VHDL, com size_bits = 256 (duas
// linhas de 128 bits; a lógica é a mesma de qualquer tamanho). Os dois clocks do módulo ligam ao mesmo sinal.
// O núcleo e a memória de baixo são entradas livres, presas ao contrato por suposições. Um endereço vigiado
// (wa, constante mas qualquer) e a sua palavra W (constante mas qualquer) fazem o papel da memória de baixo:
// toda vez que ela devolve a linha de wa, a palavra de wa é W; as demais palavras são livres.
// Modo REGION: a memória de baixo muda a palavra vigiada quando uma invalidação por região cobre a linha dela
// (o que o controlador de FLASH faz depois de apagar ou gravar), e a prova exige que nenhum acerto devolva o dado
// velho a partir do quarto ciclo depois do pulso e que um acerto não caia por uma região fora do índice dele.
module props (input clk);
  localparam [5:0] BASE_SDRAM = 6'b010000, BASE_FLASH = 6'b001000;
  localparam [31:0] ROM_BASE = 32'h20000000, ROM_END = 32'h40000000;
  (* anyconst *) wire [31:0] wa;
  (* anyconst *) wire [31:0] W;
  (* anyseq *) wire rst, sel, invalidate, d_ready;
  (* anyseq *) wire [31:0] addr, d_rdata;
  (* anyseq *) wire [95:0] d_rdata_x;
  wire ready, miss, d_rden, d_adv, d_line;
  wire [31:0] data, d_addr;
`ifdef REGION
  (* anyseq *) wire inval_region;
  (* anyseq *) wire [31:0] ifirst, ilast, Wnew;
`else
  wire inval_region = 0;
  wire [31:0] ifirst = 0, ilast = 0;
`endif

  icache dut (.i_clk(clk), .i_clk_cpu(clk), .i_rst(rst), .i_addr(addr), .i_sel(sel), .o_ready(ready), .o_data(data),
    .i_invalidate(invalidate), .i_inval_region(inval_region), .i_inval_first(ifirst), .i_inval_last(ilast), .o_miss(miss), .o_d_addr(d_addr), .o_d_rden(d_rden), .o_d_advance(d_adv),
    .i_d_ready(d_ready), .i_d_rdata(d_rdata), .o_d_line(d_line), .i_d_rdata_x(d_rdata_x));

  function in_rom (input [31:0] x);
    in_rom = x >= ROM_BASE && x < ROM_END;
  endfunction

  // A linha de wa como a memória de baixo a vê, e a posição da palavra de wa nela.
  wire [31:0] wline = {in_rom(wa) ? BASE_FLASH : BASE_SDRAM, wa[25:4], 4'b0000};
  wire [1:0] k = wa[3:2];

  // A palavra vigiada como a memória de baixo a tem: constante, ou trocada pela região no modo REGION.
`ifdef REGION
  (* anyinit *) reg [31:0] Wm;
  wire [31:0] Wcur = Wm;
`else
  wire [31:0] Wcur = W;
`endif
  // A região pedida cobre a linha vigiada por endereço, e o índice dela por posição na cache (duas linhas).
  wire span_ok = ilast[31:4] >= ifirst[31:4];
  wire covers_line = inval_region && span_ok && wa[31:4] >= ifirst[31:4] && wa[31:4] <= ilast[31:4];
  wire covers_index = inval_region && span_ok && ((ilast[31:4] - ifirst[31:4] >= 1) || ifirst[4] == wa[4]);

  reg f_past_valid = 0;
  reg p_d_rden = 0, p_d_ready = 0, p_sel = 0, p_ready = 0;
  reg [31:0] p_addr = 0;
  reg p_inv = 0;
  reg [3:0] f_wait = 0;
  // Depois de uma invalidação o cache não acerta nada até um preenchimento novo começar.
  reg stale = 0;
  reg [2:0] stale_age = 0;
  always @(posedge clk) begin
    f_past_valid <= 1;
    p_inv <= invalidate;
    p_d_rden <= d_rden; p_d_ready <= d_ready; p_sel <= sel; p_addr <= addr; p_ready <= ready;
    f_wait <= (d_rden && !d_ready) ? f_wait + 1 : 0;
`ifdef REGION
    if (covers_line) Wm <= Wnew;
`endif
    if (invalidate) begin stale <= 1; stale_age <= 0; end
    else begin
      if (miss) stale <= 0;
      if (stale_age != 3'd7) stale_age <= stale_age + 1;
    end
  end

  // ---- o ambiente ----
  always @* if (!f_past_valid) assume (rst);
  always @* if (f_past_valid) assume (!rst);
  // os endereços do núcleo ficam na mesma janela de 64 MiB do endereço vigiado (a etiqueta guarda os bits 25 a 4)
  always @* assume (addr[31:26] == wa[31:26]);
  // o núcleo mantém o endereço do pedido até o cache responder: trocar o endereço no meio de um preenchimento
  // faria o cache ver as palavras novas da linha que chega com a etiqueta e o bit de validade da linha velha
  always @(posedge clk) if (f_past_valid && p_sel && !p_ready) assume (sel && addr == p_addr);
  // a memória de baixo responde só a um pedido ativo, em até 3 ciclos, e devolve a palavra de wa na linha de wa
  always @* begin
    if (d_ready) assume (d_rden);
    assume (!(f_wait == 3 && d_rden));
    if (d_addr[31:4] == wline[31:4]) begin
      if (k == 2'd0) assume (d_rdata == Wcur);
      else assume (d_rdata_x[32 * (k - 1) +: 32] == Wcur);
    end
  end

  always @(posedge clk) if (f_past_valid) begin
    // 1. Um acerto no endereço vigiado devolve o dado que a memória de baixo deu para ele.
`ifndef REGION
    if (ready && addr[31:2] == wa[31:2]) assert (data == W);
`endif
    // 2. O pedido à memória de baixo é de uma linha inteira, alinhada, e o avanço é a resposta dela.
    if (d_rden) assert (d_line && d_addr[3:0] == 4'b0000);
    assert (d_adv == d_ready);
    // 3. A invalidação limpa: a partir do segundo ciclo depois dela, nenhum acerto antes de um preenchimento novo
    //    (um preenchimento em andamento na invalidação é descartado).
    if (stale && stale_age >= 2) assert (!ready);
    // 4. Sem pedido do núcleo não há acerto.
    if (!p_sel) assert (!ready);
  end

`ifdef REGION
  // Depois de uma região que cobre a linha vigiada, o acerto devolve o dado atual da memória de baixo (a partir do
  // quarto ciclo depois do pulso), e uma região fora do índice da linha não derruba o acerto que a cache já tinha.
  reg [2:0] r_age = 3'd7;
  reg held = 0;
  reg [2:0] c_age = 3'd0;
  always @(posedge clk) begin
    if (invalidate || covers_index) c_age <= 0; else if (c_age != 3'd7) c_age <= c_age + 1;
    if (covers_line) r_age <= 0; else if (r_age != 3'd7) r_age <= r_age + 1;
    held <= ready && addr[31:4] == wa[31:4] && sel && !invalidate && !covers_index && c_age >= 4;
  end
  always @(posedge clk) if (f_past_valid) begin
    if (ready && addr[31:2] == wa[31:2] && r_age >= 3) assert (data == Wm);
    if (held && sel && addr == p_addr && !invalidate && !p_inv) assert (ready);
  end
`endif

`ifdef COVER
  always @(posedge clk) if (f_past_valid) begin
`ifdef REGION
    cover (covers_line && Wnew != Wm);
    cover (ready && addr[31:2] == wa[31:2] && r_age == 3'd7 && Wm != 0);
    cover (inval_region && !covers_index);
`endif
    cover (ready && addr[31:2] == wa[31:2] && W != 0);
    cover (miss);
    cover (invalidate && d_rden);
    cover (!stale && ready);
  end
`endif
endmodule
