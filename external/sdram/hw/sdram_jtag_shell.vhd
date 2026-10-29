library ieee;
use ieee.std_logic_1164.all;
library altera_mf;
use altera_mf.altera_mf_components.all;

-- The Virtual JTAG instance of the SDRAM debug port and the logic behind it (board only: it
-- needs Intel's sld_virtual_jtag, so it is not analyzed in simulation, where the testbench plays
-- the instance and drives sdram_jtag_core directly). The host sees one instance with a 2-bit
-- instruction register; instruction 1 selects the 64-bit DEBUG register.
entity sdram_jtag_shell is
  port (
    -- toward sdram_dbg_master (see sdram_jtag_core)
    o_cmd_tog    : out std_logic;
    o_op         : out std_logic_vector(3 downto 0);
    o_be         : out std_logic_vector(3 downto 0);
    o_addr       : out std_logic_vector(23 downto 0);
    o_data       : out std_logic_vector(31 downto 0);
    i_done_tog   : in  std_logic;
    i_rsp_addr   : in  std_logic_vector(23 downto 0);
    i_rsp_data   : in  std_logic_vector(31 downto 0);
    i_rsp_status : in  std_logic_vector(7 downto 0)
  );
end entity sdram_jtag_shell;

architecture rtl of sdram_jtag_shell is

  signal tck, tdi, tdo : std_logic;
  signal ir_in         : std_logic_vector(1 downto 0);
  signal st_cdr, st_sdr, st_udr, st_uir : std_logic;
  signal unused_e1dr, unused_pdr, unused_e2dr, unused_cir : std_logic;

begin

  u_vjtag : sld_virtual_jtag
    generic map (
      lpm_type => "sld_virtual_jtag",
      lpm_hint => "sld_instance_index=0",
      sld_auto_instance_index => "YES",
      sld_instance_index => 0,
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

  u_core : entity work.sdram_jtag_core
    port map (
      i_tck => tck, i_tdi => tdi, o_tdo => tdo, i_ir_in => ir_in,
      i_state_cdr => st_cdr, i_state_sdr => st_sdr, i_state_udr => st_udr, i_state_uir => st_uir,
      o_cmd_tog => o_cmd_tog, o_op => o_op, o_be => o_be, o_addr => o_addr, o_data => o_data,
      i_done_tog => i_done_tog, i_rsp_addr => i_rsp_addr, i_rsp_data => i_rsp_data, i_rsp_status => i_rsp_status
    );

end architecture rtl;
