-- =============================================================================
-- Modelo de FLASH de duas portas com comandos, para o teste de conjunto
--
-- O chip de leitura (flash_chip, porta A), a porta de comandos (flash_cmd_port,
-- porta B) e o armazenamento de duas portas (flash_simulation) ligados como no
-- topo da FPGA, mais um buffer de página de leitura registrada que faz o papel
-- do buffer do controlador de FLASH: o teste o enche por i_buf_we antes de
-- mandar uma gravação. O vetor de palavras do armazenamento fica visível ao
-- cocotb em u_store.mem.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.utils_pkg.all;

entity flash_dual_system is
  generic (
    -- Bordas até a primeira palavra do chip de leitura.
    first_latency   : natural := 6;
    -- Bordas entre as palavras de uma linha do chip de leitura.
    next_latency    : natural := 3;
    -- Tamanho do chip em bytes, uma potência de dois.
    size_bytes      : positive := 16384;
    -- Tamanho do setor em bytes.
    sector_bytes    : positive := 4096;
    -- Tamanho da página em bytes.
    page_bytes      : positive := 256;
    -- Bordas de espera de um apagar.
    erase_latency   : natural := 40;
    -- Bordas de espera de uma gravação.
    program_latency : natural := 10
  );
  port (
    -- Clock do sistema.
    i_clk         : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst         : in  std_logic;

    -- Porta A: endereço do pedido.
    i_addr        : in  std_logic_vector(31 downto 0);
    -- Porta A: pedido de leitura.
    i_rden        : in  std_logic;
    -- Porta A: pedido de linha de quatro palavras.
    i_line        : in  std_logic;
    -- Porta A: o pedido foi consumido neste ciclo.
    i_advance     : in  std_logic;
    -- Porta A: pedido concluído.
    o_ready       : out std_logic;
    -- Porta A: palavra pedida.
    o_rdata       : out std_logic_vector(31 downto 0);
    -- Porta A: palavras 1 a 3 da linha.
    o_rdata_x     : out std_logic_vector(95 downto 0);

    -- Porta B: pulso que entrega um comando.
    i_cmd_valid   : in  std_logic;
    -- Porta B: código do comando.
    i_cmd_op      : in  std_logic_vector(2 downto 0);
    -- Porta B: endereço de byte do comando.
    i_cmd_addr    : in  std_logic_vector(31 downto 0);
    -- Porta B: o chip está ocupado.
    o_busy        : out std_logic;
    -- Porta B: o latch de escrita está armado.
    o_wel         : out std_logic;
    -- Porta B: o último apagar ou gravar foi recusado.
    o_refused     : out std_logic;

    -- Buffer de página: escrita de uma palavra.
    i_buf_we      : in  std_logic;
    -- Buffer de página: índice da palavra escrita.
    i_buf_widx    : in  std_logic_vector(log2_exact(page_bytes) - 3 downto 0);
    -- Buffer de página: palavra escrita.
    i_buf_wdata   : in  std_logic_vector(31 downto 0);

    -- Pulso de invalidação no fim de um apagar ou gravar.
    o_inval_valid : out std_logic;
    -- Primeiro endereço de byte da região alterada.
    o_inval_first : out std_logic_vector(31 downto 0);
    -- Último endereço de byte da região alterada.
    o_inval_last  : out std_logic_vector(31 downto 0)
  );
end entity flash_dual_system;

architecture rtl of flash_dual_system is

  -- Bits de endereço da janela do chip.
  constant WINDOW_BITS : natural := log2_exact(size_bytes);

  -- Buffer de página: vetor de palavras.
  type page_t is array (0 to page_bytes / 4 - 1) of std_logic_vector(31 downto 0);
  -- Palavras do buffer de página.
  signal page      : page_t := (others => (others => '1'));
  -- Índice lido do buffer pela porta de comandos.
  signal buf_idx   : std_logic_vector(log2_exact(page_bytes) - 3 downto 0);
  -- Palavra do buffer lida (registrada).
  signal buf_data  : std_logic_vector(31 downto 0) := (others => '0');

  -- Endereço de byte da porta A do armazenamento.
  signal a_addr    : std_logic_vector(31 downto 0);
  -- Palavra lida pela porta A do armazenamento.
  signal a_data    : std_logic_vector(31 downto 0);
  -- Endereço de byte da porta B do armazenamento.
  signal b_addr    : std_logic_vector(31 downto 0);
  -- Habilita de escrita da porta B do armazenamento.
  signal b_we      : std_logic;
  -- Palavra escrita pela porta B do armazenamento.
  signal b_wdata   : std_logic_vector(31 downto 0);
  -- Palavra lida pela porta B do armazenamento.
  signal b_data    : std_logic_vector(31 downto 0);

begin

  u_chip : entity work.flash_chip
    generic map (first_latency => first_latency, next_latency => next_latency, size_bytes => size_bytes)
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_addr => i_addr, i_rden => i_rden, i_line => i_line, i_advance => i_advance,
      o_ready => o_ready, o_busy => open, o_rdata => o_rdata, o_rdata_x => o_rdata_x,
      o_mem_addr => a_addr, i_mem_data => a_data
    );

  u_cmd : entity work.flash_cmd_port
    generic map (
      size_bytes => size_bytes, sector_bytes => sector_bytes, page_bytes => page_bytes,
      erase_latency => erase_latency, program_latency => program_latency
    )
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_cmd_valid => i_cmd_valid, i_cmd_op => i_cmd_op, i_cmd_addr => i_cmd_addr,
      o_busy => o_busy, o_wel => o_wel, o_refused => o_refused,
      o_buf_idx => buf_idx, i_buf_data => buf_data,
      o_mem_addr => b_addr, o_mem_we => b_we, o_mem_wdata => b_wdata, i_mem_data => b_data,
      o_inval_valid => o_inval_valid, o_inval_first => o_inval_first, o_inval_last => o_inval_last
    );

  u_store : entity work.flash_simulation
    generic map (size_bytes => size_bytes)
    port map (
      i_clk_a => i_clk, i_address_a => a_addr(WINDOW_BITS - 1 downto 2), i_rden_a => '1', o_q_a => a_data,
      i_clk_b => i_clk, i_address_b => b_addr(WINDOW_BITS - 1 downto 2), i_rden_b => '1',
      i_wren_b => b_we, i_data_b => b_wdata, o_q_b => b_data
    );

  -- Buffer de página: escrita pelo teste e leitura registrada pela porta de comandos.
  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_buf_we = '1' then
        page(to_integer(unsigned(i_buf_widx))) <= i_buf_wdata;
      end if;
      buf_data <= page(to_integer(unsigned(buf_idx)));
    end if;
  end process;

end architecture rtl;
