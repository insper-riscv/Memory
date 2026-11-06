// Propriedades do latency_counter, verificadas na netlist Verilog que o GHDL sintetiza do VHDL, com max_count de 6
// (a lógica é a mesma dos outros valores). O pulso de carga, o valor e o reset são entradas livres, presas ao
// contrato por suposições. Um oráculo escrito aqui, sem olhar o contador, diz em que borda cada saída sobe: depois
// da carga de N (N = 0 vale 1) a borda seguinte é a E1, o_last vale na E_N e só nela, o_wait vale de E1 a E_(N-1), uma
// carga na borda do fim reinicia a contagem, e sem carga a contagem termina e o bloco fica livre. O registrador cnt
// (dbg_cnt, adicionado a uma cópia da netlist) entra só no invariante que torna a prova ilimitada: as bordas que
// faltam são n - age + 1 enquanto a contagem vive, e zero fora dela.
module props (input clk);
  localparam [2:0] MAXC = 3'd6;
  (* anyseq *) wire rst, load;
  (* anyseq *) wire [2:0] count;
  wire last, wait_more;
  wire [2:0] d_cnt;

  latency_counter dut (.i_clk(clk), .i_rst(rst), .i_load(load), .i_count(count), .o_last(last), .o_wait(wait_more),
    .dbg_cnt(d_cnt));

  // O oráculo: se há contagem viva, o total n e a borda age que a próxima vê.
  reg armed = 0;
  reg [2:0] n = 0, age = 0;
  reg f_past_valid = 0;
  always @(posedge clk) begin
    f_past_valid <= 1;
    if (rst) armed <= 0;
    else if (load) begin
      armed <= 1;
      n <= (count == 0) ? 3'd1 : count;
      age <= 3'd1;
    end else if (armed) begin
      if (age == n) armed <= 0;
      else age <= age + 3'd1;
    end
  end

  // ---- o ambiente ----
  always @* assume (count <= MAXC);
  always @* if (!f_past_valid) assume (rst);

  // ---- o contrato ----
  always @* begin
    // 1. O fim e a espera sobem onde o oráculo manda, e nunca juntos.
    assert (last == (armed && age == n));
    assert (wait_more == (armed && age < n));
    assert (!(last && wait_more));
    // 2. Invariante da prova ilimitada: o contador guarda as bordas que faltam.
    if (armed) begin
      assert (age >= 1 && age <= n && n >= 1 && n <= MAXC);
      assert (d_cnt == n - age + 3'd1);
    end else assert (d_cnt == 0);
  end

`ifdef COVER
  always @(posedge clk) if (f_past_valid) begin
    cover (last && n == 6);
    cover (last && n == 1);
    cover (last && load && !rst);
    cover (wait_more && rst);
    cover (wait_more && load && !rst);
    cover (!armed && load && count == 0 && !rst);
  end
`endif
endmodule
