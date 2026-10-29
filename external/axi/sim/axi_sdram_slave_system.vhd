library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;

-- Simulation top for the AXI4 slave of the SDRAM: the slave bridge and the SDRAM system behind it,
-- with the AXI4 slave port exposed so a testbench plays the master. The chip model can be read
-- without the bus (dbg_word_*).
entity axi_sdram_slave_system is
  generic (
    TCK_PS         : natural := T_CK_PS;
    INIT_CYCLES    : natural := cycles(T_INIT_PS, T_CK_PS);
    REFRESH_CYCLES : natural := cycles(T_REFI_PS, T_CK_PS) * 9 / 10
  );
  port (
    i_clk         : in  std_logic;   -- the core's clock
    i_clk_mem     : in  std_logic;
    i_rst         : in  std_logic;
    i_rst_mem     : in  std_logic;

    i_s_awvalid   : in  std_logic;
    o_s_awready   : out std_logic;
    i_s_awaddr    : in  std_logic_vector(31 downto 0);
    i_s_awlen     : in  std_logic_vector(7 downto 0);
    i_s_awsize    : in  std_logic_vector(2 downto 0);
    i_s_awburst   : in  std_logic_vector(1 downto 0);
    i_s_wvalid    : in  std_logic;
    o_s_wready    : out std_logic;
    i_s_wdata     : in  std_logic_vector(31 downto 0);
    i_s_wstrb     : in  std_logic_vector(3 downto 0);
    i_s_wlast     : in  std_logic;
    o_s_bvalid    : out std_logic;
    i_s_bready    : in  std_logic;
    o_s_bresp     : out std_logic_vector(1 downto 0);
    i_s_arvalid   : in  std_logic;
    o_s_arready   : out std_logic;
    i_s_araddr    : in  std_logic_vector(31 downto 0);
    i_s_arlen     : in  std_logic_vector(7 downto 0);
    i_s_arsize    : in  std_logic_vector(2 downto 0);
    i_s_arburst   : in  std_logic_vector(1 downto 0);
    o_s_rvalid    : out std_logic;
    i_s_rready    : in  std_logic;
    o_s_rdata     : out std_logic_vector(31 downto 0);
    o_s_rresp     : out std_logic_vector(1 downto 0);
    o_s_rlast     : out std_logic;

    o_init_done       : out std_logic;
    i_dbg_word_addr   : in  std_logic_vector(23 downto 0);
    o_dbg_word_data   : out std_logic_vector(31 downto 0);
    o_dbg_refreshes   : out std_logic_vector(31 downto 0);
    o_dbg_init_ok     : out std_logic
  );
end entity axi_sdram_slave_system;

architecture sim of axi_sdram_slave_system is
  signal m_addr, m_wdata, m_rdata : std_logic_vector(31 downto 0);
  signal m_be : std_logic_vector(3 downto 0);
  signal m_rden, m_wren, m_adv, m_ready, m_line : std_logic;
  signal m_wdx, m_rdx : std_logic_vector(95 downto 0);
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
    generic map (TCK_PS => TCK_PS, INIT_CYCLES => INIT_CYCLES, REFRESH_CYCLES => REFRESH_CYCLES)
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

end architecture sim;
