library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- The core's instruction cache: 4 KB, direct-mapped, lines of 16 bytes (four words), read only.
-- It sits on the fetch path for the SDRAM addresses; the BOOT_ROM and the FLASH do not go
-- through it.
--
-- Core side: addr is the fetch address (the PC) and sel says it is an SDRAM address. The RAMs
-- have a registered read, as the FPGA's block RAMs do, so the instruction of the address that was
-- on addr at a clock edge is on data after that edge, and ready says it is the right one: the line
-- is valid, its tag matches, and addr has not changed since that edge. The core samples ready and
-- data at its own edge, a fraction of a clock after this one; while ready is low it holds the
-- address, and the cache brings the line in. Nothing here depends on the core's clock phase beyond
-- that order.
--
-- Memory side: the same contract as dcache's. One line request (four words, d_line high, the last
-- three words on d_rdata_x) is held on d_addr and d_rden until d_ready; d_advance answers it.
--
-- invalidate: one pulse drops every line in one clock. A line fill that is still going on when the
-- pulse arrives is dropped as well (it may hold code from before the stores that the program
-- finished), so nothing the cache holds is older than the invalidate.
--
-- Nothing writes the SDRAM behind the cache except the debug port, which does it with the core
-- stopped and the cache invalidated (as after the reset), and the core's own stores, which the
-- cache does not observe: only a fence.i makes them visible to the fetch.
--
-- Address split of the SDRAM space (64 MB): bits 25:12 tag, 11:4 line, 3:2 word. The bits above
-- 25 are not stored; the memory side puts BASE there.
entity icache is
  generic (
    BASE : std_logic_vector(5 downto 0) := "010000"   -- bits 31:26 of the SDRAM addresses (0x40000000)
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;  -- synchronous, active high

    -- fetch side
    addr       : in  std_logic_vector(31 downto 0);
    sel        : in  std_logic;
    ready      : out std_logic;
    data       : out std_logic_vector(31 downto 0);
    invalidate : in  std_logic := '0';

    -- memory side
    d_addr     : out std_logic_vector(31 downto 0);
    d_rden     : out std_logic;
    d_advance  : out std_logic;
    d_ready    : in  std_logic;
    d_rdata    : in  std_logic_vector(31 downto 0);
    d_line     : out std_logic;
    d_rdata_x  : in  std_logic_vector(95 downto 0) := (others => '0')
  );
end entity icache;

architecture rtl of icache is

  type state_t is (S_IDLE, S_FILL_REQ, S_FILL_WAIT, S_FILL_GET, S_SETTLE);
  signal st : state_t := S_IDLE;

  type data_t is array (0 to 1023) of std_logic_vector(31 downto 0);
  type tag_t  is array (0 to 255) of std_logic_vector(13 downto 0);
  signal data_ram : data_t := (others => (others => '0'));
  signal tag_ram  : tag_t  := (others => (others => '0'));
  signal valid    : std_logic_vector(255 downto 0) := (others => '0');

  -- the registered read: what the RAMs held for the address of the last clock edge
  signal ram_rd   : std_logic_vector(31 downto 0) := (others => '0');
  signal tag_rd   : std_logic_vector(13 downto 0) := (others => '0');
  signal valid_rd : std_logic := '0';
  signal addr_q   : std_logic_vector(31 downto 0) := (others => '0');
  signal sel_q    : std_logic := '0';

  signal tag_match : std_logic;
  signal hit       : std_logic;

  signal fill_tag : std_logic_vector(13 downto 0);
  signal fill_idx : std_logic_vector(7 downto 0);
  signal cnt      : unsigned(1 downto 0) := (others => '0');
  signal drop     : std_logic := '0';
  signal fill_w   : std_logic_vector(31 downto 0);
  signal ram_we, tag_we : std_logic;
  signal ram_wa : std_logic_vector(9 downto 0);
  signal d_rden_i : std_logic := '0';
  signal d_line_i : std_logic := '0';
  signal d_addr_i : std_logic_vector(31 downto 0) := (others => '0');

begin

  tag_match <= '1' when tag_rd = addr_q(25 downto 12) else '0';
  hit       <= sel_q and valid_rd and tag_match;
  ready     <= hit when addr_q = addr else '0';
  data      <= ram_rd;

  fill_w <= d_rdata when cnt = "00" else
            d_rdata_x(31 downto 0)  when cnt = "01" else
            d_rdata_x(63 downto 32) when cnt = "10" else
            d_rdata_x(95 downto 64);
  ram_wa <= fill_idx & std_logic_vector(cnt);
  ram_we <= '1' when st = S_FILL_GET else '0';
  tag_we <= '1' when st = S_FILL_GET and cnt = "11" else '0';

  process (clk)
  begin
    if rising_edge(clk) then
      ram_rd   <= data_ram(to_integer(unsigned(addr(11 downto 2))));
      tag_rd   <= tag_ram(to_integer(unsigned(addr(11 downto 4))));
      valid_rd <= valid(to_integer(unsigned(addr(11 downto 4))));
      addr_q   <= addr;
      sel_q    <= sel;
      if ram_we = '1' then
        data_ram(to_integer(unsigned(ram_wa))) <= fill_w;
      end if;
      if tag_we = '1' then
        tag_ram(to_integer(unsigned(fill_idx))) <= fill_tag;
      end if;
    end if;
  end process;

  d_addr    <= d_addr_i;
  d_rden    <= d_rden_i;
  d_line    <= d_line_i;
  d_advance <= d_ready;

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st       <= S_IDLE;
        valid    <= (others => '0');
        drop     <= '0';
        d_rden_i <= '0';
        d_line_i <= '0';
        cnt      <= (others => '0');
      else
        if invalidate = '1' then
          valid <= (others => '0');
          if st /= S_IDLE then
            drop <= '1';
          end if;
        end if;
        case st is

          when S_IDLE =>
            drop <= '0';
            -- a miss of the address that is still on addr: bring its line in
            if sel_q = '1' and hit = '0' and addr_q = addr and invalidate = '0' then
              fill_tag <= addr_q(25 downto 12);
              fill_idx <= addr_q(11 downto 4);
              st       <= S_FILL_REQ;
            end if;

          when S_FILL_REQ =>
            d_addr_i <= BASE & fill_tag & fill_idx & "0000";
            d_line_i <= '1';
            d_rden_i <= '1';
            st       <= S_FILL_WAIT;

          when S_FILL_WAIT =>
            if d_ready = '1' then
              d_rden_i <= '0';
              d_line_i <= '0';
              cnt      <= (others => '0');
              st       <= S_FILL_GET;
            end if;

          when S_FILL_GET =>
            if cnt = "11" then
              if drop = '0' and invalidate = '0' then
                valid(to_integer(unsigned(fill_idx))) <= '1';
              end if;
              cnt <= (others => '0');
              st  <= S_SETTLE;
            else
              cnt <= cnt + 1;
            end if;

          -- the registered read has to see the new tag and valid bit before the next lookup
          when S_SETTLE =>
            st <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
