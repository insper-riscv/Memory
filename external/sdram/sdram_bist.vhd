library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Built-in self test of the SDRAM, driven straight on the controller (no core, no
-- bridge): it writes known data over a range of words, reads it back and counts
-- the words that differ. It is the check of the pins, the clock phase and the
-- controller that does not depend on anything else of the system.
--
-- A run is picked by `mode` and started by a rising edge of `start`:
--   0  quick: window of 2^WINDOW_LOG2 words, address-dependent data, and the byte
--      masks (a masked byte must keep its old value, an enabled one must change)
--   1  patterns: the same window with all-zeros, all-ones, 0xAAAAAAAA, 0x55555555,
--      a walking one and a walking zero on each bit of the bus, then the address data
--      and its complement
--   2  sweep: the whole chip (2^SWEEP_LOG2 words), address data, then its complement
--   3  random: 2^RANDOM_LOG2 words at pseudo-random addresses, written and read back
--
-- The data of a word depends on its address in a way that never repeats inside
-- the chip (a stuck or crossed address line puts one word's data in another).
entity sdram_bist is
  generic (
    WINDOW_LOG2    : natural := 16;
    SWEEP_LOG2     : natural := 24;
    RANDOM_LOG2    : natural := 20;
    -- clocks to wait for one word before the run is declared failed
    TIMEOUT_CYCLES : natural := 4096
  );
  port (
    i_clk        : in  std_logic;
    i_rst        : in  std_logic;  -- synchronous, active high

    i_start      : in  std_logic;
    i_mode       : in  std_logic_vector(1 downto 0);
    i_init_done  : in  std_logic;

    o_busy       : out std_logic;
    o_done       : out std_logic;  -- a run finished (stays high until the next start)
    o_fail       : out std_logic;  -- a word differed, or the controller did not answer
    o_timeout    : out std_logic;
    o_phase      : out std_logic_vector(4 downto 0);
    o_err_count  : out std_logic_vector(31 downto 0);
    o_first_addr : out std_logic_vector(23 downto 0);
    o_first_exp  : out std_logic_vector(31 downto 0);
    o_first_got  : out std_logic_vector(31 downto 0);
    o_ops_done   : out std_logic_vector(31 downto 0);

    -- the request interface of sdram_ctrl, on the same clock
    o_c_req_tog  : out std_logic;
    i_c_ack_tog  : in  std_logic;
    o_c_we       : out std_logic;
    o_c_addr     : out std_logic_vector(23 downto 0);
    o_c_wdata    : out std_logic_vector(31 downto 0);
    o_c_be       : out std_logic_vector(3 downto 0);
    i_c_rdata    : in  std_logic_vector(31 downto 0)
  );
end entity sdram_bist;

architecture rtl of sdram_bist is

  type kind_t is (K_WRITE, K_READ, K_END);
  type phase_def_t is record
    kind     : kind_t;
    pat      : natural range 0 to 9;
    be       : std_logic_vector(3 downto 0);
    rnd      : boolean;
    cnt_log2 : natural;
  end record;

  function hash (w : unsigned(23 downto 0)) return std_logic_vector is
    variable hi : std_logic_vector(7 downto 0);
    variable lo : std_logic_vector(23 downto 0);
  begin
    hi := std_logic_vector(w(7 downto 0) xor w(15 downto 8) xor w(23 downto 16));
    lo := std_logic_vector(w xor x"5AC3A5");
    return hi & lo;
  end function;

  -- the data of word w for a pattern
  function expected (pat : natural; w : unsigned(23 downto 0)) return std_logic_vector is
    variable h : std_logic_vector(31 downto 0) := hash(w);
    variable one : std_logic_vector(31 downto 0);
  begin
    one := std_logic_vector(shift_left(to_unsigned(1, 32), to_integer(w(4 downto 0))));
    case pat is
      when 0 => return x"00000000";
      when 1 => return x"FFFFFFFF";
      when 2 => return x"AAAAAAAA";
      when 3 => return x"55555555";
      when 4 => return one;
      when 5 => return not one;
      when 6 => return h;
      when 7 => return not h;
      -- bytes 1 and 3 keep h, bytes 0 and 2 took the complement (a write of 7 with mask 0101 over 6)
      when 8 => return (h and x"FF00FF00") or ((not h) and x"00FF00FF");
      -- then bytes 1 and 3 took all-ones (mask 1010)
      when others => return x"FF00FF00" or ((not h) and x"00FF00FF");
    end case;
  end function;

  function def (m : std_logic_vector(1 downto 0); idx : natural) return phase_def_t is
    variable d : phase_def_t := (K_END, 0, "1111", false, 0);
    variable p : natural;
  begin
    case m is
      when "00" =>
        case idx is
          when 0 => d := (K_WRITE, 6, "1111", false, WINDOW_LOG2);
          when 1 => d := (K_WRITE, 7, "0101", false, WINDOW_LOG2);
          when 2 => d := (K_READ,  8, "1111", false, WINDOW_LOG2);
          when 3 => d := (K_WRITE, 1, "1010", false, WINDOW_LOG2);
          when 4 => d := (K_READ,  9, "1111", false, WINDOW_LOG2);
          when 5 => d := (K_WRITE, 6, "1111", false, WINDOW_LOG2);
          when 6 => d := (K_READ,  6, "1111", false, WINDOW_LOG2);
          when others => null;
        end case;
      when "01" =>
        if idx < 16 then
          p := idx / 2;
          if idx mod 2 = 0 then
            d := (K_WRITE, p, "1111", false, WINDOW_LOG2);
          else
            d := (K_READ,  p, "1111", false, WINDOW_LOG2);
          end if;
        end if;
      when "10" =>
        case idx is
          when 0 => d := (K_WRITE, 6, "1111", false, SWEEP_LOG2);
          when 1 => d := (K_READ,  6, "1111", false, SWEEP_LOG2);
          when 2 => d := (K_WRITE, 7, "1111", false, SWEEP_LOG2);
          when 3 => d := (K_READ,  7, "1111", false, SWEEP_LOG2);
          when others => null;
        end case;
      when others =>
        case idx is
          when 0 => d := (K_WRITE, 6, "1111", true, RANDOM_LOG2);
          when 1 => d := (K_READ,  6, "1111", true, RANDOM_LOG2);
          when others => null;
        end case;
    end case;
    return d;
  end function;

  constant SEED : unsigned(31 downto 0) := x"2545F491";

  type state_t is (ST_IDLE, ST_PHASE, ST_ISSUE, ST_TOG, ST_WAIT);
  signal st : state_t := ST_IDLE;

  signal start_q   : std_logic := '0';
  signal mode_l    : std_logic_vector(1 downto 0) := "00";
  signal idx       : natural range 0 to 31 := 0;
  signal cur       : phase_def_t := (K_END, 0, "1111", false, 0);
  signal n         : unsigned(31 downto 0) := (others => '0');   -- word of the phase
  signal limit     : unsigned(31 downto 0) := (others => '0');   -- last word of the phase
  signal lf        : unsigned(31 downto 0) := SEED;              -- address source of the random phases
  signal req_i     : std_logic := '0';
  signal exp_r     : std_logic_vector(31 downto 0) := (others => '0');
  signal addr_r    : unsigned(23 downto 0) := (others => '0');
  signal wait_cnt  : natural range 0 to TIMEOUT_CYCLES := 0;
  signal busy_i, done_i, fail_i, timeout_i : std_logic := '0';
  signal errs      : unsigned(31 downto 0) := (others => '0');
  signal ops       : unsigned(31 downto 0) := (others => '0');
  signal f_addr    : std_logic_vector(23 downto 0) := (others => '0');
  signal f_exp, f_got : std_logic_vector(31 downto 0) := (others => '0');

begin

  o_busy       <= busy_i;
  o_done       <= done_i;
  o_fail       <= fail_i;
  o_timeout    <= timeout_i;
  o_phase      <= std_logic_vector(to_unsigned(idx, 5));
  o_err_count  <= std_logic_vector(errs);
  o_first_addr <= f_addr;
  o_first_exp  <= f_exp;
  o_first_got  <= f_got;
  o_ops_done   <= std_logic_vector(ops);
  o_c_req_tog  <= req_i;

  process (i_clk)
    variable next_lf : unsigned(31 downto 0);
    variable last    : boolean;
    variable a       : unsigned(23 downto 0);
  begin
    if rising_edge(i_clk) then
      start_q <= i_start;

      if i_rst = '1' then
        st        <= ST_IDLE;
        req_i     <= '0';
        busy_i    <= '0';
        done_i    <= '0';
        fail_i    <= '0';
        timeout_i <= '0';
        errs      <= (others => '0');
        ops       <= (others => '0');
        idx       <= 0;
      else
        case st is

          when ST_IDLE =>
            if i_start = '1' and start_q = '0' and i_init_done = '1' then
              mode_l    <= i_mode;
              idx       <= 0;
              busy_i    <= '1';
              done_i    <= '0';
              fail_i    <= '0';
              timeout_i <= '0';
              errs      <= (others => '0');
              ops       <= (others => '0');
              f_addr    <= (others => '0');
              f_exp     <= (others => '0');
              f_got     <= (others => '0');
              st        <= ST_PHASE;
            end if;

          when ST_PHASE =>
            cur <= def(mode_l, idx);
            n   <= (others => '0');
            lf  <= SEED;
            limit <= shift_left(to_unsigned(1, 32), def(mode_l, idx).cnt_log2) - 1;
            if def(mode_l, idx).kind = K_END then
              busy_i <= '0';
              done_i <= '1';
              st     <= ST_IDLE;
            else
              st <= ST_ISSUE;
            end if;

          when ST_ISSUE =>
            if cur.rnd then
              a := lf(23 downto 0);
            else
              a := n(23 downto 0);
            end if;
            addr_r  <= a;
            o_c_addr  <= std_logic_vector(a);
            if cur.kind = K_WRITE then
              o_c_we <= '1';
            else
              o_c_we <= '0';
            end if;
            o_c_be    <= cur.be;
            o_c_wdata <= expected(cur.pat, a);
            exp_r   <= expected(cur.pat, a);
            wait_cnt <= 0;
            st      <= ST_TOG;

          when ST_TOG =>
            req_i <= not req_i;
            st    <= ST_WAIT;

          when ST_WAIT =>
            if i_c_ack_tog = req_i then
              ops <= ops + 1;
              if cur.kind = K_READ and i_c_rdata /= exp_r then
                if errs = 0 then
                  f_addr <= std_logic_vector(addr_r);
                  f_exp  <= exp_r;
                  f_got  <= i_c_rdata;
                end if;
                errs   <= errs + 1;
                fail_i <= '1';
              end if;
              -- next word of the phase
              last := n = limit;
              if last then
                idx <= idx + 1;
                st  <= ST_PHASE;
              else
                n <= n + 1;
                next_lf := lf xor shift_left(lf, 13);
                next_lf := next_lf xor shift_right(next_lf, 17);
                next_lf := next_lf xor shift_left(next_lf, 5);
                lf <= next_lf;
                st <= ST_ISSUE;
              end if;
            elsif wait_cnt = TIMEOUT_CYCLES then
              timeout_i <= '1';
              fail_i    <= '1';
              busy_i    <= '0';
              done_i    <= '1';
              st        <= ST_IDLE;
            else
              wait_cnt <= wait_cnt + 1;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
