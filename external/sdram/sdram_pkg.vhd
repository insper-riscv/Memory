-- =============================================================================
-- Constantes compartilhadas pelo controlador da SDRAM e pelo modelo do chip
--
-- SDRAM SDR de 32M x 16 da DE0-CV (4 bancos, 13 bits de linha, 10 de coluna),
-- grau -7 a 143 MHz, latência CAS 3. Os valores foram conferidos com as
-- características AC do datasheet da ISSI IS42/45S16320D: cada um é igual ou mais
-- conservador que o mínimo do datasheet. São números simples (em picossegundos)
-- para que mudá-los não toque o controlador. O modelo do chip faz a simulação
-- falhar quando o controlador viola qualquer um deles.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

package sdram_pkg is

  -- Período do clock que as contagens de ciclos assumem (142,857 MHz).
  constant T_CK_PS    : natural := 7000;
  -- ACTIVE até READ/WRITE.
  constant T_RCD_PS   : natural := 15000;
  -- PRECHARGE até ACTIVE.
  constant T_RP_PS    : natural := 15000;
  -- ACTIVE até PRECHARGE.
  constant T_RAS_PS   : natural := 42000;
  -- ACTIVE até ACTIVE no mesmo banco.
  constant T_RC_PS    : natural := 60000;
  -- AUTO REFRESH até qualquer comando (o REF até REF do datasheet: tRC).
  constant T_RFC_PS   : natural := 63000;
  -- Último dado de escrita até PRECHARGE.
  constant T_WR_PS    : natural := 14000;
  -- LOAD MODE REGISTER até qualquer comando, em clocks.
  constant T_MRD_CK   : natural := 2;
  -- Espera com clock estável antes do primeiro comando (datasheet: 100 us).
  constant T_INIT_PS  : natural := 200_000_000;
  -- Intervalo entre refreshes: 64 ms / 8192 linhas.
  constant T_REFI_PS  : natural := 7_812_500;
  -- Comandos AUTO REFRESH da sequência de energização (datasheet: pelo menos 2).
  constant INIT_REFRESHES : natural := 8;

  -- Latência CAS em clocks.
  constant CAS_LATENCY : natural := 3;
  -- Registrador de modo: rajada de 2 (uma palavra de 32 bits), sequencial, latência CAS 3, escritas em rajada.
  constant MODE_REG : std_logic_vector(12 downto 0) := "0000000110001";

  -- Comando NOP, codificado como cs_n & ras_n & cas_n & we_n.
  constant CMD_NOP       : std_logic_vector(3 downto 0) := "0111";
  -- Comando ACTIVE.
  constant CMD_ACTIVE    : std_logic_vector(3 downto 0) := "0011";
  -- Comando READ.
  constant CMD_READ      : std_logic_vector(3 downto 0) := "0101";
  -- Comando WRITE.
  constant CMD_WRITE     : std_logic_vector(3 downto 0) := "0100";
  -- Comando PRECHARGE.
  constant CMD_PRECHARGE : std_logic_vector(3 downto 0) := "0010";
  -- Comando AUTO REFRESH.
  constant CMD_REFRESH   : std_logic_vector(3 downto 0) := "0001";
  -- Comando LOAD MODE REGISTER.
  constant CMD_LOAD_MODE : std_logic_vector(3 downto 0) := "0000";

  -- Ciclos de clock que cobrem um tempo (arredondado para cima).
  function cycles(ps : natural; tck_ps : natural) return natural;

end package sdram_pkg;

package body sdram_pkg is

  function cycles(ps : natural; tck_ps : natural) return natural is
  begin
    return (ps + tck_ps - 1) / tck_ps;
  end function;

end package body sdram_pkg;
