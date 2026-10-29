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
-- axi_master_bridge turns into AXI4-Lite.
--
-- flush: a request (one pulse is enough) to write back every dirty line (the lines stay valid and
-- become clean), and with invalidate in the same clock then drops every line, as a program does
-- before the host loads the next one behind the cache's back. It starts as soon as the cache is idle, before any access that is waiting; busy is
-- high from the clock after the request until flush_done pulses. An access that comes meanwhile
-- waits for the flush to finish. Nothing else writes the SDRAM
-- behind the cache's back in normal operation, so a program that loads code or data with another
-- master (the JTAG debug port) does it with the cache invalid, as it is after the reset.
--
-- WRITE_THROUGH: every store also goes to the memory before it completes, and a store that misses
-- does not bring the line in (write-around), so no line is ever dirty and the memory always holds
-- what the core wrote. Loads still hit in the cache. It is what a debug port that reads the SDRAM
-- behind the cache needs: the host sees every store as soon as it completes, with no flush. Lines of
-- the cache can still be older than the memory when the host writes it; an invalidate (see flush)
-- before the host loads something new drops them.
--
-- Address split of the SDRAM space (64 MB): bits 25:12 tag, 11:4 line, 3:2 word. The bits above
-- 25 are not stored; the memory side puts BASE there.
entity dcache is
  generic (
    BASE          : std_logic_vector(5 downto 0) := "010000";  -- bits 31:26 of the SDRAM addresses (0x40000000)
    WRITE_THROUGH : boolean := false                           -- see the header
  );
  port (
    i_clk         : in  std_logic;
    i_rst         : in  std_logic;  -- synchronous, active high

    -- core side
    i_addr        : in  std_logic_vector(31 downto 0);
    i_wdata       : in  std_logic_vector(31 downto 0);
    i_byteena     : in  std_logic_vector(3 downto 0);
    i_rden        : in  std_logic;
    i_wren        : in  std_logic;
    i_mem_advance : in  std_logic;
    o_ready       : out std_logic;
    o_rdata       : out std_logic_vector(31 downto 0);

    i_flush       : in  std_logic;
    i_invalidate  : in  std_logic := '0';   -- with flush: after the write-back, every line becomes invalid
    o_flush_done  : out std_logic;
    o_busy        : out std_logic;

    -- memory side (one word at a time)
    o_d_addr      : out std_logic_vector(31 downto 0);
    o_d_wdata     : out std_logic_vector(31 downto 0);
    o_d_byteena   : out std_logic_vector(3 downto 0);
    o_d_rden      : out std_logic;
    o_d_wren      : out std_logic;
    o_d_advance   : out std_logic;
    i_d_ready     : in  std_logic;
    i_d_rdata     : in  std_logic_vector(31 downto 0);
    o_d_line      : out std_logic;
    o_d_wdata_x   : out std_logic_vector(95 downto 0);
    i_d_rdata_x   : in  std_logic_vector(95 downto 0) := (others => '0')
  );
end entity dcache;

architecture rtl of dcache is

  type state_t is (
    S_IDLE, S_LOOK, S_DONE,
    S_WB_RD, S_WB_CAP, S_WB_REQ, S_WB_WAIT,
    S_FILL_REQ, S_FILL_WAIT, S_FILL_GET,
    S_FL_TAG, S_FL_CHK, S_FL_NEXT,
    S_WT_REQ, S_WT_WAIT);
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
  signal inv_pend, inv_run : std_logic := '0';
  signal f_idx    : unsigned(7 downto 0) := (others => '0');
  signal hit      : std_logic;

  signal pend     : std_logic_vector(31 downto 0) := (others => '0');
  signal rdata_q  : std_logic_vector(31 downto 0) := (others => '0');
  signal d_rden_i, d_wren_i : std_logic := '0';
  signal d_be_i   : std_logic_vector(3 downto 0) := "1111";
  signal d_line_i : std_logic := '0';
  signal wb_q     : std_logic_vector(127 downto 0) := (others => '0');   -- the line being written back
  signal fill_w   : std_logic_vector(31 downto 0);                        -- word cnt of the line that arrived
  signal d_addr_i : std_logic_vector(31 downto 0) := (others => '0');
  signal d_wdata_i : std_logic_vector(31 downto 0) := (others => '0');
  signal fd_i     : std_logic := '0';

begin

  req_tag <= i_addr(25 downto 12);
  req_idx <= i_addr(11 downto 4);
  cur_idx <= std_logic_vector(f_idx) when flushing = '1' else req_idx;
  hit     <= valid(to_integer(unsigned(cur_idx))) when tag_rd = req_tag else '0';

  -- read addresses: the word of the access while it is looked up, the word being moved otherwise
  ram_ra <= i_addr(11 downto 2) when (st = S_IDLE or st = S_LOOK) else cur_idx & std_logic_vector(cnt);
  tag_ra <= cur_idx;

  -- write port: a hit writes the word, a fill writes the word that arrived
  ram_we <= '1' when (st = S_LOOK and hit = '1' and i_wren = '1') or st = S_FILL_GET else '0';
  ram_wa <= i_addr(11 downto 2) when st = S_LOOK else req_idx & std_logic_vector(cnt);
  fill_w <= i_d_rdata when cnt = "00" else
            i_d_rdata_x(31 downto 0)  when cnt = "01" else
            i_d_rdata_x(63 downto 32) when cnt = "10" else
            i_d_rdata_x(95 downto 64);
  ram_wd <= i_wdata when st = S_LOOK else fill_w;
  ram_be <= i_byteena when st = S_LOOK else "1111";
  tag_we <= '1' when st = S_FILL_GET and cnt = "11" else '0';
  tag_wa <= req_idx;
  tag_wd <= req_tag;

  process (i_clk)
  begin
    if rising_edge(i_clk) then
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

  o_ready      <= '1' when st = S_DONE else '0';
  o_rdata      <= rdata_q;
  o_busy       <= flush_pend or flushing;
  o_flush_done <= fd_i;

  o_d_addr    <= d_addr_i;
  o_d_wdata   <= d_wdata_i;
  o_d_byteena <= d_be_i;
  o_d_rden    <= d_rden_i;
  o_d_wren    <= d_wren_i;
  o_d_line    <= d_line_i;
  o_d_wdata_x <= wb_q(127 downto 32);
  o_d_advance <= i_d_ready;

  process (i_clk)
    variable ci : integer range 0 to 255;
  begin
    if rising_edge(i_clk) then
      fd_i <= '0';
      if i_rst = '1' then
        st       <= S_IDLE;
        valid    <= (others => '0');
        dirty    <= (others => '0');
        flushing <= '0';
        flush_pend <= '0';
        inv_pend   <= '0';
        inv_run    <= '0';
        d_rden_i <= '0';
        d_wren_i <= '0';
        cnt      <= (others => '0');
      else
        ci := to_integer(unsigned(cur_idx));
        if i_flush = '1' then
          flush_pend <= '1';
          inv_pend   <= i_invalidate;
        end if;
        case st is

          when S_IDLE =>
            if flush_pend = '1' then
              flush_pend <= '0';
              inv_run    <= inv_pend;
              flushing   <= '1';
              f_idx      <= (others => '0');
              st         <= S_FL_TAG;
            elsif i_rden = '1' or i_wren = '1' then
              st <= S_LOOK;
            end if;

          when S_LOOK =>
            if WRITE_THROUGH and i_wren = '1' then
              -- the cache RAM takes the word on a hit (ram_we); the memory takes it either way
              st <= S_WT_REQ;
            elsif hit = '1' then
              if i_wren = '1' then
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
            if i_mem_advance = '1' then
              if i_wren = '0' then
                rdata_q <= pend;
              end if;
              st <= S_IDLE;
            end if;

          -- write-through: the word of the store goes to the memory
          when S_WT_REQ =>
            d_addr_i  <= BASE & i_addr(25 downto 2) & "00";
            d_wdata_i <= i_wdata;
            d_be_i    <= i_byteena;
            d_wren_i  <= '1';
            st        <= S_WT_WAIT;

          when S_WT_WAIT =>
            if i_d_ready = '1' then
              d_wren_i <= '0';
              d_be_i   <= "1111";
              st       <= S_DONE;
            end if;

          -- write the dirty line back: read its four words out of the RAM, then one line request
          when S_WB_RD =>
            st <= S_WB_CAP;

          when S_WB_CAP =>
            wb_q(32 * to_integer(cnt) + 31 downto 32 * to_integer(cnt)) <= ram_rd;
            if cnt = "11" then
              st <= S_WB_REQ;
            else
              cnt <= cnt + 1;
              st  <= S_WB_RD;
            end if;

          when S_WB_REQ =>
            d_addr_i  <= BASE & tag_rd & cur_idx & "0000";
            d_wdata_i <= wb_q(31 downto 0);
            d_line_i  <= '1';
            d_wren_i  <= '1';
            st        <= S_WB_WAIT;

          when S_WB_WAIT =>
            if i_d_ready = '1' then
              d_wren_i  <= '0';
              d_line_i  <= '0';
              cnt       <= (others => '0');
              dirty(ci) <= '0';
              if flushing = '1' then
                st <= S_FL_NEXT;
              else
                st <= S_FILL_REQ;
              end if;
            end if;

          -- bring the line in: one line request, then its words into the RAM
          when S_FILL_REQ =>
            d_addr_i <= BASE & req_tag & req_idx & "0000";
            d_line_i <= '1';
            d_rden_i <= '1';
            st       <= S_FILL_WAIT;

          when S_FILL_WAIT =>
            if i_d_ready = '1' then
              d_rden_i <= '0';
              d_line_i <= '0';
              cnt      <= (others => '0');
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
              if inv_run = '1' then
                valid <= (others => '0');
              end if;
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
