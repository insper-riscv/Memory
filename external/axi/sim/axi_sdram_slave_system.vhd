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
    clk         : in  std_logic;   -- the core's clock
    clk_mem     : in  std_logic;
    rst         : in  std_logic;
    rst_mem     : in  std_logic;

    s_awvalid   : in  std_logic;
    s_awready   : out std_logic;
    s_awaddr    : in  std_logic_vector(31 downto 0);
    s_awlen     : in  std_logic_vector(7 downto 0);
    s_awsize    : in  std_logic_vector(2 downto 0);
    s_awburst   : in  std_logic_vector(1 downto 0);
    s_wvalid    : in  std_logic;
    s_wready    : out std_logic;
    s_wdata     : in  std_logic_vector(31 downto 0);
    s_wstrb     : in  std_logic_vector(3 downto 0);
    s_wlast     : in  std_logic;
    s_bvalid    : out std_logic;
    s_bready    : in  std_logic;
    s_bresp     : out std_logic_vector(1 downto 0);
    s_arvalid   : in  std_logic;
    s_arready   : out std_logic;
    s_araddr    : in  std_logic_vector(31 downto 0);
    s_arlen     : in  std_logic_vector(7 downto 0);
    s_arsize    : in  std_logic_vector(2 downto 0);
    s_arburst   : in  std_logic_vector(1 downto 0);
    s_rvalid    : out std_logic;
    s_rready    : in  std_logic;
    s_rdata     : out std_logic_vector(31 downto 0);
    s_rresp     : out std_logic_vector(1 downto 0);
    s_rlast     : out std_logic;

    init_done       : out std_logic;
    dbg_word_addr   : in  std_logic_vector(23 downto 0);
    dbg_word_data   : out std_logic_vector(31 downto 0);
    dbg_refreshes   : out std_logic_vector(31 downto 0);
    dbg_init_ok     : out std_logic
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
      clk => clk, rst => rst,
      s_awvalid => s_awvalid, s_awready => s_awready, s_awaddr => s_awaddr, s_awlen => s_awlen,
      s_awsize => s_awsize, s_awburst => s_awburst,
      s_wvalid => s_wvalid, s_wready => s_wready, s_wdata => s_wdata, s_wstrb => s_wstrb, s_wlast => s_wlast,
      s_bvalid => s_bvalid, s_bready => s_bready, s_bresp => s_bresp,
      s_arvalid => s_arvalid, s_arready => s_arready, s_araddr => s_araddr, s_arlen => s_arlen,
      s_arsize => s_arsize, s_arburst => s_arburst,
      s_rvalid => s_rvalid, s_rready => s_rready, s_rdata => s_rdata, s_rresp => s_rresp, s_rlast => s_rlast,
      addr => m_addr, wdata => m_wdata, byteena => m_be, rden => m_rden, wren => m_wren,
      mem_advance => m_adv, ready => m_ready, rdata => m_rdata,
      line => m_line, wdata_x => m_wdx, byteena_x => m_bex, rdata_x => m_rdx
    );

  u_sdram : entity work.sdram_system
    generic map (TCK_PS => TCK_PS, INIT_CYCLES => INIT_CYCLES, REFRESH_CYCLES => REFRESH_CYCLES)
    port map (
      clk_mem => clk_mem, clk_cpu => clk, rst_mem => rst_mem, rst_cpu => rst,
      addr => m_addr, wdata => m_wdata, byteena => m_be, rden => m_rden, wren => m_wren,
      mem_advance => m_adv, ready => m_ready, rdata => m_rdata,
      line => m_line, wdata_x => m_wdx, byteena_x => m_bex, rdata_x => m_rdx,
      init_done => init_done,
      dbg_word_addr => dbg_word_addr, dbg_word_data => dbg_word_data,
      dbg_flip => '0', dbg_flip_addr => (others => '0'), dbg_flip_bit => (others => '0'),
      dbg_refreshes => dbg_refreshes, dbg_init_ok => dbg_init_ok
    );

end architecture sim;
