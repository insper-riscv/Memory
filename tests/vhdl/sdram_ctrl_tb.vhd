-- =============================================================================
-- Testbench do controlador SDRAM contra o modelo do chip
--
-- O controlador e o modelo do chip no mesmo clock. Os pinos do chip ficam
-- dentro do testbench; o cocotb conduz só o pedido (alternância, endereço,
-- dado) e lê as portas de depuração do modelo. O modelo falha a simulação
-- diante de qualquer regra do chip quebrada (tempos, ordem de comandos,
-- inicialização, intervalo de refresh), então uma execução sem falha também
-- prova que o controlador obedece ao chip.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.sdram_pkg.all;

entity sdram_ctrl_tb is
  generic (
    -- Ciclos de espera após a energização antes do primeiro comando.
    init_cycles    : natural := cycles(T_INIT_PS, T_CK_PS);
    -- Ciclos entre dois refreshes.
    refresh_cycles : natural := cycles(T_REFI_PS, T_CK_PS) * 9 / 10
  );
  port (
    -- Clock do controlador e do chip.
    i_clk           : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst           : in  std_logic;
    -- Alternância que pede um acesso.
    i_req_tog       : in  std_logic;
    -- Alternância que confirma o acesso.
    o_ack_tog       : out std_logic;
    -- A inicialização terminou ('1').
    o_init_done     : out std_logic;
    -- Escrita ('1') ou leitura ('0').
    i_we            : in  std_logic;
    -- Endereço de palavra.
    i_addr          : in  std_logic_vector(23 downto 0);
    -- Dado de escrita da palavra 0.
    i_wdata         : in  std_logic_vector(31 downto 0);
    -- Habilita de bytes da palavra 0.
    i_be            : in  std_logic_vector(3 downto 0);
    -- Dado lido da palavra 0.
    o_rdata         : out std_logic_vector(31 downto 0);
    -- Acesso de linha de quatro palavras ('1').
    i_line          : in  std_logic;
    -- Palavras 1 a 3 do dado de escrita da linha.
    i_wdata_x       : in  std_logic_vector(95 downto 0);
    -- Habilita de bytes das palavras 1 a 3.
    i_be_x          : in  std_logic_vector(11 downto 0);
    -- Palavras 1 a 3 do dado lido da linha.
    o_rdata_x       : out std_logic_vector(95 downto 0);
    -- Endereço de palavra lido diretamente do modelo.
    i_dbg_word_addr : in  std_logic_vector(23 downto 0);
    -- Palavra do modelo no endereço de depuração.
    o_dbg_word_data : out std_logic_vector(31 downto 0);
    -- Contagem de AUTO REFRESH recebidos pelo chip.
    o_dbg_refreshes : out std_logic_vector(31 downto 0);
    -- A sequência de inicialização foi aceita pelo chip ('1').
    o_dbg_init_ok   : out std_logic
  );
end entity sdram_ctrl_tb;

architecture rtl of sdram_ctrl_tb is
  -- Habilita de clock do chip.
  signal cke    : std_logic;
  -- Seleção do chip, ativa em '0'.
  signal cs_n   : std_logic;
  -- Strobe de endereço de linha, ativo em '0'.
  signal ras_n  : std_logic;
  -- Strobe de endereço de coluna, ativo em '0'.
  signal cas_n  : std_logic;
  -- Habilita de escrita, ativo em '0'.
  signal we_n   : std_logic;
  -- Seleção do banco.
  signal ba     : std_logic_vector(1 downto 0);
  -- Endereço de linha ou de coluna.
  signal a      : std_logic_vector(12 downto 0);
  -- Máscara de bytes dos dados.
  signal dqm    : std_logic_vector(1 downto 0);
  -- Pinos de dados DQ.
  signal dq     : std_logic_vector(15 downto 0);
  -- Dado que o controlador coloca nos pinos DQ.
  signal dq_out : std_logic_vector(15 downto 0);
  -- O controlador dirige os pinos DQ ('1').
  signal dq_oe  : std_logic;
begin

  u_ctrl : entity work.sdram_ctrl
    generic map (init_cycles => init_cycles, refresh_cycles => refresh_cycles)
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_req_tog => i_req_tog, o_ack_tog => o_ack_tog, o_init_done => o_init_done,
      i_we => i_we, i_addr => i_addr, i_wdata => i_wdata, i_be => i_be, o_rdata => o_rdata,
      i_line => i_line, i_wdata_x => i_wdata_x, i_be_x => i_be_x, o_rdata_x => o_rdata_x,
      o_dram_cke => cke, o_dram_cs_n => cs_n, o_dram_ras_n => ras_n, o_dram_cas_n => cas_n,
      o_dram_we_n => we_n, o_dram_ba => ba, o_dram_addr => a, o_dram_dqm => dqm,
      o_dram_dq_out => dq_out, o_dram_dq_oe => dq_oe, i_dram_dq_in => dq
    );

  -- o controlador dirige os pinos com o seu habilita de saída, o modelo nos outros casos
  dq <= dq_out when dq_oe = '1' else (others => 'Z');

  u_chip : entity work.sdram_model
    generic map (init_file => "")
    port map (
      i_clk => i_clk, i_cke => cke, i_cs_n => cs_n, i_ras_n => ras_n, i_cas_n => cas_n,
      i_we_n => we_n, i_ba => ba, i_a => a, i_dqm => dqm, io_dq => dq, i_reinit => i_rst,
      i_dbg_word_addr => i_dbg_word_addr, o_dbg_word_data => o_dbg_word_data,
      i_dbg_flip => '0', i_dbg_flip_addr => (others => '0'), i_dbg_flip_bit => (others => '0'),
      o_dbg_refreshes => o_dbg_refreshes, o_dbg_init_ok => o_dbg_init_ok
    );

end architecture rtl;
