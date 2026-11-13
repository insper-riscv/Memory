-- =============================================================================
-- Instância do Virtual JTAG da porta de depuração da SDRAM
--
-- Contém a instância do Virtual JTAG (virtual_jtag, do Common-Components) e a lógica
-- atrás dela (sdram_jtag_core). É exclusiva da FPGA: precisa do sld_virtual_jtag da
-- Intel, então não é analisada em simulação, onde o testbench faz o papel da instância
-- e conduz o sdram_jtag_core diretamente. O hospedeiro vê uma instância com registrador
-- de instrução de 2 bits; a instrução 1 seleciona o registrador DEBUG de 64 bits.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity sdram_jtag_shell is
  generic (
    -- Índice da instância do Virtual JTAG que o hospedeiro usa para alcançar a porta de depuração.
    instance_index      : natural := 0;
    -- "YES" deixa o Quartus escolher o índice livre mais baixo; "NO" fixa o índice em instance_index.
    auto_instance_index : string  := "YES"
  );
  port (
    -- Alternância que pede um comando ao mestre de debug.
    o_cmd_tog    : out std_logic;
    -- Operação do comando de debug.
    o_op         : out std_logic_vector(3 downto 0);
    -- Habilita de bytes do comando.
    o_be         : out std_logic_vector(3 downto 0);
    -- Endereço do acesso.
    o_addr       : out std_logic_vector(23 downto 0);
    -- Dado do comando.
    -- Largura física do dispositivo ou do protocolo (32 bits), não do núcleo.
    o_data       : out std_logic_vector(31 downto 0);
    -- Alternância que confirma o comando concluído.
    i_done_tog   : in  std_logic;
    -- Endereço da resposta do comando.
    i_rsp_addr   : in  std_logic_vector(23 downto 0);
    -- Dado da resposta do comando.
    -- Largura física do dispositivo ou do protocolo (32 bits), não do núcleo.
    i_rsp_data   : in  std_logic_vector(31 downto 0);
    -- Status da resposta do comando.
    i_rsp_status : in  std_logic_vector(7 downto 0)
  );
end entity sdram_jtag_shell;

architecture rtl of sdram_jtag_shell is

  -- Clock da cadeia JTAG.
  signal tck    : std_logic;
  -- Dado serial vindo do hospedeiro.
  signal tdi    : std_logic;
  -- Dado serial para o hospedeiro.
  signal tdo    : std_logic;
  -- Registrador de instrução do Virtual JTAG.
  signal ir_in  : std_logic_vector(1 downto 0);
  -- Estado Capture-DR da cadeia virtual.
  signal st_cdr : std_logic;
  -- Estado Shift-DR da cadeia virtual.
  signal st_sdr : std_logic;
  -- Estado Update-DR da cadeia virtual.
  signal st_udr : std_logic;
  -- Estado Update-IR da cadeia virtual.
  signal st_uir : std_logic;

begin

  u_vjtag : entity work.virtual_jtag
    generic map (
      instance_index => instance_index,
      auto_instance_index => auto_instance_index,
      ir_width => 2
    )
    port map (
      o_tck => tck, o_tdi => tdi, i_tdo => tdo, o_ir_in => ir_in,
      o_state_cdr => st_cdr, o_state_sdr => st_sdr, o_state_udr => st_udr, o_state_uir => st_uir
    );

  u_core : entity work.sdram_jtag_core
    port map (
      i_tck => tck, i_tdi => tdi, o_tdo => tdo, i_ir_in => ir_in,
      i_state_cdr => st_cdr, i_state_sdr => st_sdr, i_state_udr => st_udr, i_state_uir => st_uir,
      o_cmd_tog => o_cmd_tog, o_op => o_op, o_be => o_be, o_addr => o_addr, o_data => o_data,
      i_done_tog => i_done_tog, i_rsp_addr => i_rsp_addr, i_rsp_data => i_rsp_data, i_rsp_status => i_rsp_status
    );

end architecture rtl;
