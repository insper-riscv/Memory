library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;

-- Simulation top of the cached path: the data cache, the AXI4 master and slave bridges, and
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
    i_clk_mem     : in  std_logic;
    i_clk_cpu     : in  std_logic;
    i_rst_mem     : in  std_logic;
    i_rst_cpu     : in  std_logic;

    i_addr        : in  std_logic_vector(31 downto 0);
    i_wdata       : in  std_logic_vector(31 downto 0);
    i_byteena     : in  std_logic_vector(3 downto 0);
    i_rden        : in  std_logic;
    i_wren        : in  std_logic;
    i_mem_advance : in  std_logic;
    o_ready       : out std_logic;
    o_rdata       : out std_logic_vector(31 downto 0);
    i_flush       : in  std_logic;
    o_flush_done  : out std_logic;
    o_busy        : out std_logic;

    o_init_done       : out std_logic;
    i_dbg_word_addr   : in  std_logic_vector(23 downto 0);
    o_dbg_word_data   : out std_logic_vector(31 downto 0);
    i_dbg_flip        : in  std_logic;
    i_dbg_flip_addr   : in  std_logic_vector(23 downto 0);
    i_dbg_flip_bit    : in  std_logic_vector(4 downto 0);
    o_dbg_refreshes   : out std_logic_vector(31 downto 0);
    o_dbg_init_ok     : out std_logic
  );
end entity sdram_dcache_system;

architecture sim of sdram_dcache_system is
  -- the cache's memory side
  signal d_addr, d_wdata, d_rdata : std_logic_vector(31 downto 0);
  signal d_be      : std_logic_vector(3 downto 0);
  signal d_rden, d_wren, d_advance, d_ready, d_err, d_line : std_logic;
  signal d_wdx, d_rdx : std_logic_vector(95 downto 0);

  -- AXI4
  signal awvalid, awready, wvalid, wready, bvalid, bready, wlast, rlast : std_logic;
  signal arvalid, arready, rvalid, rready : std_logic;
  signal awaddr, wdata_a, araddr, rdata_a : std_logic_vector(31 downto 0);
  signal awlen, arlen : std_logic_vector(7 downto 0);
  signal awsize, arsize : std_logic_vector(2 downto 0);
  signal awburst, arburst : std_logic_vector(1 downto 0);
  signal awprot, arprot : std_logic_vector(2 downto 0);
  signal wstrb : std_logic_vector(3 downto 0);
  signal bresp, rresp : std_logic_vector(1 downto 0);

  -- the SDRAM system's word port
  signal m_addr, m_wdata, m_rdata : std_logic_vector(31 downto 0);
  signal m_be : std_logic_vector(3 downto 0);
  signal m_rden, m_wren, m_adv, m_ready, m_line : std_logic;
  signal m_wdx, m_rdx : std_logic_vector(95 downto 0);
  signal m_bex : std_logic_vector(11 downto 0);
begin

  u_cache : entity work.dcache
    generic map (WRITE_THROUGH => WRITE_THROUGH)
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
    generic map (TCK_PS => TCK_PS, INIT_CYCLES => INIT_CYCLES, REFRESH_CYCLES => REFRESH_CYCLES)
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

end architecture sim;
