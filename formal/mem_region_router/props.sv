// Propriedades do mem_region_router, verificadas na netlist Verilog que o GHDL sintetiza do VHDL, com os
// valores padrão dos genéricos (flash de 0x20000000 a 0x40000000, janela de 1 MiB). O núcleo e os dois lados
// (o resto da memória e a flash) são entradas livres; o único registrador (a resposta local) é exposto.
// O contrato: fora da flash o acesso vai ao resto da memória; na flash vai à flash só como leitura dentro da
// janela; escrita na flash e leitura além da janela terminam no próprio roteador, devolvendo zero, sem travar.
module props (input clk);
  localparam [31:0] BASE = 32'h20000000, END = 32'h40000000, WIN_END = 32'h20100000;
  (* anyseq *) wire rst;
  (* anyseq *) wire [31:0] addr, wdata, s_rdata, f_rdata;
  (* anyseq *) wire [3:0] byteena;
  (* anyseq *) wire [95:0] wdata_x, s_rdata_x, f_rdata_x;
  (* anyseq *) wire rden, wren, line, advance, s_ready, f_ready;
  wire ready, s_rden, s_wren, s_line, s_adv, f_rden, f_line, f_adv, d_local;
  wire [31:0] rdata, s_addr, s_wdata, f_addr;
  wire [3:0] s_byteena;
  wire [95:0] rdata_x, s_wdata_x;

  mem_region_router dut (.i_clk(clk), .i_rst(rst),
    .i_addr(addr), .i_wdata(wdata), .i_byteena(byteena), .i_rden(rden), .i_wren(wren), .i_line(line), .i_wdata_x(wdata_x),
    .i_advance(advance), .o_ready(ready), .o_rdata(rdata), .o_rdata_x(rdata_x),
    .o_s_addr(s_addr), .o_s_wdata(s_wdata), .o_s_byteena(s_byteena), .o_s_rden(s_rden), .o_s_wren(s_wren), .o_s_line(s_line),
    .o_s_wdata_x(s_wdata_x), .o_s_advance(s_adv), .i_s_ready(s_ready), .i_s_rdata(s_rdata), .i_s_rdata_x(s_rdata_x),
    .o_f_addr(f_addr), .o_f_rden(f_rden), .o_f_line(f_line), .o_f_advance(f_adv), .i_f_ready(f_ready), .i_f_rdata(f_rdata), .i_f_rdata_x(f_rdata_x),
    .dbg_local_ready(d_local));

  reg f_past_valid = 0, f_past2 = 0;
  reg p_req = 0, p_adv = 0, p_ready = 0, p_rden = 0, p_wren = 0;
  reg [31:0] p_addr = 0;
  reg p_local_req = 0;
  always @(posedge clk) begin
    f_past_valid <= 1; f_past2 <= f_past_valid;
    p_req <= rden || wren; p_rden <= rden; p_wren <= wren; p_adv <= advance; p_ready <= ready; p_addr <= addr;
    p_local_req <= local_req;
  end

  wire in_flash = addr >= BASE && addr < END;
  wire beyond   = addr >= WIN_END;
  wire local_req = in_flash && (wren || (rden && beyond));

  // ---- o ambiente ----
  always @* if (!f_past_valid) assume (rst);
  always @* if (f_past_valid) assume (!rst);
  // o núcleo mantém o pedido e o endereço até avançar, e só avança quando há resposta
  always @(posedge clk) if (f_past_valid && p_req && !p_adv) assume (rden == p_rden && wren == p_wren && addr == p_addr);
  always @* assume (!advance || ready);

  always @* if (f_past_valid) begin
    // 1. Fora da flash, o acesso inteiro vai ao resto da memória e a flash não vê nada.
    if (!in_flash) begin
      assert (s_rden == rden && s_wren == wren && s_adv == advance);
      assert (!f_rden && !f_adv);
      assert (ready == s_ready && rdata == s_rdata && rdata_x == s_rdata_x);
    end
    // 2. Na flash, o resto da memória nunca é acessado.
    if (in_flash) assert (!s_rden && !s_wren && !s_adv);
    // 3. Leitura na janela vai à flash; a resposta e o dado são os da flash.
    if (in_flash && !local_req) begin
      assert (f_rden == rden && f_adv == advance);
      assert (ready == f_ready && rdata == f_rdata && rdata_x == f_rdata_x);
    end
    // 4. Escrita na flash e leitura além da janela não chegam a ninguém; devolvem zero.
    if (local_req) begin
      assert (!f_rden && !f_adv && !s_rden && !s_wren);
      assert (rdata == 32'h0 && rdata_x == 96'h0);
      assert (ready == d_local);
    end
    // 5. No máximo um destino por acesso.
    assert (!(s_rden && f_rden) && !(s_wren && f_rden));
    // 6. Endereço, dado e máscara passam sem mudar.
    assert (s_addr == addr && f_addr == addr && s_wdata == wdata && s_byteena == byteena && s_line == line && f_line == line);
  end

  // 7. Sem travar: um acesso local pendente é concluído no ciclo seguinte, e a resposta cai depois do avanço.
  always @(posedge clk) if (f_past2) begin
    if (p_local_req && !p_ready && !p_adv && local_req) assert (ready);
    if (p_ready && p_adv && p_local_req && !local_req) assert (!d_local);
  end

`ifdef COVER
  always @(posedge clk) if (f_past_valid) begin
    cover (local_req && ready && wren);
    cover (local_req && ready && rden);
    cover (in_flash && !local_req && f_rden && ready);
    cover (!in_flash && s_rden && ready);
  end
`endif
endmodule
