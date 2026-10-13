library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- The core's data cache: 4 KB, direct-mapped, lines of 16 bytes (four words), write-back with
-- write-allocate. It sits on the memory path of ext_interconnect (the addresses of the SDRAM); the
-- peripherals never reach it.
--
-- Core side, the same contract as sdram_cpu_bridge: the access sits on addr/wdata/byteena/rden/wren
-- while the memory stage is stopped; ready goes high when the access is done and stays high, as a
-- level, until mem_advance; rdata only changes on that edge. A hit takes two clocks (the RAMs have a
-- registered read, as the FPGA's block RAMs do); a miss takes the line's four word accesses, plus
-- four more first if the line to replace is dirty.
--
-- Memory side: one word at a time on d_*, with the same contract (a request is held until d_ready,
-- and d_ready is taken by the cache itself, as the rest of the pipeline is stopped). AXI4-Lite
-- cannot carry a burst, so the line moves as four single-word accesses; the port is the one
-- axil_master_bridge turns into AXI4-Lite.
--
-- flush: a request (one pulse is enough) to write back every dirty line (the lines stay valid and
-- become clean). It starts as soon as the cache is idle, before any access that is waiting; busy is
-- high from the clock after the request until flush_done pulses. An access that comes meanwhile
-- waits for the flush to finish. Nothing else writes the SDRAM
-- behind the cache's back in normal operation, so a program that loads code or data with another
-- master (the JTAG debug port) does it with the cache invalid, as it is after the reset.
--
-- Address split of the SDRAM space (64 MB): bits 25:12 tag, 11:4 line, 3:2 word. The bits above
-- 25 are not stored; the memory side puts BASE there.
entity dcache is
  generic (
    BASE : std_logic_vector(5 downto 0) := "010000"  -- bits 31:26 of the SDRAM addresses (0x40000000)
  );
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;  -- synchronous, active high

    -- core side
    addr        : in  std_logic_vector(31 downto 0);
    wdata       : in  std_logic_vector(31 downto 0);
    byteena     : in  std_logic_vector(3 downto 0);
    rden        : in  std_logic;
    wren        : in  std_logic;
    mem_advance : in  std_logic;
    ready       : out std_logic;
    rdata       : out std_logic_vector(31 downto 0);

    flush       : in  std_logic;
    flush_done  : out std_logic;
    busy        : out std_logic;

    -- memory side (one word at a time)
    d_addr      : out std_logic_vector(31 downto 0);
    d_wdata     : out std_logic_vector(31 downto 0);
    d_byteena   : out std_logic_vector(3 downto 0);
    d_rden      : out std_logic;
    d_wren      : out std_logic;
    d_advance   : out std_logic;
    d_ready     : in  std_logic;
    d_rdata     : in  std_logic_vector(31 downto 0)
  );
end entity dcache;

architecture rtl of dcache is

  type state_t is (
    S_IDLE, S_LOOK, S_DONE,
    S_WB_RD, S_WB_REQ, S_WB_WAIT,
    S_FILL_REQ, S_FILL_WAIT, S_FILL_GET,
    S_FL_TAG, S_FL_CHK, S_FL_NEXT);
  signal st : state_t := S_IDLE;

  type data_t is array (0 to 1023) of std_logic_vector(31 downto 0);
  type tag_t  is array (0 to 255) of std_logic_vector(13 downto 0);
  signal data_ram : data_t := (others => (others => '0'));
  signal tag_ram  : tag_t  := (others => (others => '0'));
  signal valid    : std_logic_vector(255 downto 0) := (others => '0');
  signal dirty    : std_logic_vector(255 downto 0) := (others => '0');

  -- the RAM ports: a registered read, a write with byte enables
  signal ram_ra, ram_wa : std_logic_vector(9 downto 0);
  signal ram_rd, ram_wd : std_logic_vector(31 downto 0);
  signal ram_be         : std_logic_vector(3 downto 0);
  signal ram_we         : std_logic;
  signal tag_ra, tag_wa : std_logic_vector(7 downto 0);
  signal tag_rd, tag_wd : std_logic_vector(13 downto 0);
  signal tag_we         : std_logic;

  signal req_tag  : std_logic_vector(13 downto 0);
  signal req_idx  : std_logic_vector(7 downto 0);
  signal cur_idx  : std_logic_vector(7 downto 0);   -- the line being worked on
  signal cnt      : unsigned(1 downto 0) := (others => '0');
  signal flushing : std_logic := '0';
  signal flush_pend : std_logic := '0';
  signal f_idx    : unsigned(7 downto 0) := (others => '0');
  signal hit      : std_logic;

  signal pend     : std_logic_vector(31 downto 0) := (others => '0');
  signal rdata_q  : std_logic_vector(31 downto 0) := (others => '0');
  signal d_rden_i, d_wren_i : std_logic := '0';
  signal d_addr_i : std_logic_vector(31 downto 0) := (others => '0');
  signal d_wdata_i : std_logic_vector(31 downto 0) := (others => '0');
  signal fd_i     : std_logic := '0';

begin

  req_tag <= addr(25 downto 12);
  req_idx <= addr(11 downto 4);
  cur_idx <= std_logic_vector(f_idx) when flushing = '1' else req_idx;
  hit     <= valid(to_integer(unsigned(cur_idx))) when tag_rd = req_tag else '0';

  -- read addresses: the word of the access while it is looked up, the word being moved otherwise
  ram_ra <= addr(11 downto 2) when (st = S_IDLE or st = S_LOOK) else cur_idx & std_logic_vector(cnt);
  tag_ra <= cur_idx;

  -- write port: a hit writes the word, a fill writes the word that arrived
  ram_we <= '1' when (st = S_LOOK and hit = '1' and wren = '1') or st = S_FILL_GET else '0';
  ram_wa <= addr(11 downto 2) when st = S_LOOK else req_idx & std_logic_vector(cnt);
  ram_wd <= wdata when st = S_LOOK else d_rdata;
  ram_be <= byteena when st = S_LOOK else "1111";
  tag_we <= '1' when st = S_FILL_GET and cnt = "11" else '0';
  tag_wa <= req_idx;
  tag_wd <= req_tag;

  process (clk)
  begin
    if rising_edge(clk) then
      ram_rd <= data_ram(to_integer(unsigned(ram_ra)));
      if ram_we = '1' then
        for b in 0 to 3 loop
          if ram_be(b) = '1' then
            data_ram(to_integer(unsigned(ram_wa)))(8 * b + 7 downto 8 * b) <= ram_wd(8 * b + 7 downto 8 * b);
          end if;
        end loop;
      end if;
      tag_rd <= tag_ram(to_integer(unsigned(tag_ra)));
      if tag_we = '1' then
        tag_ram(to_integer(unsigned(tag_wa))) <= tag_wd;
      end if;
    end if;
  end process;

  ready      <= '1' when st = S_DONE else '0';
  rdata      <= rdata_q;
  busy       <= flush_pend or flushing;
  flush_done <= fd_i;

  d_addr    <= d_addr_i;
  d_wdata   <= d_wdata_i;
  d_byteena <= "1111";
  d_rden    <= d_rden_i;
  d_wren    <= d_wren_i;
  d_advance <= d_ready;

  process (clk)
    variable ci : integer range 0 to 255;
  begin
    if rising_edge(clk) then
      fd_i <= '0';
      if rst = '1' then
        st       <= S_IDLE;
        valid    <= (others => '0');
        dirty    <= (others => '0');
        flushing <= '0';
        flush_pend <= '0';
        d_rden_i <= '0';
        d_wren_i <= '0';
        cnt      <= (others => '0');
      else
        ci := to_integer(unsigned(cur_idx));
        if flush = '1' then
          flush_pend <= '1';
        end if;
        case st is

          when S_IDLE =>
            if flush_pend = '1' then
              flush_pend <= '0';
              flushing   <= '1';
              f_idx      <= (others => '0');
              st         <= S_FL_TAG;
            elsif rden = '1' or wren = '1' then
              st <= S_LOOK;
            end if;

          when S_LOOK =>
            if hit = '1' then
              if wren = '1' then
                dirty(ci) <= '1';
              else
                pend <= ram_rd;
              end if;
              st <= S_DONE;
            else
              cnt <= (others => '0');
              if valid(ci) = '1' and dirty(ci) = '1' then
                st <= S_WB_RD;
              else
                st <= S_FILL_REQ;
              end if;
            end if;

          when S_DONE =>
            if mem_advance = '1' then
              if wren = '0' then
                rdata_q <= pend;
              end if;
              st <= S_IDLE;
            end if;

          -- write the dirty line back: read a word of it, send it, four times
          when S_WB_RD =>
            st <= S_WB_REQ;

          when S_WB_REQ =>
            d_addr_i  <= BASE & tag_rd & cur_idx & std_logic_vector(cnt) & "00";
            d_wdata_i <= ram_rd;
            d_wren_i  <= '1';
            st        <= S_WB_WAIT;

          when S_WB_WAIT =>
            if d_ready = '1' then
              d_wren_i <= '0';
              if cnt = "11" then
                cnt       <= (others => '0');
                dirty(ci) <= '0';
                if flushing = '1' then
                  st <= S_FL_NEXT;
                else
                  st <= S_FILL_REQ;
                end if;
              else
                cnt <= cnt + 1;
                st  <= S_WB_RD;
              end if;
            end if;

          -- bring the line in, one word at a time
          when S_FILL_REQ =>
            d_addr_i <= BASE & req_tag & req_idx & std_logic_vector(cnt) & "00";
            d_rden_i <= '1';
            st       <= S_FILL_WAIT;

          when S_FILL_WAIT =>
            if d_ready = '1' then
              d_rden_i <= '0';
              st       <= S_FILL_GET;
            end if;

          when S_FILL_GET =>
            if cnt = "11" then
              valid(ci) <= '1';
              dirty(ci) <= '0';
              cnt       <= (others => '0');
              st        <= S_IDLE;
            else
              cnt <= cnt + 1;
              st  <= S_FILL_REQ;
            end if;

          -- flush: the lines one by one
          when S_FL_TAG =>
            st <= S_FL_CHK;

          when S_FL_CHK =>
            if valid(ci) = '1' and dirty(ci) = '1' then
              cnt <= (others => '0');
              st  <= S_WB_RD;
            else
              st <= S_FL_NEXT;
            end if;

          when S_FL_NEXT =>
            if f_idx = 255 then
              flushing <= '0';
              fd_i     <= '1';
              st       <= S_IDLE;
            else
              f_idx <= f_idx + 1;
              st    <= S_FL_TAG;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
