library ieee;
use ieee.std_logic_1164.all;
library altera_mf;
use altera_mf.altera_mf_components.all;

-- The JTAG UART with its Virtual JTAG instance (board only: it needs Intel's sld_virtual_jtag,
-- so it is not analyzed in simulation, where the testbench plays the instance and drives
-- jtag_uart directly). The host sees a second instance next to the SDRAM debug port's, with a
-- 2-bit instruction register; instruction 1 selects the 48-bit register of jtag_uart.
entity jtag_uart_shell is
  port (
    i_clk     : in  std_logic;
    i_rst     : in  std_logic;
    i_addr    : in  std_logic_vector(7 downto 0);
    i_wdata   : in  std_logic_vector(31 downto 0);
    i_we      : in  std_logic;
    i_re      : in  std_logic;
    o_rdata   : out std_logic_vector(31 downto 0)
  );
end entity jtag_uart_shell;

architecture rtl of jtag_uart_shell is

  signal tck, tdi, tdo : std_logic;
  signal ir_in         : std_logic_vector(1 downto 0);
  signal st_cdr, st_sdr, st_udr, st_uir : std_logic;
  signal unused_e1dr, unused_pdr, unused_e2dr, unused_cir : std_logic;

begin

  u_vjtag : sld_virtual_jtag
    generic map (
      lpm_type => "sld_virtual_jtag",
      lpm_hint => "sld_instance_index=1",
      sld_auto_instance_index => "NO",
      sld_instance_index => 1,
      sld_ir_width => 2,
      sld_sim_n_scan => 0,
      sld_sim_total_length => 0,
      sld_sim_action => ""
    )
    port map (
      tdo => tdo, ir_out => (others => '0'),
      tck => tck, tdi => tdi, ir_in => ir_in,
      virtual_state_cdr => st_cdr, virtual_state_sdr => st_sdr,
      virtual_state_e1dr => unused_e1dr, virtual_state_pdr => unused_pdr,
      virtual_state_e2dr => unused_e2dr, virtual_state_udr => st_udr,
      virtual_state_cir => unused_cir, virtual_state_uir => st_uir
    );

  u_uart : entity work.jtag_uart
    port map (
      i_clk => i_clk, i_rst => i_rst, i_addr => i_addr, i_wdata => i_wdata, i_we => i_we, i_re => i_re, o_rdata => o_rdata,
      i_tck => tck, i_tdi => tdi, o_tdo => tdo, i_ir_in => ir_in,
      i_state_cdr => st_cdr, i_state_sdr => st_sdr, i_state_udr => st_udr, i_state_uir => st_uir
    );

end architecture rtl;
