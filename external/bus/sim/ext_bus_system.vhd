library ieee;
use ieee.std_logic_1164.all;

-- Simulation top: the interconnect with the JTAG UART in peripheral slot 4. The core's port and
-- the memory side (m_*) are exposed so a testbench plays the core and the memory; jtag_* stand
-- for a Virtual JTAG instance (see jtag_uart).
entity ext_bus_system is
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;

    addr        : in  std_logic_vector(31 downto 0);
    wdata       : in  std_logic_vector(31 downto 0);
    byteena     : in  std_logic_vector(3 downto 0);
    rden        : in  std_logic;
    wren        : in  std_logic;
    mem_advance : in  std_logic;
    ready       : out std_logic;
    rdata       : out std_logic_vector(31 downto 0);

    m_addr      : out std_logic_vector(31 downto 0);
    m_wdata     : out std_logic_vector(31 downto 0);
    m_byteena   : out std_logic_vector(3 downto 0);
    m_rden      : out std_logic;
    m_wren      : out std_logic;
    m_ready     : in  std_logic;
    m_rdata     : in  std_logic_vector(31 downto 0);

    jtag_tck        : in  std_logic := '0';
    jtag_tdi        : in  std_logic := '0';
    jtag_tdo        : out std_logic;
    jtag_ir_in      : in  std_logic_vector(1 downto 0) := "00";
    jtag_state_cdr  : in  std_logic := '0';
    jtag_state_sdr  : in  std_logic := '0';
    jtag_state_udr  : in  std_logic := '0';
    jtag_state_uir  : in  std_logic := '0'
  );
end entity ext_bus_system;

architecture sim of ext_bus_system is
  signal p_addr   : std_logic_vector(7 downto 0);
  signal p_wdata  : std_logic_vector(31 downto 0);
  signal p_byteena : std_logic_vector(3 downto 0);
  signal p_we, p_re : std_logic_vector(7 downto 0);
  signal p_rdata  : std_logic_vector(8 * 32 - 1 downto 0) := (others => '0');
begin

  u_ic : entity work.ext_interconnect
    port map (
      clk => clk, rst => rst,
      addr => addr, wdata => wdata, byteena => byteena, rden => rden, wren => wren,
      mem_advance => mem_advance, ready => ready, rdata => rdata,
      m_addr => m_addr, m_wdata => m_wdata, m_byteena => m_byteena, m_rden => m_rden,
      m_wren => m_wren, m_ready => m_ready, m_rdata => m_rdata,
      p_addr => p_addr, p_wdata => p_wdata, p_byteena => p_byteena, p_we => p_we, p_re => p_re,
      p_rdata => p_rdata
    );

  u_uart : entity work.jtag_uart
    port map (
      clk => clk, rst => rst, addr => p_addr, wdata => p_wdata, we => p_we(4), re => p_re(4),
      rdata => p_rdata(32 * 4 + 31 downto 32 * 4),
      tck => jtag_tck, tdi => jtag_tdi, tdo => jtag_tdo, ir_in => jtag_ir_in,
      state_cdr => jtag_state_cdr, state_sdr => jtag_state_sdr,
      state_udr => jtag_state_udr, state_uir => jtag_state_uir
    );

end architecture sim;
