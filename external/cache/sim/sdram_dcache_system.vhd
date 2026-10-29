-- =============================================================================
-- Topo de simulação do caminho com cache
--
-- A cache de dados, as pontes mestre e escravo AXI4 e o sistema SDRAM atrás
-- delas. O lado do core é a lista de portas que um core conduziria (a mesma do
-- sdram_system, mais o flush da cache); as portas de debug chegam ao modelo do
-- chip.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;

entity sdram_dcache_system is
  generic (
    -- Verdadeiro: a cache escreve também na memória a cada store.
    write_through  : boolean := false;
    -- Período do clock em picossegundos.
    tck_ps         : natural := T_CK_PS;
    -- Ciclos de espera após a energização antes do primeiro comando.
    init_cycles    : natural := cycles(T_INIT_PS, T_CK_PS);
    -- Ciclos entre dois refreshes.
    refresh_cycles : natural := cycles(T_REFI_PS, T_CK_PS) * 9 / 10
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
    -- Pede a escrita de todas as linhas sujas na memória ('1').
    i_flush       : in  std_logic;
    -- A escrita das linhas sujas terminou ('1').
    o_flush_done  : out std_logic;
    -- O módulo está ocupado ('1').
    o_busy        : out std_logic;

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
    o_dbg_init_ok     : out std_logic
  );
end entity sdram_dcache_system;

architecture rtl of sdram_dcache_system is
  -- Lado da memória da cache: endereço do acesso.
  signal d_addr : std_logic_vector(31 downto 0);
  -- Lado da memória da cache: dado de escrita.
  signal d_wdata : std_logic_vector(31 downto 0);
  -- Lado da memória da cache: dado lido.
  signal d_rdata : std_logic_vector(31 downto 0);
  -- Lado da memória da cache: habilita de bytes da escrita.
  signal d_be      : std_logic_vector(3 downto 0);
  -- Lado da memória da cache: pedido de leitura.
  signal d_rden : std_logic;
  -- Lado da memória da cache: pedido de escrita.
  signal d_wren : std_logic;
  -- Lado da memória da cache: o acesso foi aceito.
  signal d_advance : std_logic;
  -- Lado da memória da cache: acesso concluído.
  signal d_ready : std_logic;
  -- Resposta de erro da ponte mestre AXI4.
  signal d_err : std_logic;
  -- Lado da memória da cache: acesso de linha.
  signal d_line : std_logic;
  -- Lado da memória da cache: palavras 1 a 3 da escrita de linha.
  signal d_wdx : std_logic_vector(95 downto 0);
  -- Lado da memória da cache: palavras 1 a 3 da leitura de linha.
  signal d_rdx : std_logic_vector(95 downto 0);

  -- Barramento AXI4, canal de endereço de escrita: validade da transferência ('1' = válida).
  signal awvalid : std_logic;
  -- Barramento AXI4, canal de endereço de escrita: destino pronto para aceitar a transferência ('1').
  signal awready : std_logic;
  -- Barramento AXI4, canal de dados de escrita: validade da transferência ('1' = válida).
  signal wvalid : std_logic;
  -- Barramento AXI4, canal de dados de escrita: destino pronto para aceitar a transferência ('1').
  signal wready : std_logic;
  -- Barramento AXI4, canal de resposta de escrita: validade da transferência ('1' = válida).
  signal bvalid : std_logic;
  -- Barramento AXI4, canal de resposta de escrita: destino pronto para aceitar a transferência ('1').
  signal bready : std_logic;
  -- Barramento AXI4, canal de dados de escrita: último beat da rajada ('1').
  signal wlast : std_logic;
  -- Barramento AXI4, canal de dados de leitura: último beat da rajada ('1').
  signal rlast : std_logic;
  -- Barramento AXI4, canal de endereço de leitura: validade da transferência ('1' = válida).
  signal arvalid : std_logic;
  -- Barramento AXI4, canal de endereço de leitura: destino pronto para aceitar a transferência ('1').
  signal arready : std_logic;
  -- Barramento AXI4, canal de dados de leitura: validade da transferência ('1' = válida).
  signal rvalid : std_logic;
  -- Barramento AXI4, canal de dados de leitura: destino pronto para aceitar a transferência ('1').
  signal rready : std_logic;
  -- Barramento AXI4, canal de endereço de escrita: endereço do primeiro beat.
  signal awaddr : std_logic_vector(31 downto 0);
  -- Barramento AXI4, canal de dados de escrita: dados.
  signal wdata_a : std_logic_vector(31 downto 0);
  -- Barramento AXI4, canal de endereço de leitura: endereço do primeiro beat.
  signal araddr : std_logic_vector(31 downto 0);
  -- Barramento AXI4, canal de dados de leitura: dados.
  signal rdata_a : std_logic_vector(31 downto 0);
  -- Barramento AXI4, canal de endereço de escrita: número de beats da rajada menos um.
  signal awlen : std_logic_vector(7 downto 0);
  -- Barramento AXI4, canal de endereço de leitura: número de beats da rajada menos um.
  signal arlen : std_logic_vector(7 downto 0);
  -- Barramento AXI4, canal de endereço de escrita: log2 do número de bytes por beat.
  signal awsize : std_logic_vector(2 downto 0);
  -- Barramento AXI4, canal de endereço de leitura: log2 do número de bytes por beat.
  signal arsize : std_logic_vector(2 downto 0);
  -- Barramento AXI4, canal de endereço de escrita: tipo de rajada (1 = INCR).
  signal awburst : std_logic_vector(1 downto 0);
  -- Barramento AXI4, canal de endereço de leitura: tipo de rajada (1 = INCR).
  signal arburst : std_logic_vector(1 downto 0);
  -- Barramento AXI4, canal de endereço de escrita: atributos de proteção.
  signal awprot : std_logic_vector(2 downto 0);
  -- Barramento AXI4, canal de endereço de leitura: atributos de proteção.
  signal arprot : std_logic_vector(2 downto 0);
  -- Barramento AXI4, canal de dados de escrita: habilita de bytes.
  signal wstrb : std_logic_vector(3 downto 0);
  -- Barramento AXI4, canal de resposta de escrita: resposta (0 = OKAY, 2 = SLVERR).
  signal bresp : std_logic_vector(1 downto 0);
  -- Barramento AXI4, canal de dados de leitura: resposta (0 = OKAY, 2 = SLVERR).
  signal rresp : std_logic_vector(1 downto 0);

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

  u_cache : entity work.dcache
    generic map (write_through => write_through)
    port map (
      i_clk => i_clk_cpu, i_rst => i_rst_cpu,
      i_addr => i_addr, i_wdata => i_wdata, i_byteena => i_byteena, i_rden => i_rden, i_wren => i_wren,
      i_mem_advance => i_mem_advance, o_ready => o_ready, o_rdata => o_rdata,
      i_flush => i_flush, o_flush_done => o_flush_done, o_busy => o_busy,
      o_d_addr => d_addr, o_d_wdata => d_wdata, o_d_byteena => d_be, o_d_rden => d_rden, o_d_wren => d_wren,
      o_d_advance => d_advance, i_d_ready => d_ready, i_d_rdata => d_rdata,
      o_d_line => d_line, o_d_wdata_x => d_wdx, i_d_rdata_x => d_rdx
    );

  u_master : entity work.axi_master_bridge
    port map (
      i_clk => i_clk_cpu, i_rst => i_rst_cpu,
      i_addr => d_addr, i_wdata => d_wdata, i_byteena => d_be, i_rden => d_rden, i_wren => d_wren,
      i_mem_advance => d_advance, o_ready => d_ready, o_rdata => d_rdata,
      i_line => d_line, i_wdata_x => d_wdx, i_byteena_x => (others => '1'), o_rdata_x => d_rdx, o_err => d_err,
      o_m_awvalid => awvalid, i_m_awready => awready, o_m_awaddr => awaddr, o_m_awlen => awlen,
      o_m_awsize => awsize, o_m_awburst => awburst, o_m_awprot => awprot,
      o_m_wvalid => wvalid, i_m_wready => wready, o_m_wdata => wdata_a, o_m_wstrb => wstrb, o_m_wlast => wlast,
      i_m_bvalid => bvalid, o_m_bready => bready, i_m_bresp => bresp,
      o_m_arvalid => arvalid, i_m_arready => arready, o_m_araddr => araddr, o_m_arlen => arlen,
      o_m_arsize => arsize, o_m_arburst => arburst, o_m_arprot => arprot,
      i_m_rvalid => rvalid, o_m_rready => rready, i_m_rdata => rdata_a, i_m_rresp => rresp, i_m_rlast => rlast
    );

  u_slave : entity work.axi_slave_word_bridge
    port map (
      i_clk => i_clk_cpu, i_rst => i_rst_cpu,
      i_s_awvalid => awvalid, o_s_awready => awready, i_s_awaddr => awaddr, i_s_awlen => awlen,
      i_s_awsize => awsize, i_s_awburst => awburst,
      i_s_wvalid => wvalid, o_s_wready => wready, i_s_wdata => wdata_a, i_s_wstrb => wstrb, i_s_wlast => wlast,
      o_s_bvalid => bvalid, i_s_bready => bready, o_s_bresp => bresp,
      i_s_arvalid => arvalid, o_s_arready => arready, i_s_araddr => araddr, i_s_arlen => arlen,
      i_s_arsize => arsize, i_s_arburst => arburst,
      o_s_rvalid => rvalid, i_s_rready => rready, o_s_rdata => rdata_a, o_s_rresp => rresp, o_s_rlast => rlast,
      o_addr => m_addr, o_wdata => m_wdata, o_byteena => m_be, o_rden => m_rden, o_wren => m_wren,
      o_mem_advance => m_adv, i_ready => m_ready, i_rdata => m_rdata,
      o_line => m_line, o_wdata_x => m_wdx, o_byteena_x => m_bex, i_rdata_x => m_rdx
    );

  u_sdram : entity work.sdram_system
    generic map (tck_ps => tck_ps, init_cycles => init_cycles, refresh_cycles => refresh_cycles)
    port map (
      i_clk_mem => i_clk_mem, i_clk_cpu => i_clk_cpu, i_rst_mem => i_rst_mem, i_rst_cpu => i_rst_cpu,
      i_addr => m_addr, i_wdata => m_wdata, i_byteena => m_be, i_rden => m_rden, i_wren => m_wren,
      i_mem_advance => m_adv, o_ready => m_ready, o_rdata => m_rdata,
      i_line => m_line, i_wdata_x => m_wdx, i_byteena_x => m_bex, o_rdata_x => m_rdx,
      o_init_done => o_init_done,
      i_dbg_word_addr => i_dbg_word_addr, o_dbg_word_data => o_dbg_word_data,
      i_dbg_flip => i_dbg_flip, i_dbg_flip_addr => i_dbg_flip_addr, i_dbg_flip_bit => i_dbg_flip_bit,
      o_dbg_refreshes => o_dbg_refreshes, o_dbg_init_ok => o_dbg_init_ok
    );

end architecture rtl;
