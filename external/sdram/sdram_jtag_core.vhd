library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- The JTAG side of the SDRAM debug port: the logic behind a Virtual JTAG instance
-- (sld_virtual_jtag in the board's top, driven by the testbench in simulation), on the
-- JTAG clock tck, and its hand-off to sdram_dbg_master, which runs on another clock.
--
-- The Virtual JTAG has an instruction register (here 2 bits) and one data register per
-- instruction. Instruction 1 selects the 64-bit DEBUG register; any other instruction leaves
-- a 1-bit bypass. A shift of the DEBUG register brings in a command and sends out the
-- state of the last one:
--
--   shifted in   [63:60] op   [59:56] byte enables   [55:32] word address   [31:0] data
--   shifted out  [63:56] status   [55:32] word accessed last   [31:0] data read
--
--   status bit 0 busy: the previous command has not finished (its data and word are not valid yet)
--   status bit 1 error: the controller did not answer
--   status bit 2 the SDRAM is initialized
--   status bit 3 overrun: a command arrived while busy and was dropped (cleared by the next command)
--
-- The command goes out when the shift ends (the update state). The ops are those of
-- sdram_dbg_master, except op 0: it sends nothing, so a shift of op 0 only reads the status.
-- The status of a command is only up to date a few JTAG clocks after it was sent, so the first
-- shift after a command may still show busy; the next one does not. cmd_tog, op, be, addr and data hold until the next accepted command;
-- done_tog and rsp_* are read through a synchronizer on tck.
entity sdram_jtag_core is
  port (
    i_tck       : in  std_logic;
    i_tdi       : in  std_logic;
    o_tdo       : out std_logic;
    i_ir_in     : in  std_logic_vector(1 downto 0);
    i_state_cdr : in  std_logic;
    i_state_sdr : in  std_logic;
    i_state_udr : in  std_logic;
    i_state_uir : in  std_logic;

    -- toward sdram_dbg_master
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
end entity sdram_jtag_core;

architecture rtl of sdram_jtag_core is

  signal ir       : std_logic_vector(1 downto 0) := (others => '0');
  signal sr       : std_logic_vector(63 downto 0) := (others => '0');
  signal bypass   : std_logic := '0';
  signal cmd_i    : std_logic := '0';
  signal done_s   : std_logic_vector(1 downto 0) := "00";
  signal overrun  : std_logic := '0';
  signal busy     : std_logic;
  signal op_r     : std_logic_vector(3 downto 0) := (others => '0');
  signal be_r     : std_logic_vector(3 downto 0) := (others => '0');
  signal addr_r   : std_logic_vector(23 downto 0) := (others => '0');
  signal data_r   : std_logic_vector(31 downto 0) := (others => '0');

begin

  busy    <= '1' when cmd_i /= done_s(1) else '0';
  o_cmd_tog <= cmd_i;
  o_op      <= op_r;
  o_be      <= be_r;
  o_addr    <= addr_r;
  o_data    <= data_r;
  o_tdo     <= sr(0) when ir = "01" else bypass;

  process (i_tck)
  begin
    if rising_edge(i_tck) then
      done_s <= done_s(0) & i_done_tog;

      if i_state_uir = '1' then
        ir <= i_ir_in;
      end if;

      if i_state_cdr = '1' then
        if ir = "01" then
          sr <= ("0000" & overrun & i_rsp_status(2 downto 1) & busy) & i_rsp_addr & i_rsp_data;
        end if;
      elsif i_state_sdr = '1' then
        if ir = "01" then
          sr <= i_tdi & sr(63 downto 1);
        else
          bypass <= i_tdi;
        end if;
      elsif i_state_udr = '1' then
        -- op 0 is only a way to read the status: it sends nothing
        if ir = "01" and sr(63 downto 60) /= "0000" then
          if busy = '1' then
            overrun <= '1';
          else
            overrun <= '0';
            op_r    <= sr(63 downto 60);
            be_r    <= sr(59 downto 56);
            addr_r  <= sr(55 downto 32);
            data_r  <= sr(31 downto 0);
            cmd_i   <= not cmd_i;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
