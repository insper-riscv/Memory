library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- A UART whose other end is a host on JTAG instead of a serial line: the core writes bytes
-- the host reads, and the host writes bytes the core reads.
--
-- Core side (clock clk): three word registers, one access per pulse of we or re.
--
--   word 0  TXDATA  write: queue the byte in bits 7:0 for the host (dropped, and flagged, if the
--                   queue is full); read: 0
--   word 1  RXDATA  read: bit 8 = a byte was waiting, bits 7:0 = that byte, which is removed;
--                   bit 8 = 0 when empty; write: ignored
--   word 2  STATUS  read: bits 7:0 free places in the transmit queue (0 to 64), bits 15:8 bytes
--                   waiting in the receive queue (0 to 64), bit 16 a byte was dropped since the
--                   last read of this register (the read clears it); write: ignored
--
-- Host side: the logic behind a Virtual JTAG instance (sld_virtual_jtag in the board's top, driven
-- by the testbench in simulation) on tck. Instruction 1 selects a 48-bit register. A scan sends
-- one command and brings back the answer to the previous one:
--
--   shifted in   [8] push   [7:0] byte to give to the core (taken only if push = 1)
--   shifted out  [31:0] up to four bytes from the core, the first one in bits 7:0
--                [34:32] how many of them are valid
--                [35] the push of the previous command was dropped (receive queue full)
--                [36] the previous scan was dropped: the command before it had not finished
--                [47:40] bytes still waiting in the transmit queue
--
-- Every scan that is accepted takes up to four bytes out of the transmit queue. The clock of the
-- JTAG chain only runs during a scan, so an answer reaches the scan logic during the next scan
-- and is shown by the one after it: a scan shows the answer to the command of the scan before the
-- previous one. An answer is shown once. A host that wants the output keeps scanning.
--
-- The command crosses to clk with a toggle and two flip-flops; the byte and push flag hold until
-- the next accepted command, and the answer crosses back the same way.
entity jtag_uart is
  generic (
    LOG2_DEPTH : natural := 6
  );
  port (
    clk     : in  std_logic;
    rst     : in  std_logic;  -- synchronous, active high

    -- core side, one pulse per access
    addr    : in  std_logic_vector(7 downto 0);  -- word offset
    wdata   : in  std_logic_vector(31 downto 0);
    we      : in  std_logic;
    re      : in  std_logic;
    rdata   : out std_logic_vector(31 downto 0);  -- valid in the cycle of the pulse

    -- host side (see above)
    tck       : in  std_logic;
    tdi       : in  std_logic;
    tdo       : out std_logic;
    ir_in     : in  std_logic_vector(1 downto 0);
    state_cdr : in  std_logic;
    state_sdr : in  std_logic;
    state_udr : in  std_logic;
    state_uir : in  std_logic
  );
end entity jtag_uart;

architecture rtl of jtag_uart is

  constant DEPTH : natural := 2 ** LOG2_DEPTH;
  type fifo_t is array (0 to DEPTH - 1) of std_logic_vector(7 downto 0);

  -- clk domain
  signal tx_mem    : fifo_t := (others => (others => '0'));
  signal rx_mem    : fifo_t := (others => (others => '0'));
  signal tx_w, tx_r : unsigned(LOG2_DEPTH downto 0) := (others => '0');
  signal rx_w, rx_r : unsigned(LOG2_DEPTH downto 0) := (others => '0');
  signal lost      : std_logic := '0';
  signal cmd_s     : std_logic_vector(1 downto 0) := "00";
  signal done_i    : std_logic := '0';
  signal resp      : std_logic_vector(47 downto 0) := (others => '0');
  signal tx_level  : unsigned(LOG2_DEPTH downto 0);
  signal rx_level  : unsigned(LOG2_DEPTH downto 0);

  -- tck domain
  signal ir        : std_logic_vector(1 downto 0) := (others => '0');
  signal sr        : std_logic_vector(47 downto 0) := (others => '0');
  signal bypass    : std_logic := '0';
  signal cmd_i     : std_logic := '0';
  signal done_s    : std_logic_vector(1 downto 0) := "00";
  signal seen      : std_logic := '0';
  signal held      : std_logic_vector(47 downto 0) := (others => '0');
  signal overrun   : std_logic := '0';
  signal busy      : std_logic;
  signal byte_r    : std_logic_vector(7 downto 0) := (others => '0');
  signal push_r    : std_logic := '0';

begin

  tx_level <= tx_w - tx_r;
  rx_level <= rx_w - rx_r;
  busy     <= '1' when cmd_i /= done_s(1) else '0';
  tdo      <= sr(0) when ir = "01" else bypass;

  -- the registers read by the core
  process (addr, rx_mem, rx_r, rx_level, tx_level, lost)
    variable free : unsigned(15 downto 0);
  begin
    rdata <= (others => '0');
    case to_integer(unsigned(addr)) is
      when 1 =>
        if rx_level /= 0 then
          rdata(8) <= '1';
          rdata(7 downto 0) <= rx_mem(to_integer(rx_r(LOG2_DEPTH - 1 downto 0)));
        end if;
      when 2 =>
        free := to_unsigned(DEPTH, 16) - resize(tx_level, 16);
        rdata(7 downto 0)  <= std_logic_vector(free(7 downto 0));
        rdata(15 downto 8) <= std_logic_vector(resize(rx_level, 8));
        rdata(16)          <= lost;
      when others =>
        null;
    end case;
  end process;

  process (clk)
    variable n      : natural range 0 to 4;
    variable taken  : std_logic_vector(31 downto 0);
    variable rxovf  : std_logic;
    variable tx_r_n : unsigned(LOG2_DEPTH downto 0);
    variable left   : unsigned(LOG2_DEPTH downto 0);
  begin
    if rising_edge(clk) then
      cmd_s <= cmd_s(0) & cmd_i;

      if rst = '1' then
        tx_w <= (others => '0');
        tx_r <= (others => '0');
        rx_w <= (others => '0');
        rx_r <= (others => '0');
        lost <= '0';
        done_i <= cmd_s(1);   -- a command that was pending before the reset is not run
        resp <= (others => '0');
      else
        -- the core
        if we = '1' and to_integer(unsigned(addr)) = 0 then
          if tx_level = DEPTH then
            lost <= '1';
          else
            tx_mem(to_integer(tx_w(LOG2_DEPTH - 1 downto 0))) <= wdata(7 downto 0);
            tx_w <= tx_w + 1;
          end if;
        end if;
        if re = '1' then
          if to_integer(unsigned(addr)) = 1 and rx_level /= 0 then
            rx_r <= rx_r + 1;
          elsif to_integer(unsigned(addr)) = 2 then
            lost <= '0';
          end if;
        end if;

        -- a command from the host
        if cmd_s(1) /= done_i then
          if tx_level > 4 then
            n := 4;
          else
            n := to_integer(tx_level);
          end if;
          taken := (others => '0');
          for i in 0 to 3 loop
            if i < n then
              taken(8 * i + 7 downto 8 * i) := tx_mem(to_integer(tx_r(LOG2_DEPTH - 1 downto 0) + i));
            end if;
          end loop;
          tx_r_n := tx_r + n;
          tx_r   <= tx_r_n;
          left   := tx_w - tx_r_n;

          rxovf := '0';
          if push_r = '1' then
            if rx_level = DEPTH then
              rxovf := '1';
            else
              rx_mem(to_integer(rx_w(LOG2_DEPTH - 1 downto 0))) <= byte_r;
              rx_w <= rx_w + 1;
            end if;
          end if;

          resp <= std_logic_vector(resize(left, 8)) & "00000" & std_logic_vector(to_unsigned(n, 3))
                  & taken;
          resp(35) <= rxovf;
          done_i <= not done_i;
        end if;
      end if;
    end if;
  end process;

  process (tck)
  begin
    if rising_edge(tck) then
      done_s <= done_s(0) & done_i;

      if state_uir = '1' then
        ir <= ir_in;
      end if;

      if state_cdr = '1' then
        if ir = "01" then
          sr <= held(47 downto 37) & overrun & held(35 downto 0);
          -- an answer is shown once
          held(34 downto 0) <= (others => '0');
        end if;
      elsif state_sdr = '1' then
        if ir = "01" then
          sr <= tdi & sr(47 downto 1);
        else
          bypass <= tdi;
        end if;
      elsif state_udr = '1' then
        if ir = "01" then
          -- the answer of the command before is now in the other clock's register for good (the
          -- shift lasted many tck edges): keep it for the next capture
          if done_s(1) /= seen then
            held <= resp;
            seen <= done_s(1);
          end if;
          if busy = '1' then
            overrun <= '1';
          else
            overrun <= '0';
            byte_r  <= sr(7 downto 0);
            push_r  <= sr(8);
            cmd_i   <= not cmd_i;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
