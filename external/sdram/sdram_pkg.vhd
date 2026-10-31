library ieee;
use ieee.std_logic_1164.all;

-- Constants shared by the SDRAM controller and the chip model: the 32M x 16 SDR
-- SDRAM of the DE0-CV (4 banks, 13 row bits, 10 column bits), -7 grade at 143 MHz,
-- CAS latency 3. The values are checked against the AC characteristics of the
-- ISSI IS42/45S16320D datasheet (docs/SDRAM_TIMINGS.md): each one is equal to or more
-- conservative than the datasheet minimum. They are plain numbers (in picoseconds) so
-- that changing them does not touch the controller. The chip model fails the
-- simulation when the controller violates any of them.
package sdram_pkg is

  constant T_CK_PS    : natural := 7000;        -- clock period the cycle counts assume (142.857 MHz)
  constant T_RCD_PS   : natural := 15000;       -- ACTIVE to READ/WRITE
  constant T_RP_PS    : natural := 15000;       -- PRECHARGE to ACTIVE
  constant T_RAS_PS   : natural := 42000;       -- ACTIVE to PRECHARGE
  constant T_RC_PS    : natural := 60000;       -- ACTIVE to ACTIVE, same bank
  constant T_RFC_PS   : natural := 63000;       -- AUTO REFRESH to any command (the datasheet's REF to REF: tRC)
  constant T_WR_PS    : natural := 14000;       -- last write data to PRECHARGE
  constant T_MRD_CK   : natural := 2;           -- LOAD MODE REGISTER to any command, in clocks
  constant T_INIT_PS  : natural := 200_000_000; -- wait with a stable clock before the first command (datasheet: 100 us)
  constant T_REFI_PS  : natural := 7_812_500;   -- 64 ms / 8192 rows
  constant INIT_REFRESHES : natural := 8;       -- AUTO REFRESH commands of the power-up sequence (datasheet: at least 2)

  constant CAS_LATENCY : natural := 3;
  -- burst length 2 (one 32-bit word), sequential, CAS latency 3, burst writes
  constant MODE_REG : std_logic_vector(12 downto 0) := "0000000110001";

  -- command encodings: cs_n & ras_n & cas_n & we_n
  constant CMD_NOP       : std_logic_vector(3 downto 0) := "0111";
  constant CMD_ACTIVE    : std_logic_vector(3 downto 0) := "0011";
  constant CMD_READ      : std_logic_vector(3 downto 0) := "0101";
  constant CMD_WRITE     : std_logic_vector(3 downto 0) := "0100";
  constant CMD_PRECHARGE : std_logic_vector(3 downto 0) := "0010";
  constant CMD_REFRESH   : std_logic_vector(3 downto 0) := "0001";
  constant CMD_LOAD_MODE : std_logic_vector(3 downto 0) := "0000";

  -- Clock cycles that cover a time (rounded up).
  function cycles(ps : natural; tck_ps : natural) return natural;

end package sdram_pkg;

package body sdram_pkg is

  function cycles(ps : natural; tck_ps : natural) return natural is
  begin
    return (ps + tck_ps - 1) / tck_ps;
  end function;

end package body sdram_pkg;
