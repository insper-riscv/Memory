-- =============================================================================
-- Instância do Virtual JTAG da porta de depuração da SDRAM
--
-- Contém a instância do Virtual JTAG e a lógica atrás dela. É exclusiva da placa:
-- precisa do sld_virtual_jtag da Intel, então não é analisada em simulação, onde
-- o testbench faz o papel da instância e conduz o sdram_jtag_core diretamente. O
-- hospedeiro vê uma instância com registrador de instrução de 2 bits; a
-- instrução 1 seleciona o registrador DEBUG de 64 bits.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
library altera_mf;
use altera_mf.altera_mf_components.all;

entity sdram_jtag_shell is
  port (
    -- Alternância que pede um comando ao mestre de debug.
    o_cmd_tog    : out std_logic;
    -- Operação do comando de debug.
    o_op         : out std_logic_vector(3 downto 0);
    -- Habilita de bytes do comando.
    o_be         : out std_logic_vector(3 downto 0);
    -- Endereço do acesso.
    o_addr       : out std_logic_vector(23 downto 0);
    -- Dado lido.
    o_data       : out std_logic_vector(31 downto 0);
    -- Alternância que confirma o comando concluído.
    i_done_tog   : in  std_logic;
    -- Endereço da resposta do comando.
    i_rsp_addr   : in  std_logic_vector(23 downto 0);
    -- Dado da resposta do comando.
    i_rsp_data   : in  std_logic_vector(31 downto 0);
    -- Status da resposta do comando.
    i_rsp_status : in  std_logic_vector(7 downto 0)
  );
end entity sdram_jtag_shell;

architecture rtl of sdram_jtag_shell is

  -- Clock da cadeia JTAG.
  signal tck : std_logic;
  -- Dado serial vindo do hospedeiro.
  signal tdi : std_logic;
  -- Dado serial para o hospedeiro.
  signal tdo : std_logic;
  -- Registrador de instrução do Virtual JTAG.
  signal ir_in         : std_logic_vector(1 downto 0);
  -- Estado Capture-DR da cadeia virtual.
  signal st_cdr : std_logic;
  -- Estado Shift-DR da cadeia virtual.
  signal st_sdr : std_logic;
  -- Estado Update-DR da cadeia virtual.
  signal st_udr : std_logic;
  -- Estado Update-IR da cadeia virtual.
  signal st_uir : std_logic;
  -- Estado Exit1-DR, não usado.
  signal unused_e1dr : std_logic;
  -- Estado Pause-DR, não usado.
  signal unused_pdr : std_logic;
  -- Estado Exit2-DR, não usado.
  signal unused_e2dr : std_logic;
  -- Estado Capture-IR, não usado.
  signal unused_cir : std_logic;

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
