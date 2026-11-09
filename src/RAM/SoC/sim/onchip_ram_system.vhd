-- =============================================================================
-- Topo de simulação da RAM interna atrás do contrato de linha
--
-- O onchip_ram_port sobre o modelo ram_simulation, com a cache de dados na
-- frente ou não, e o ram_chip no lugar do par adaptador e modelo quando o
-- genérico use_chip pede. O mesmo teste roda nos dois, então o ram_chip serve
-- de referência do contrato. Sem cache, o lado do requisitante é a lista de
-- portas do ram_chip (palavra e linha); com cache, é a do core (palavra) mais o
-- flush. A porta de depuração por palavra é a do ram_chip nos dois casos.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.utils_pkg.all;

entity onchip_ram_system is
  generic (
    -- Verdadeiro: a dcache fica entre o requisitante e a memória.
    with_cache    : boolean  := false;
    -- Verdadeiro: o ram_chip faz o papel da memória, no lugar do adaptador e do modelo da RAM.
    use_chip      : boolean  := false;
    -- Verdadeiro: a cache escreve também na memória a cada store.
    write_through : boolean  := false;
    -- Tamanho da memória em bytes, uma potência de dois.
    size_bytes    : positive := 4096;
    -- Onde a memória começa dentro dos 64 MB da região, em KiB. Origem: o espaço de endereços da
    -- região da memória que o Memory enxerga (26 bits baixos), não o mapa do Core.
    base_kib      : natural  := 0;
    -- Latência emulada em bordas, a mesma no ram_chip e no adaptador (0 deixa ao ram_chip o padrão e ao adaptador a estrutural).
    latency       : natural  := 0;
    -- Tamanho da cache de dados em bits, uma potência de dois (usado só com with_cache).
    cache_size_bits : positive := 4096
  );
  port (
    -- Clock do sistema.
    i_clk           : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst           : in  std_logic;

    -- Endereço do acesso.
    i_addr          : in  std_logic_vector(31 downto 0);
    -- Dado de escrita.
    i_wdata         : in  std_logic_vector(31 downto 0);
    -- Habilita de bytes da escrita, um bit por byte.
    i_byteena       : in  std_logic_vector(3 downto 0);
    -- Pedido de leitura ('1' = lê).
    i_rden          : in  std_logic;
    -- Pedido de escrita ('1' = escreve).
    i_wren          : in  std_logic;
    -- O pipeline avançou neste ciclo, o acesso concluído pode terminar.
    i_mem_advance   : in  std_logic;
    -- Acesso concluído, o dado lido é válido ('1').
    o_ready         : out std_logic;
    -- Dado lido.
    o_rdata         : out std_logic_vector(31 downto 0);
    -- Acesso de linha ('1'); só vale sem cache.
    i_line          : in  std_logic;
    -- Palavras 1 a 3 do dado de escrita da linha; só vale sem cache.
    i_wdata_x       : in  std_logic_vector(95 downto 0);
    -- Habilita de bytes das palavras 1 a 3; só vale sem cache.
    i_byteena_x     : in  std_logic_vector(11 downto 0);
    -- Palavras 1 a 3 do dado lido da linha; zero com cache.
    o_rdata_x       : out std_logic_vector(95 downto 0);
    -- Pede a escrita de todas as linhas sujas na memória ('1'); só vale com cache.
    i_flush         : in  std_logic;
    -- A escrita das linhas sujas terminou ('1').
    o_flush_done    : out std_logic;

    -- Índice da palavra lida pela porta de depuração.
    i_dbg_word_addr : in  std_logic_vector(23 downto 0);
    -- Palavra da memória no índice de i_dbg_word_addr.
    o_dbg_word_data : out std_logic_vector(31 downto 0)
  );
end entity onchip_ram_system;

architecture rtl of onchip_ram_system is

  -- Bits do índice de palavra do bloco de RAM.
  constant WORD_BITS : natural := log2_exact(size_bytes) - 2;
  -- Latência do ram_chip: a emulada, ou o padrão do modelo (8) quando não há.
  pure function chip_latency_of(n : natural) return natural is
  begin
    if n > 0 then
      return n;
    end if;
    return 8;
  end function;

  -- Latência entregue ao ram_chip.
  constant CHIP_LATENCY : natural := chip_latency_of(latency);

  -- Lado da memória: endereço do acesso.
  signal m_addr    : std_logic_vector(31 downto 0);
  -- Lado da memória: dado de escrita.
  signal m_wdata   : std_logic_vector(31 downto 0);
  -- Lado da memória: habilita de bytes da escrita.
  signal m_be      : std_logic_vector(3 downto 0);
  -- Lado da memória: pedido de leitura.
  signal m_rden    : std_logic;
  -- Lado da memória: pedido de escrita.
  signal m_wren    : std_logic;
  -- Lado da memória: avanço do acesso.
  signal m_adv     : std_logic;
  -- Lado da memória: acesso concluído.
  signal m_ready   : std_logic;
  -- Lado da memória: dado lido.
  signal m_rdata   : std_logic_vector(31 downto 0);
  -- Lado da memória: acesso de linha.
  signal m_line    : std_logic;
  -- Lado da memória: palavras 1 a 3 da escrita de linha.
  signal m_wdx     : std_logic_vector(95 downto 0);
  -- Lado da memória: habilita de bytes das palavras 1 a 3.
  signal m_bex     : std_logic_vector(11 downto 0);
  -- Lado da memória: palavras 1 a 3 da leitura de linha.
  signal m_rdx     : std_logic_vector(95 downto 0);

  -- Bloco de RAM: índice da palavra.
  signal b_addr    : std_logic_vector(WORD_BITS - 1 downto 0);
  -- Bloco de RAM: dado de escrita.
  signal b_wdata   : std_logic_vector(31 downto 0);
  -- Bloco de RAM: habilita de bytes da escrita.
  signal b_be      : std_logic_vector(3 downto 0);
  -- Bloco de RAM: habilita de leitura.
  signal b_rden    : std_logic;
  -- Bloco de RAM: habilita de escrita.
  signal b_wren    : std_logic;
  -- Bloco de RAM: palavra lida.
  signal b_q       : std_logic_vector(31 downto 0);

begin

  -- Com cache, o requisitante fala com a dcache e o lado da memória dela chega à memória.
  g_cache : if with_cache generate
    u_cache : entity work.dcache
      generic map (size_bits => cache_size_bits, write_through => write_through)
      port map (
        i_clk => i_clk, i_rst => i_rst,
        i_addr => i_addr, i_wdata => i_wdata, i_byteena => i_byteena, i_rden => i_rden, i_wren => i_wren,
        i_mem_advance => i_mem_advance, o_ready => o_ready, o_rdata => o_rdata,
        i_flush => i_flush, o_flush_done => o_flush_done,
        o_d_addr => m_addr, o_d_wdata => m_wdata, o_d_byteena => m_be, o_d_rden => m_rden, o_d_wren => m_wren,
        o_d_advance => m_adv, i_d_ready => m_ready, i_d_rdata => m_rdata,
        o_d_line => m_line, o_d_wdata_x => m_wdx, i_d_rdata_x => m_rdx
      );
    m_bex     <= (others => '1');
    o_rdata_x <= (others => '0');
  end generate g_cache;

  -- Sem cache, o requisitante fala direto com a memória.
  g_direct : if not with_cache generate
    m_addr       <= i_addr;
    m_wdata      <= i_wdata;
    m_be         <= i_byteena;
    m_rden       <= i_rden;
    m_wren       <= i_wren;
    m_adv        <= i_mem_advance;
    m_line       <= i_line;
    m_wdx        <= i_wdata_x;
    m_bex        <= i_byteena_x;
    o_ready      <= m_ready;
    o_rdata      <= m_rdata;
    o_rdata_x    <= m_rdx;
    o_flush_done <= '0';
  end generate g_direct;

  -- O modelo ram_chip como referência do contrato.
  g_chip : if use_chip generate
    u_chip : entity work.ram_chip
      generic map (size_bytes => size_bytes, base_kib => base_kib, latency => CHIP_LATENCY)
      port map (
        i_clk => i_clk, i_rst => i_rst,
        i_addr => m_addr, i_wdata => m_wdata, i_byteena => m_be, i_rden => m_rden, i_wren => m_wren,
        i_mem_advance => m_adv, o_ready => m_ready, o_rdata => m_rdata,
        i_line => m_line, i_wdata_x => m_wdx, i_byteena_x => m_bex, o_rdata_x => m_rdx,
        i_dbg_word_addr => i_dbg_word_addr, o_dbg_word_data => o_dbg_word_data
      );
  end generate g_chip;

  -- O adaptador sobre o modelo de simulação do bloco de RAM.
  g_onchip : if not use_chip generate
    u_port : entity work.onchip_ram_port
      generic map (size_bytes => size_bytes, base_kib => base_kib, latency => latency)
      port map (
        i_clk => i_clk, i_rst => i_rst,
        i_addr => m_addr, i_wdata => m_wdata, i_byteena => m_be, i_rden => m_rden, i_wren => m_wren,
        i_mem_advance => m_adv, o_ready => m_ready, o_rdata => m_rdata,
        i_line => m_line, i_wdata_x => m_wdx, i_byteena_x => m_bex, o_rdata_x => m_rdx,
        o_mem_addr => b_addr, o_mem_wdata => b_wdata, o_mem_byteena => b_be,
        o_mem_rden => b_rden, o_mem_wren => b_wren, i_mem_q => b_q,
        i_dbg_word_addr => i_dbg_word_addr, o_dbg_word_data => o_dbg_word_data
      );

    u_ram : entity work.ram_simulation
      generic map (addr_width => WORD_BITS, size_bytes => size_bytes)
      port map (
        i_clk => i_clk, i_addr => b_addr, i_data_in => b_wdata, o_data_out => b_q,
        i_we_ram => b_wren, i_re_ram => b_rden, i_en_ram => '1', i_mask => b_be
      );
  end generate g_onchip;

end architecture rtl;
