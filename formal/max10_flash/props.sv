// Propriedades do max10_flash, verificadas na netlist Verilog que o GHDL sintetiza do VHDL. O ambiente é livre: o
// barramento de registradores, a espera, o dado lido válido, o dado lido e a leitura do CSR da megafunção são entradas
// quaisquer, presas só por uma suposição (só o primeiro ciclo tem reset). O registrador da escrita habilitada (wen) é
// exposto (dbg_wen). As propriedades dizem o que a megafunção nunca recebe, qualquer que seja o software e a resposta dela.
module props (input clk);
  (* anyseq *) wire rst, wr, rd, dwait, drvalid;
  (* anyseq *) wire [2:0] address;
  (* anyseq *) wire [31:0] data_in, drdata, csr_rdata;

  wire [31:0] data_out, d_wdata, csr_wdata;
  wire irq, d_read, d_write, csr_read, csr_write, csr_addr, d_wen;
  wire [3:0] d_addr;

  max10_flash dut (.i_clk(clk), .i_rst(rst), .i_address(address), .i_write(wr), .i_read(rd), .i_data_in(data_in),
    .o_data_out(data_out), .o_irq(irq), .o_data_read(d_read), .o_data_write(d_write), .o_data_addr(d_addr),
    .o_data_wdata(d_wdata), .i_data_wait(dwait), .i_data_rvalid(drvalid), .i_data_rdata(drdata),
    .o_csr_read(csr_read), .o_csr_write(csr_write), .o_csr_addr(csr_addr), .o_csr_wdata(csr_wdata),
    .i_csr_rdata(csr_rdata), .dbg_wen(d_wen));

  // A palavra de controle é de um dos três tipos: libera os setores, protege todos, ou pede o apagar de um setor.
  wire [2:0] sec = csr_wdata[22:20];
  wire ctl_enable = csr_wdata[27:23] == 5'd0 && sec == 3'd7 && csr_wdata[19:0] == 20'hFFFFF;
  wire ctl_disable = csr_wdata[27:23] == 5'h1F && sec == 3'd7 && csr_wdata[19:0] == 20'hFFFFF;
  wire ctl_erase = csr_wdata[27:23] == 5'd0 && sec != 3'd7 && csr_wdata[19:0] == 20'hFFFFF;

  reg f_past_valid = 0;
  reg p_csr_write = 0, p_enable = 0, p_disable = 0, p_wen = 0, p_rst = 0;
  always @(posedge clk) begin
    f_past_valid <= 1;
    p_csr_write <= csr_write; p_enable <= ctl_enable; p_disable <= ctl_disable; p_wen <= d_wen; p_rst <= rst;
  end

  always @* if (!f_past_valid) assume (rst);
  always @* if (f_past_valid) assume (!rst);

  always @(posedge clk) if (f_past_valid) begin
    // 1. A palavra de dado só é escrita com a escrita habilitada.
    if (d_write) assert (d_wen);
    // 2. Um apagar só é pedido com a escrita habilitada, num setor de 1 a 2 (o padrão de erase_allowed).
    if (csr_write && ctl_erase) assert (d_wen && (sec == 3'd1 || sec == 3'd2));
    // 3. Toda escrita no CSR é uma das três palavras: nunca apagar de página, nunca setor 7 com protegido parcial.
    if (csr_write) assert (csr_addr && (ctl_enable || ctl_disable || ctl_erase));
    // 4. Um pedido por vez.
    assert (({2'b0, d_read} + {2'b0, d_write} + {2'b0, csr_read} + {2'b0, csr_write}) <= 3'd1);
    // 5. A escrita habilitada sobe só depois de uma escrita de liberação no CSR, e cai só com reset ou com a proteção.
    if (d_wen && !p_wen) assert (p_csr_write && p_enable);
    if (!d_wen && p_wen) assert (p_rst || (p_csr_write && p_disable));
  end

`ifdef COVER
  always @(posedge clk) if (f_past_valid) begin
    cover (d_write && d_wen);
    cover (csr_write && ctl_erase);
    cover (d_wen && !p_wen);
    cover (!d_wen && p_wen && p_csr_write);
    cover (csr_read);
    cover (d_read);
  end
`endif
endmodule
