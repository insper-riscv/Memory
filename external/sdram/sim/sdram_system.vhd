-- =============================================================================
-- Topo de simulação do subsistema SDRAM
--
-- A ponte, a porta de debug, o controlador e o modelo do chip em dois clocks,
-- mais o clock JTAG. O lado do core é a lista de portas que um core conduziria;
-- as portas de debug chegam ao modelo (veja sdram_model); as portas jtag_*
-- representam uma instância do Virtual JTAG (veja sdram_jtag_core) e podem ficar
-- sem conexão.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;

entity sdram_system is
  generic (
    -- Período do clock em picossegundos.
    tck_ps         : natural := T_CK_PS;
    -- Ciclos de espera após a energização antes do primeiro comando.
    init_cycles    : natural := cycles(T_INIT_PS, T_CK_PS);
    -- Ciclos entre dois refreshes.
    refresh_cycles : natural := cycles(T_REFI_PS, T_CK_PS) * 9 / 10;
    -- Arquivo com a imagem inicial do chip.
    init_file      : string  := ""
  );
  port (
    -- Clock do lado do controlador SDRAM.
    i_clk_mem     : in  std_logic;
    -- Clock do lado do core.
    i_clk_cpu     : in  std_logic;
    -- Reset do lado do controlador SDRAM, ativo em '1'.
    i_rst_mem     : in  std_logic;
    -- Reset do lado do core, ativo em '1'.
    i_rst_cpu     : in  std_logic;

    -- Endereço do acesso.
    i_addr        : in  std_logic_vector(31 downto 0);
    -- Dado de escrita.
    i_wdata       : in  std_logic_vector(31 downto 0);
    -- Habilita de bytes da escrita, um bit por byte.
    i_byteena     : in  std_logic_vector(3 downto 0);
    -- Pedido de leitura ('1' = lê).
    i_rden        : in  std_logic;
    -- Pedido de escrita ('1' = escreve).
    i_wren        : in  std_logic;
    -- O pipeline avançou neste ciclo, o acesso em andamento pode ser concluído.
    i_mem_advance : in  std_logic;
    -- Acesso concluído, o dado lido é válido ('1').
    o_ready       : out std_logic;
    -- Dado lido.
    o_rdata       : out std_logic_vector(31 downto 0);
    -- Acesso de linha, quatro palavras seguidas ('1').
    i_line        : in  std_logic := '0';
    -- Palavras 1 a 3 do dado de escrita da linha.
    i_wdata_x     : in  std_logic_vector(95 downto 0) := (others => '0');
    -- Habilita de bytes das palavras 1 a 3 da linha.
    i_byteena_x   : in  std_logic_vector(11 downto 0) := (others => '0');
    -- Palavras 1 a 3 do dado lido da linha.
    o_rdata_x     : out std_logic_vector(95 downto 0);

    -- Porta do mestre I (ponte de instruções do core): endereço de palavra.
    i_ins_addr      : in  std_logic_vector(31 downto 0) := (others => '0');
    -- Pedido de leitura da ponte de instruções ('1' = lê).
    i_ins_rden      : in  std_logic := '0';
    -- O pipeline avançou neste ciclo (ponte de instruções).
    i_ins_advance   : in  std_logic := '0';
    -- Acesso da ponte de instruções concluído ('1').
    o_ins_ready     : out std_logic;
    -- Porta do mestre I (ponte de instruções do core): dado lido.
    o_ins_rdata     : out std_logic_vector(31 downto 0);
    -- Porta do mestre I (ponte de instruções do core): acesso de linha de quatro palavras ('1').
    i_ins_line      : in  std_logic := '0';
    -- Porta do mestre I (ponte de instruções do core): palavras 1 a 3 do dado lido da linha.
    o_ins_rdata_x   : out std_logic_vector(95 downto 0);

    -- A inicialização da SDRAM terminou ('1').
    o_init_done       : out std_logic;
    -- Endereço de palavra lido diretamente do modelo do chip, para depuração.
    i_dbg_word_addr   : in  std_logic_vector(23 downto 0);
    -- Palavra do modelo do chip no endereço de dbg_word_addr.
    o_dbg_word_data   : out std_logic_vector(31 downto 0);
    -- Pulso que inverte um bit de uma palavra armazenada, para provar que uma verificação nota a corrupção.
    i_dbg_flip        : in  std_logic;
    -- Endereço de palavra cujo bit é invertido.
    i_dbg_flip_addr   : in  std_logic_vector(23 downto 0);
    -- Posição do bit invertido na palavra.
    i_dbg_flip_bit    : in  std_logic_vector(4 downto 0);
    -- Contagem de comandos AUTO REFRESH recebidos pelo chip.
    o_dbg_refreshes   : out std_logic_vector(31 downto 0);
    -- A sequência de inicialização do chip foi aceita ('1').
    o_dbg_init_ok     : out std_logic;

    -- Clock da cadeia JTAG.
    i_jtag_tck        : in  std_logic := '0';
    -- Dado serial vindo do hospedeiro.
    i_jtag_tdi        : in  std_logic := '0';
    -- Dado serial para o hospedeiro.
    o_jtag_tdo        : out std_logic;
    -- Registrador de instrução do Virtual JTAG.
    i_jtag_ir_in      : in  std_logic_vector(1 downto 0) := "00";
    -- Estado Capture-DR da cadeia virtual.
    i_jtag_state_cdr  : in  std_logic := '0';
    -- Estado Shift-DR da cadeia virtual.
    i_jtag_state_sdr  : in  std_logic := '0';
    -- Estado Update-DR da cadeia virtual.
    i_jtag_state_udr  : in  std_logic := '0';
    -- Estado Update-IR da cadeia virtual.
    i_jtag_state_uir  : in  std_logic := '0'
  );
end entity sdram_system;

architecture rtl of sdram_system is
  -- Alternância de pedido da ponte de dados ao árbitro.
  signal req_tog : std_logic;
  -- Alternância de confirmação do árbitro à ponte de dados.
  signal ack_tog : std_logic;
  -- A inicialização da SDRAM terminou.
  signal init_i : std_logic;
  -- Escrita ('1') do controlador.
  signal c_we : std_logic;
  -- Endereço de palavra do controlador.
  signal c_addr  : std_logic_vector(23 downto 0);
  -- Dado de escrita do controlador.
  signal c_wdata : std_logic_vector(31 downto 0);
  -- Dado lido do controlador.
  signal c_rdata : std_logic_vector(31 downto 0);
  -- Acesso de linha do controlador.
  signal c_line  : std_logic;
  -- Palavras 1 a 3 de escrita de linha do controlador.
  signal c_wdx : std_logic_vector(95 downto 0);
  -- Palavras 1 a 3 lidas da linha do controlador.
  signal c_rdx : std_logic_vector(95 downto 0);
  -- Habilita de bytes das palavras 1 a 3 do controlador.
  signal c_bex   : std_logic_vector(11 downto 0);
  -- Acesso de linha do mestre A (ponte de dados).
  signal a_line  : std_logic;
  -- Palavras 1 a 3 de escrita de linha do mestre A (ponte de dados).
  signal a_wdx : std_logic_vector(95 downto 0);
  -- Palavras 1 a 3 lidas da linha do mestre A (ponte de dados).
  signal a_rdx : std_logic_vector(95 downto 0);
  -- Habilita de bytes das palavras 1 a 3 do mestre A (ponte de dados).
  signal a_bex   : std_logic_vector(11 downto 0);
  -- Habilita de bytes do controlador.
  signal c_be    : std_logic_vector(3 downto 0);

  -- Alternância de pedido do mestre A (ponte de dados).
  signal a_req : std_logic;
  -- Alternância de confirmação do mestre A (ponte de dados).
  signal a_ack : std_logic;
  -- Escrita ('1') do mestre A (ponte de dados).
  signal a_we : std_logic;
  -- Endereço de palavra do mestre A (ponte de dados).
  signal a_addr  : std_logic_vector(23 downto 0);
  -- Dado de escrita do mestre A (ponte de dados).
  signal a_wdata : std_logic_vector(31 downto 0);
  -- Dado lido do mestre A (ponte de dados).
  signal a_rdata : std_logic_vector(31 downto 0);
  -- Habilita de bytes do mestre A (ponte de dados).
  signal a_be    : std_logic_vector(3 downto 0);
  -- Alternância de pedido do mestre I (ponte de instruções).
  signal i_req : std_logic;
  -- Alternância de confirmação do mestre I.
  signal i_ack : std_logic;
  -- Escrita ('1') do mestre I.
  signal i_we : std_logic;
  -- Endereço de palavra do mestre I (ponte de instruções).
  signal i_caddr  : std_logic_vector(23 downto 0);
  -- Dado de escrita do mestre I (ponte de instruções).
  signal i_cwdata : std_logic_vector(31 downto 0);
  -- Dado lido do mestre I (ponte de instruções).
  signal i_crdata : std_logic_vector(31 downto 0);
  -- Habilita de bytes do mestre I (ponte de instruções).
  signal i_cbe    : std_logic_vector(3 downto 0);
  -- Acesso de linha do mestre I (ponte de instruções).
  signal i_cline  : std_logic;
  -- Palavras 1 a 3 de escrita de linha do mestre I (ponte de instruções).
  signal i_cwdx : std_logic_vector(95 downto 0);
  -- Palavras 1 a 3 lidas da linha do mestre I (ponte de instruções).
  signal i_crdx : std_logic_vector(95 downto 0);
  -- Habilita de bytes das palavras 1 a 3 do mestre I (ponte de instruções).
  signal i_cbex   : std_logic_vector(11 downto 0);
  -- Alternância de pedido do mestre B (debug).
  signal b_req : std_logic;
  -- Alternância de confirmação do mestre B (debug).
  signal b_ack : std_logic;
  -- Escrita ('1') do mestre B (debug).
  signal b_we : std_logic;
  -- Endereço de palavra do mestre B (debug).
  signal b_addr  : std_logic_vector(23 downto 0);
  -- Dado de escrita do mestre B (debug).
  signal b_wdata : std_logic_vector(31 downto 0);
  -- Dado lido do mestre B (debug).
  signal b_rdata : std_logic_vector(31 downto 0);
  -- Habilita de bytes do mestre B (debug).
  signal b_be    : std_logic_vector(3 downto 0);

  -- Alternância de comando do hospedeiro ao mestre de debug.
  signal cmd_tog : std_logic;
  -- Alternância de conclusão do mestre de debug.
  signal done_tog : std_logic;
  -- Operação do comando de debug.
  signal d_op : std_logic_vector(3 downto 0);
  -- Habilita de bytes do comando de debug.
  signal d_be : std_logic_vector(3 downto 0);
  -- Endereço do comando de debug.
  signal d_addr : std_logic_vector(23 downto 0);
  -- Endereço da resposta do comando de debug.
  signal r_addr : std_logic_vector(23 downto 0);
  -- Dado do comando de debug.
  signal d_data : std_logic_vector(31 downto 0);
  -- Dado da resposta do comando de debug.
  signal r_data : std_logic_vector(31 downto 0);
  -- Status da resposta do comando de debug.
  signal r_status : std_logic_vector(7 downto 0);

  -- Habilita de clock (CKE) do chip.
  signal cke : std_logic;
  -- Seleção do chip, ativa em '0'.
  signal cs_n : std_logic;
  -- Strobe de endereço de linha, ativo em '0'.
  signal ras_n : std_logic;
  -- Strobe de endereço de coluna, ativo em '0'.
  signal cas_n : std_logic;
  -- Habilita de escrita, ativo em '0'.
  signal we_n : std_logic;
  -- Seleção do banco.
  signal ba   : std_logic_vector(1 downto 0);
  -- Endereço de linha ou de coluna.
  signal a    : std_logic_vector(12 downto 0);
  -- Máscara de bytes dos dados.
  signal dqm  : std_logic_vector(1 downto 0);
  -- Pinos de dados DQ.
  signal dq   : std_logic_vector(15 downto 0);
  -- Dado que o controlador coloca nos pinos DQ.
  signal dq_out : std_logic_vector(15 downto 0);
  -- O controlador dirige os pinos DQ ('1').
  signal dq_oe  : std_logic;
begin

  o_init_done <= init_i;

  u_bridge : entity work.sdram_cpu_bridge
    port map (
      i_clk_cpu => i_clk_cpu, i_rst_cpu => i_rst_cpu,
      i_addr => i_addr, i_wdata => i_wdata, i_byteena => i_byteena, i_rden => i_rden, i_wren => i_wren,
      i_mem_advance => i_mem_advance, o_ready => o_ready, o_rdata => o_rdata,
      i_line => i_line, i_wdata_x => i_wdata_x, i_byteena_x => i_byteena_x, o_rdata_x => o_rdata_x,
      o_req_tog => a_req, i_ack_tog => a_ack, i_init_done => init_i,
      o_c_we => a_we, o_c_addr => a_addr, o_c_wdata => a_wdata, o_c_be => a_be, i_c_rdata => a_rdata,
      o_c_line => a_line, o_c_wdata_x => a_wdx, o_c_be_x => a_bex, i_c_rdata_x => a_rdx
    );

  u_ibridge : entity work.sdram_cpu_bridge
    port map (
      i_clk_cpu => i_clk_cpu, i_rst_cpu => i_rst_cpu,
      i_addr => i_ins_addr, i_wdata => (others => '0'), i_byteena => (others => '0'), i_rden => i_ins_rden, i_wren => '0',
      i_mem_advance => i_ins_advance, o_ready => o_ins_ready, o_rdata => o_ins_rdata,
      i_line => i_ins_line, i_wdata_x => (others => '0'), i_byteena_x => (others => '0'), o_rdata_x => o_ins_rdata_x,
      o_req_tog => i_req, i_ack_tog => i_ack, i_init_done => init_i,
      o_c_we => i_we, o_c_addr => i_caddr, o_c_wdata => i_cwdata, o_c_be => i_cbe, i_c_rdata => i_crdata,
      o_c_line => i_cline, o_c_wdata_x => i_cwdx, o_c_be_x => i_cbex, i_c_rdata_x => i_crdx
    );

  u_jtag : entity work.sdram_jtag_core
    port map (
      i_tck => i_jtag_tck, i_tdi => i_jtag_tdi, o_tdo => o_jtag_tdo, i_ir_in => i_jtag_ir_in,
      i_state_cdr => i_jtag_state_cdr, i_state_sdr => i_jtag_state_sdr,
      i_state_udr => i_jtag_state_udr, i_state_uir => i_jtag_state_uir,
      o_cmd_tog => cmd_tog, o_op => d_op, o_be => d_be, o_addr => d_addr, o_data => d_data,
      i_done_tog => done_tog, i_rsp_addr => r_addr, i_rsp_data => r_data, i_rsp_status => r_status
    );

  u_dbg : entity work.sdram_dbg_master
    port map (
      i_clk => i_clk_mem, i_rst => i_rst_mem,
      i_cmd_tog => cmd_tog, o_done_tog => done_tog, i_op => d_op, i_be => d_be, i_addr => d_addr, i_data => d_data,
      o_rsp_addr => r_addr, o_rsp_data => r_data, o_rsp_status => r_status,
      i_init_done => init_i,
      o_b_req_tog => b_req, i_b_ack_tog => b_ack, o_b_we => b_we, o_b_addr => b_addr,
      o_b_wdata => b_wdata, o_b_be => b_be, i_b_rdata => b_rdata
    );

  u_arb : entity work.sdram_arbiter
    port map (
      i_clk => i_clk_mem, i_rst => i_rst_mem,
      i_a_req_tog => a_req, o_a_ack_tog => a_ack, i_a_we => a_we, i_a_addr => a_addr,
      i_a_wdata => a_wdata, i_a_be => a_be, o_a_rdata => a_rdata,
      i_a_line => a_line, i_a_wdata_x => a_wdx, i_a_be_x => a_bex, o_a_rdata_x => a_rdx,
      i_ins_req_tog => i_req, o_ins_ack_tog => i_ack, i_ins_we => i_we, i_ins_addr => i_caddr,
      i_ins_wdata => i_cwdata, i_ins_be => i_cbe, o_ins_rdata => i_crdata,
      i_ins_line => i_cline, i_ins_wdata_x => i_cwdx, i_ins_be_x => i_cbex, o_ins_rdata_x => i_crdx,
      i_b_req_tog => b_req, o_b_ack_tog => b_ack, i_b_we => b_we, i_b_addr => b_addr,
      i_b_wdata => b_wdata, i_b_be => b_be, o_b_rdata => b_rdata,
      o_c_req_tog => req_tog, i_c_ack_tog => ack_tog, o_c_we => c_we, o_c_addr => c_addr,
      o_c_wdata => c_wdata, o_c_be => c_be, i_c_rdata => c_rdata,
      o_c_line => c_line, o_c_wdata_x => c_wdx, o_c_be_x => c_bex, i_c_rdata_x => c_rdx
    );

  u_ctrl : entity work.sdram_ctrl
    generic map (tck_ps => tck_ps, init_cycles => init_cycles, refresh_cycles => refresh_cycles,
                 sync_req => false)
    port map (
      i_clk => i_clk_mem, i_rst => i_rst_mem,
      i_req_tog => req_tog, o_ack_tog => ack_tog, o_init_done => init_i,
      i_we => c_we, i_addr => c_addr, i_wdata => c_wdata, i_be => c_be, o_rdata => c_rdata,
      i_line => c_line, i_wdata_x => c_wdx, i_be_x => c_bex, o_rdata_x => c_rdx,
      o_dram_cke => cke, o_dram_cs_n => cs_n, o_dram_ras_n => ras_n, o_dram_cas_n => cas_n,
      o_dram_we_n => we_n, o_dram_ba => ba, o_dram_addr => a, o_dram_dqm => dqm,
      o_dram_dq_out => dq_out, o_dram_dq_oe => dq_oe, i_dram_dq_in => dq
    );

  -- os pinos: o controlador os dirige com o seu habilita de saída, o modelo nos outros casos
  dq <= dq_out when dq_oe = '1' else (others => 'Z');

  u_chip : entity work.sdram_model
    generic map (tck_ps => tck_ps, init_file => init_file)
    port map (
      i_clk => i_clk_mem, i_cke => cke, i_cs_n => cs_n, i_ras_n => ras_n, i_cas_n => cas_n,
      i_we_n => we_n, i_ba => ba, i_a => a, i_dqm => dqm, io_dq => dq, i_reinit => i_rst_mem,
      i_dbg_word_addr => i_dbg_word_addr, o_dbg_word_data => o_dbg_word_data,
      i_dbg_flip => i_dbg_flip, i_dbg_flip_addr => i_dbg_flip_addr, i_dbg_flip_bit => i_dbg_flip_bit,
      o_dbg_refreshes => o_dbg_refreshes, o_dbg_init_ok => o_dbg_init_ok
    );

end architecture rtl;
