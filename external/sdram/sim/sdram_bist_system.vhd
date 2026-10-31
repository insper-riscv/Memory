-- =============================================================================
-- Topo de simulação do autoteste da SDRAM
--
-- O autoteste ligado direto ao controlador e ao modelo do chip, em um único
-- clock (a configuração de bring-up da placa).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;

entity sdram_bist_system is
  generic (
    -- Log2 do número de palavras da janela.
    window_log2 : natural := 8;
    -- Log2 do número de palavras da varredura.
    sweep_log2  : natural := 10;
    -- Log2 do número de palavras do modo aleatório.
    random_log2 : natural := 8;
    -- Clocks extras antes de amostrar o dado lido.
    capture_extra : natural := 0
  );
  port (
    -- Clock do módulo.
    i_clk        : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst        : in  std_logic;
    -- Inicia uma execução na borda de subida.
    i_start      : in  std_logic;
    -- Modo da execução: 0 rápido, 1 padrões, 2 varredura, 3 aleatório.
    i_mode       : in  std_logic_vector(1 downto 0);
    -- A inicialização da SDRAM terminou ('1').
    o_init_done  : out std_logic;
    -- O módulo está ocupado ('1').
    o_busy : out std_logic;
    -- Uma execução terminou.
    o_done : out std_logic;
    -- Uma palavra diferiu ou o controlador não respondeu.
    o_fail : out std_logic;
    -- O controlador não respondeu dentro do prazo.
    o_timeout : out std_logic;
    -- Fase da execução em andamento.
    o_phase      : out std_logic_vector(4 downto 0);
    -- Quantidade de palavras que diferiram.
    o_err_count  : out std_logic_vector(31 downto 0);
    -- Endereço da primeira palavra que diferiu.
    o_first_addr : out std_logic_vector(23 downto 0);
    -- Valor esperado na primeira palavra que diferiu.
    o_first_exp  : out std_logic_vector(31 downto 0);
    -- Valor lido na primeira palavra que diferiu.
    o_first_got  : out std_logic_vector(31 downto 0);
    -- Quantidade de palavras já movidas.
    o_ops_done   : out std_logic_vector(31 downto 0);

    -- Endereço de palavra lido diretamente do modelo do chip, para depuração.
    i_dbg_word_addr : in  std_logic_vector(23 downto 0);
    -- Palavra do modelo do chip no endereço de dbg_word_addr.
    o_dbg_word_data : out std_logic_vector(31 downto 0);
    -- Pulso que inverte um bit de uma palavra armazenada, para provar que uma verificação nota a corrupção.
    i_dbg_flip      : in  std_logic;
    -- Endereço de palavra cujo bit é invertido.
    i_dbg_flip_addr : in  std_logic_vector(23 downto 0);
    -- Posição do bit invertido na palavra.
    i_dbg_flip_bit  : in  std_logic_vector(4 downto 0);
    -- Contagem de comandos AUTO REFRESH recebidos pelo chip.
    o_dbg_refreshes : out std_logic_vector(31 downto 0)
  );
end entity sdram_bist_system;

architecture rtl of sdram_bist_system is
  -- Alternância de pedido do autoteste ao controlador.
  signal req_tog : std_logic;
  -- Alternância de confirmação do controlador.
  signal ack_tog : std_logic;
  -- A inicialização da SDRAM terminou.
  signal init_i : std_logic;
  -- Escrita ('1') do autoteste.
  signal c_we : std_logic;
  -- Endereço de palavra do autoteste.
  signal c_addr  : std_logic_vector(23 downto 0);
  -- Dado de escrita do autoteste.
  signal c_wdata : std_logic_vector(31 downto 0);
  -- Dado lido pelo autoteste.
  signal c_rdata : std_logic_vector(31 downto 0);
  -- Habilita de bytes da escrita do autoteste.
  signal c_be    : std_logic_vector(3 downto 0);
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
  signal dq : std_logic_vector(15 downto 0);
  -- Dado que o controlador coloca nos pinos DQ.
  signal dq_out : std_logic_vector(15 downto 0);
  -- O controlador dirige os pinos DQ ('1').
  signal dq_oe : std_logic;
  -- Dado lido dos pinos DQ, registrado.
  signal dq_in_r : std_logic_vector(15 downto 0);
  -- A sequência de energização do chip foi aceita.
  signal init_ok : std_logic;
begin

  o_init_done <= init_i;

  u_bist : entity work.sdram_bist
    generic map (window_log2 => window_log2, sweep_log2 => sweep_log2, random_log2 => random_log2)
    port map (
      i_clk => i_clk, i_rst => i_rst, i_start => i_start, i_mode => i_mode, i_init_done => init_i,
      o_busy => o_busy, o_done => o_done, o_fail => o_fail, o_timeout => o_timeout, o_phase => o_phase,
      o_err_count => o_err_count, o_first_addr => o_first_addr, o_first_exp => o_first_exp,
      o_first_got => o_first_got, o_ops_done => o_ops_done,
      o_c_req_tog => req_tog, i_c_ack_tog => ack_tog, o_c_we => c_we, o_c_addr => c_addr,
      o_c_wdata => c_wdata, o_c_be => c_be, i_c_rdata => c_rdata
    );

  u_ctrl : entity work.sdram_ctrl
    generic map (capture_extra => capture_extra)
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_req_tog => req_tog, o_ack_tog => ack_tog, o_init_done => init_i,
      i_we => c_we, i_addr => c_addr, i_wdata => c_wdata, i_be => c_be, o_rdata => c_rdata,
      o_dram_cke => cke, o_dram_cs_n => cs_n, o_dram_ras_n => ras_n, o_dram_cas_n => cas_n,
      o_dram_we_n => we_n, o_dram_ba => ba, o_dram_addr => a, o_dram_dqm => dqm,
      o_dram_dq_out => dq_out, o_dram_dq_oe => dq_oe, i_dram_dq_in => dq_in_r
    );

  dq <= dq_out when dq_oe = '1' else (others => 'Z');

  -- os pinos são registrados uma vez na entrada, como fazem as células de E/S da placa
  gen_registered : if capture_extra = 1 generate
    process (i_clk)
    begin
      if rising_edge(i_clk) then
        dq_in_r <= dq;
      end if;
    end process;
  end generate;
  gen_direct : if capture_extra = 0 generate
    dq_in_r <= dq;
  end generate;

  u_chip : entity work.sdram_model
    port map (
      i_clk => i_clk, i_cke => cke, i_cs_n => cs_n, i_ras_n => ras_n, i_cas_n => cas_n,
      i_we_n => we_n, i_ba => ba, i_a => a, i_dqm => dqm, io_dq => dq, i_reinit => i_rst,
      i_dbg_word_addr => i_dbg_word_addr, o_dbg_word_data => o_dbg_word_data,
      i_dbg_flip => i_dbg_flip, i_dbg_flip_addr => i_dbg_flip_addr, i_dbg_flip_bit => i_dbg_flip_bit,
      o_dbg_refreshes => o_dbg_refreshes, o_dbg_init_ok => init_ok
    );

end architecture rtl;
