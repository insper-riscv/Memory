library ieee;
use ieee.std_logic_1164.all;

-- Simulation top: the interconnect with the JTAG UART in peripheral slot 4. The core's port and
-- the memory side (m_*) are exposed so a testbench plays the core and the memory; jtag_* stand
-- for a Virtual JTAG instance (see jtag_uart).
entity ext_bus_system is
  port (
    i_clk         : in  std_logic;
    i_rst         : in  std_logic;

    i_addr        : in  std_logic_vector(31 downto 0);
    i_wdata       : in  std_logic_vector(31 downto 0);
    i_byteena     : in  std_logic_vector(3 downto 0);
    i_rden        : in  std_logic;
    i_wren        : in  std_logic;
    i_mem_advance : in  std_logic;
    o_ready       : out std_logic;
    o_rdata       : out std_logic_vector(31 downto 0);

    o_m_addr      : out std_logic_vector(31 downto 0);
    o_m_wdata     : out std_logic_vector(31 downto 0);
    o_m_byteena   : out std_logic_vector(3 downto 0);
    o_m_rden      : out std_logic;
    o_m_wren      : out std_logic;
    i_m_ready     : in  std_logic;
    i_m_rdata     : in  std_logic_vector(31 downto 0);

    i_jtag_tck        : in  std_logic := '0';
    i_jtag_tdi        : in  std_logic := '0';
    o_jtag_tdo        : out std_logic;
    i_jtag_ir_in      : in  std_logic_vector(1 downto 0) := "00";
    i_jtag_state_cdr  : in  std_logic := '0';
    i_jtag_state_sdr  : in  std_logic := '0';
    i_jtag_state_udr  : in  std_logic := '0';
    i_jtag_state_uir  : in  std_logic := '0'
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
      i_clk => i_clk, i_rst => i_rst,
      i_addr => i_addr, i_wdata => i_wdata, i_byteena => i_byteena, i_rden => i_rden, i_wren => i_wren,
      i_mem_advance => i_mem_advance, o_ready => o_ready, o_rdata => o_rdata,
      o_m_addr => o_m_addr, o_m_wdata => o_m_wdata, o_m_byteena => o_m_byteena, o_m_rden => o_m_rden,
      o_m_wren => o_m_wren, i_m_ready => i_m_ready, i_m_rdata => i_m_rdata,
      o_p_addr => p_addr, o_p_wdata => p_wdata, o_p_byteena => p_byteena, o_p_we => p_we, o_p_re => p_re,
      i_p_rdata => p_rdata
    );

  u_uart : entity work.jtag_uart
    port map (
      i_clk => i_clk, i_rst => i_rst, i_addr => p_addr, i_wdata => p_wdata, i_we => p_we(4), i_re => p_re(4),
      o_rdata => p_rdata(32 * 4 + 31 downto 32 * 4),
      i_tck => i_jtag_tck, i_tdi => i_jtag_tdi, o_tdo => o_jtag_tdo, i_ir_in => i_jtag_ir_in,
      i_state_cdr => i_jtag_state_cdr, i_state_sdr => i_jtag_state_sdr,
      i_state_udr => i_jtag_state_udr, i_state_uir => i_jtag_state_uir
    );

end architecture sim;
