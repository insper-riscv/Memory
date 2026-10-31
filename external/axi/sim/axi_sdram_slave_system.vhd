-- =============================================================================
-- Topo de simulação do escravo AXI4 da SDRAM
--
-- A ponte escrava e o sistema SDRAM atrás dela, com a porta escravo AXI4 exposta
-- para o testbench fazer o papel do mestre. O modelo do chip pode ser lido sem o
-- barramento (dbg_word_*).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;

entity axi_sdram_slave_system is
  generic (
    -- Período do clock em picossegundos.
    tck_ps         : natural := T_CK_PS;
    -- Ciclos de espera após a energização antes do primeiro comando.
    init_cycles    : natural := cycles(T_INIT_PS, T_CK_PS);
    -- Ciclos entre dois refreshes.
    refresh_cycles : natural := cycles(T_REFI_PS, T_CK_PS) * 9 / 10
  );
  port (
    -- Clock do módulo.
    i_clk         : in  std_logic;
    -- Clock do lado do controlador SDRAM.
    i_clk_mem     : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst         : in  std_logic;
    -- Reset do lado do controlador SDRAM, ativo em '1'.
    i_rst_mem     : in  std_logic;

    -- Porta escravo AXI4, canal de endereço de escrita: validade da transferência ('1' = válida).
    i_s_awvalid   : in  std_logic;
    -- Porta escravo AXI4, canal de endereço de escrita: destino pronto para aceitar a transferência ('1').
    o_s_awready   : out std_logic;
    -- Porta escravo AXI4, canal de endereço de escrita: endereço do primeiro beat.
    i_s_awaddr    : in  std_logic_vector(31 downto 0);
    -- Porta escravo AXI4, canal de endereço de escrita: número de beats da rajada menos um.
    i_s_awlen     : in  std_logic_vector(7 downto 0);
    -- Porta escravo AXI4, canal de endereço de escrita: log2 do número de bytes por beat.
    i_s_awsize    : in  std_logic_vector(2 downto 0);
    -- Porta escravo AXI4, canal de endereço de escrita: tipo de rajada (1 = INCR).
    i_s_awburst   : in  std_logic_vector(1 downto 0);
    -- Porta escravo AXI4, canal de dados de escrita: validade da transferência ('1' = válida).
    i_s_wvalid    : in  std_logic;
    -- Porta escravo AXI4, canal de dados de escrita: destino pronto para aceitar a transferência ('1').
    o_s_wready    : out std_logic;
    -- Porta escravo AXI4, canal de dados de escrita: dados.
    i_s_wdata     : in  std_logic_vector(31 downto 0);
    -- Porta escravo AXI4, canal de dados de escrita: habilita de bytes.
    i_s_wstrb     : in  std_logic_vector(3 downto 0);
    -- Porta escravo AXI4, canal de dados de escrita: último beat da rajada ('1').
    i_s_wlast     : in  std_logic;
    -- Porta escravo AXI4, canal de resposta de escrita: validade da transferência ('1' = válida).
    o_s_bvalid    : out std_logic;
    -- Porta escravo AXI4, canal de resposta de escrita: destino pronto para aceitar a transferência ('1').
    i_s_bready    : in  std_logic;
    -- Porta escravo AXI4, canal de resposta de escrita: resposta (0 = OKAY, 2 = SLVERR).
    o_s_bresp     : out std_logic_vector(1 downto 0);
    -- Porta escravo AXI4, canal de endereço de leitura: validade da transferência ('1' = válida).
    i_s_arvalid   : in  std_logic;
    -- Porta escravo AXI4, canal de endereço de leitura: destino pronto para aceitar a transferência ('1').
    o_s_arready   : out std_logic;
    -- Porta escravo AXI4, canal de endereço de leitura: endereço do primeiro beat.
    i_s_araddr    : in  std_logic_vector(31 downto 0);
    -- Porta escravo AXI4, canal de endereço de leitura: número de beats da rajada menos um.
    i_s_arlen     : in  std_logic_vector(7 downto 0);
    -- Porta escravo AXI4, canal de endereço de leitura: log2 do número de bytes por beat.
    i_s_arsize    : in  std_logic_vector(2 downto 0);
    -- Porta escravo AXI4, canal de endereço de leitura: tipo de rajada (1 = INCR).
    i_s_arburst   : in  std_logic_vector(1 downto 0);
    -- Porta escravo AXI4, canal de dados de leitura: validade da transferência ('1' = válida).
    o_s_rvalid    : out std_logic;
    -- Porta escravo AXI4, canal de dados de leitura: destino pronto para aceitar a transferência ('1').
    i_s_rready    : in  std_logic;
    -- Porta escravo AXI4, canal de dados de leitura: dados.
    o_s_rdata     : out std_logic_vector(31 downto 0);
    -- Porta escravo AXI4, canal de dados de leitura: resposta (0 = OKAY, 2 = SLVERR).
    o_s_rresp     : out std_logic_vector(1 downto 0);
    -- Porta escravo AXI4, canal de dados de leitura: último beat da rajada ('1').
    o_s_rlast     : out std_logic;

    -- A inicialização da SDRAM terminou ('1').
    o_init_done       : out std_logic;
    -- Endereço de palavra lido diretamente do modelo do chip, para depuração.
    i_dbg_word_addr   : in  std_logic_vector(23 downto 0);
    -- Palavra do modelo do chip no endereço de dbg_word_addr.
    o_dbg_word_data   : out std_logic_vector(31 downto 0);
    -- Contagem de comandos AUTO REFRESH recebidos pelo chip.
    o_dbg_refreshes   : out std_logic_vector(31 downto 0);
    -- A sequência de inicialização do chip foi aceita ('1').
    o_dbg_init_ok     : out std_logic
  );
end entity axi_sdram_slave_system;

architecture rtl of axi_sdram_slave_system is
  -- Lado da palavra da ponte escrava AXI4: endereço.
  signal m_addr : std_logic_vector(31 downto 0);
  -- Lado da palavra da ponte escrava AXI4: dado de escrita.
  signal m_wdata : std_logic_vector(31 downto 0);
  -- Lado da palavra da ponte escrava AXI4: dado lido.
  signal m_rdata : std_logic_vector(31 downto 0);
  -- Lado da palavra da ponte escrava AXI4: habilita de bytes.
  signal m_be : std_logic_vector(3 downto 0);
  -- Lado da palavra da ponte escrava AXI4: pedido de leitura.
  signal m_rden : std_logic;
  -- Lado da palavra da ponte escrava AXI4: pedido de escrita.
  signal m_wren : std_logic;
  -- Lado da palavra da ponte escrava AXI4: avanço do acesso.
  signal m_adv : std_logic;
  -- Lado da palavra da ponte escrava AXI4: acesso concluído.
  signal m_ready : std_logic;
  -- Lado da palavra da ponte escrava AXI4: acesso de linha.
  signal m_line : std_logic;
  -- Lado da palavra da ponte escrava AXI4: palavras 1 a 3 da escrita de linha.
  signal m_wdx : std_logic_vector(95 downto 0);
  -- Lado da palavra da ponte escrava AXI4: palavras 1 a 3 da leitura de linha.
  signal m_rdx : std_logic_vector(95 downto 0);
  -- Lado da palavra da ponte escrava AXI4: habilita de bytes das palavras 1 a 3.
  signal m_bex : std_logic_vector(11 downto 0);
begin

  u_slave : entity work.axi_slave_word_bridge
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_s_awvalid => i_s_awvalid, o_s_awready => o_s_awready, i_s_awaddr => i_s_awaddr, i_s_awlen => i_s_awlen,
      i_s_awsize => i_s_awsize, i_s_awburst => i_s_awburst,
      i_s_wvalid => i_s_wvalid, o_s_wready => o_s_wready, i_s_wdata => i_s_wdata, i_s_wstrb => i_s_wstrb, i_s_wlast => i_s_wlast,
      o_s_bvalid => o_s_bvalid, i_s_bready => i_s_bready, o_s_bresp => o_s_bresp,
      i_s_arvalid => i_s_arvalid, o_s_arready => o_s_arready, i_s_araddr => i_s_araddr, i_s_arlen => i_s_arlen,
      i_s_arsize => i_s_arsize, i_s_arburst => i_s_arburst,
      o_s_rvalid => o_s_rvalid, i_s_rready => i_s_rready, o_s_rdata => o_s_rdata, o_s_rresp => o_s_rresp, o_s_rlast => o_s_rlast,
      o_addr => m_addr, o_wdata => m_wdata, o_byteena => m_be, o_rden => m_rden, o_wren => m_wren,
      o_mem_advance => m_adv, i_ready => m_ready, i_rdata => m_rdata,
      o_line => m_line, o_wdata_x => m_wdx, o_byteena_x => m_bex, i_rdata_x => m_rdx
    );

  u_sdram : entity work.sdram_system
    generic map (tck_ps => tck_ps, init_cycles => init_cycles, refresh_cycles => refresh_cycles)
    port map (
      i_clk_mem => i_clk_mem, i_clk_cpu => i_clk, i_rst_mem => i_rst_mem, i_rst_cpu => i_rst,
      i_addr => m_addr, i_wdata => m_wdata, i_byteena => m_be, i_rden => m_rden, i_wren => m_wren,
      i_mem_advance => m_adv, o_ready => m_ready, o_rdata => m_rdata,
      i_line => m_line, i_wdata_x => m_wdx, i_byteena_x => m_bex, o_rdata_x => m_rdx,
      o_init_done => o_init_done,
      i_dbg_word_addr => i_dbg_word_addr, o_dbg_word_data => o_dbg_word_data,
      i_dbg_flip => '0', i_dbg_flip_addr => (others => '0'), i_dbg_flip_bit => (others => '0'),
      o_dbg_refreshes => o_dbg_refreshes, o_dbg_init_ok => o_dbg_init_ok
    );

end architecture rtl;
