library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;

-- Simulation top of the cached path: the data cache, the AXI4-Lite master and slave bridges, and
-- the SDRAM system behind them. The core side is the port list a core would drive (the same as
-- sdram_system's, plus the cache's flush); the debug ports reach the chip model.
entity sdram_dcache_system is
  generic (
    WRITE_THROUGH  : boolean := false;
    TCK_PS         : natural := T_CK_PS;
    INIT_CYCLES    : natural := cycles(T_INIT_PS, T_CK_PS);
    REFRESH_CYCLES : natural := cycles(T_REFI_PS, T_CK_PS) * 9 / 10
  );
  port (
    clk_mem     : in  std_logic;
    clk_cpu     : in  std_logic;
    rst_mem     : in  std_logic;
    rst_cpu     : in  std_logic;

    addr        : in  std_logic_vector(31 downto 0);
    wdata       : in  std_logic_vector(31 downto 0);
    byteena     : in  std_logic_vector(3 downto 0);
    rden        : in  std_logic;
    wren        : in  std_logic;
    mem_advance : in  std_logic;
    ready       : out std_logic;
    rdata       : out std_logic_vector(31 downto 0);
    flush       : in  std_logic;
    flush_done  : out std_logic;
    busy        : out std_logic;

    init_done       : out std_logic;
    dbg_word_addr   : in  std_logic_vector(23 downto 0);
    dbg_word_data   : out std_logic_vector(31 downto 0);
    dbg_flip        : in  std_logic;
    dbg_flip_addr   : in  std_logic_vector(23 downto 0);
    dbg_flip_bit    : in  std_logic_vector(4 downto 0);
    dbg_refreshes   : out std_logic_vector(31 downto 0);
    dbg_init_ok     : out std_logic
  );
end entity sdram_dcache_system;

architecture sim of sdram_dcache_system is
  -- the cache's memory side
  signal d_addr, d_wdata, d_rdata : std_logic_vector(31 downto 0);
  signal d_be      : std_logic_vector(3 downto 0);
  signal d_rden, d_wren, d_advance, d_ready, d_err : std_logic;

  -- AXI4-Lite
  signal awvalid, awready, wvalid, wready, bvalid, bready : std_logic;
  signal arvalid, arready, rvalid, rready : std_logic;
  signal awaddr, wdata_a, araddr, rdata_a : std_logic_vector(31 downto 0);
  signal awprot, arprot : std_logic_vector(2 downto 0);
  signal wstrb : std_logic_vector(3 downto 0);
  signal bresp, rresp : std_logic_vector(1 downto 0);

  -- the SDRAM system's word port
  signal m_addr, m_wdata, m_rdata : std_logic_vector(31 downto 0);
  signal m_be : std_logic_vector(3 downto 0);
  signal m_rden, m_wren, m_adv, m_ready : std_logic;
begin

  u_cache : entity work.dcache
    generic map (WRITE_THROUGH => WRITE_THROUGH)
    port map (
      clk => clk_cpu, rst => rst_cpu,
      addr => addr, wdata => wdata, byteena => byteena, rden => rden, wren => wren,
      mem_advance => mem_advance, ready => ready, rdata => rdata,
      flush => flush, flush_done => flush_done, busy => busy,
      d_addr => d_addr, d_wdata => d_wdata, d_byteena => d_be, d_rden => d_rden, d_wren => d_wren,
      d_advance => d_advance, d_ready => d_ready, d_rdata => d_rdata
    );

  u_master : entity work.axil_master_bridge
    port map (
      clk => clk_cpu, rst => rst_cpu,
      addr => d_addr, wdata => d_wdata, byteena => d_be, rden => d_rden, wren => d_wren,
      mem_advance => d_advance, ready => d_ready, rdata => d_rdata, err => d_err,
      m_awvalid => awvalid, m_awready => awready, m_awaddr => awaddr, m_awprot => awprot,
      m_wvalid => wvalid, m_wready => wready, m_wdata => wdata_a, m_wstrb => wstrb,
      m_bvalid => bvalid, m_bready => bready, m_bresp => bresp,
      m_arvalid => arvalid, m_arready => arready, m_araddr => araddr, m_arprot => arprot,
      m_rvalid => rvalid, m_rready => rready, m_rdata => rdata_a, m_rresp => rresp
    );

  u_slave : entity work.axil_slave_word_bridge
    port map (
      clk => clk_cpu, rst => rst_cpu,
      s_awvalid => awvalid, s_awready => awready, s_awaddr => awaddr,
      s_wvalid => wvalid, s_wready => wready, s_wdata => wdata_a, s_wstrb => wstrb,
      s_bvalid => bvalid, s_bready => bready, s_bresp => bresp,
      s_arvalid => arvalid, s_arready => arready, s_araddr => araddr,
      s_rvalid => rvalid, s_rready => rready, s_rdata => rdata_a, s_rresp => rresp,
      addr => m_addr, wdata => m_wdata, byteena => m_be, rden => m_rden, wren => m_wren,
      mem_advance => m_adv, ready => m_ready, rdata => m_rdata
    );

  u_sdram : entity work.sdram_system
    generic map (TCK_PS => TCK_PS, INIT_CYCLES => INIT_CYCLES, REFRESH_CYCLES => REFRESH_CYCLES)
    port map (
      clk_mem => clk_mem, clk_cpu => clk_cpu, rst_mem => rst_mem, rst_cpu => rst_cpu,
      addr => m_addr, wdata => m_wdata, byteena => m_be, rden => m_rden, wren => m_wren,
      mem_advance => m_adv, ready => m_ready, rdata => m_rdata,
      init_done => init_done,
      dbg_word_addr => dbg_word_addr, dbg_word_data => dbg_word_data,
      dbg_flip => dbg_flip, dbg_flip_addr => dbg_flip_addr, dbg_flip_bit => dbg_flip_bit,
      dbg_refreshes => dbg_refreshes, dbg_init_ok => dbg_init_ok
    );

end architecture sim;
