library ieee;
use ieee.std_logic_1164.all;

-- Three masters, one controller: the core's data bridge (A), the debug master (B) and the core's
-- instruction bridge (I) share the request interface of sdram_ctrl. A request is a flip of
-- req_tog with the word on we/addr/wdata/be, answered by a flip of ack_tog (see sdram_ctrl); this
-- block takes one pending request at a time and, when several masters are waiting, serves them in
-- turn: the master served last goes to the end of the order A, I, B, so a master never waits for
-- more than one access of each of the others.
--
-- Masters A and I may ask for a line (four words, see sdram_ctrl) with a_line/i_line and the extra
-- words on *_wdata_x/*_be_x/*_rdata_x; master B moves one word at a time.
--
-- Masters A and I come from another clock (the core's), so their toggles are synchronized here, and
-- their buses hold from the flip until the answer. Master B is on this clock. Master I is optional:
-- left unconnected it never asks.
entity sdram_arbiter is
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;  -- synchronous, active high

    a_req_tog : in  std_logic;
    a_ack_tog : out std_logic;
    a_we      : in  std_logic;
    a_addr    : in  std_logic_vector(23 downto 0);
    a_wdata   : in  std_logic_vector(31 downto 0);
    a_be      : in  std_logic_vector(3 downto 0);
    a_rdata   : out std_logic_vector(31 downto 0);
    a_line    : in  std_logic := '0';
    a_wdata_x : in  std_logic_vector(95 downto 0) := (others => '0');
    a_be_x    : in  std_logic_vector(11 downto 0) := (others => '0');
    a_rdata_x : out std_logic_vector(95 downto 0);

    i_req_tog : in  std_logic := '0';
    i_ack_tog : out std_logic;
    i_we      : in  std_logic := '0';
    i_addr    : in  std_logic_vector(23 downto 0) := (others => '0');
    i_wdata   : in  std_logic_vector(31 downto 0) := (others => '0');
    i_be      : in  std_logic_vector(3 downto 0) := (others => '0');
    i_rdata   : out std_logic_vector(31 downto 0);
    i_line    : in  std_logic := '0';
    i_wdata_x : in  std_logic_vector(95 downto 0) := (others => '0');
    i_be_x    : in  std_logic_vector(11 downto 0) := (others => '0');
    i_rdata_x : out std_logic_vector(95 downto 0);

    b_req_tog : in  std_logic;
    b_ack_tog : out std_logic;
    b_we      : in  std_logic;
    b_addr    : in  std_logic_vector(23 downto 0);
    b_wdata   : in  std_logic_vector(31 downto 0);
    b_be      : in  std_logic_vector(3 downto 0);
    b_rdata   : out std_logic_vector(31 downto 0);

    c_req_tog : out std_logic;
    c_ack_tog : in  std_logic;
    c_we      : out std_logic;
    c_addr    : out std_logic_vector(23 downto 0);
    c_wdata   : out std_logic_vector(31 downto 0);
    c_be      : out std_logic_vector(3 downto 0);
    c_rdata   : in  std_logic_vector(31 downto 0);
    c_line    : out std_logic;
    c_wdata_x : out std_logic_vector(95 downto 0);
    c_be_x    : out std_logic_vector(11 downto 0);
    c_rdata_x : in  std_logic_vector(95 downto 0)
  );
end entity sdram_arbiter;

architecture rtl of sdram_arbiter is

  type state_t is (ST_IDLE, ST_BUSY);
  signal st        : state_t := ST_IDLE;
  signal a_s       : std_logic_vector(1 downto 0) := "00";
  signal i_s       : std_logic_vector(1 downto 0) := "00";
  signal a_ack_i   : std_logic := '0';
  signal b_ack_i   : std_logic := '0';
  signal i_ack_i   : std_logic := '0';
  signal c_req_i   : std_logic := '0';
  signal grant_b   : std_logic := '0';   -- the master being served is B
  signal grant_i   : std_logic := '0';   -- ... or I (both low: A)
  signal last_b    : std_logic := '0';   -- the master served last is B
  signal last_i    : std_logic := '0';   -- ... or I (both low: A)
  signal a_tog_l   : std_logic := '0';
  signal i_tog_l   : std_logic := '0';
  signal a_pend    : std_logic;
  signal b_pend    : std_logic;
  signal i_pend    : std_logic;
  signal i_rdata_i : std_logic_vector(31 downto 0) := (others => '0');
  signal i_rdx_i   : std_logic_vector(95 downto 0) := (others => '0');
  signal a_rdata_i : std_logic_vector(31 downto 0) := (others => '0');
  signal b_rdata_i : std_logic_vector(31 downto 0) := (others => '0');
  signal a_rdx_i   : std_logic_vector(95 downto 0) := (others => '0');

begin

  a_ack_tog <= a_ack_i;
  b_ack_tog <= b_ack_i;
  a_rdata   <= a_rdata_i;
  a_rdata_x <= a_rdx_i;
  b_rdata   <= b_rdata_i;
  i_ack_tog <= i_ack_i;
  i_rdata   <= i_rdata_i;
  i_rdata_x <= i_rdx_i;
  c_req_tog <= c_req_i;

  a_pend <= '1' when a_s(1) /= a_ack_i else '0';
  b_pend <= '1' when b_req_tog /= b_ack_i else '0';
  i_pend <= '1' when i_s(1) /= i_ack_i else '0';

  process (clk)
    variable pick : integer range 0 to 3;
  begin
    if rising_edge(clk) then
      a_s <= a_s(0) & a_req_tog;
      i_s <= i_s(0) & i_req_tog;

      if rst = '1' then
        st      <= ST_IDLE;
        a_s     <= "00";
        i_s     <= "00";
        a_ack_i <= '0';
        b_ack_i <= '0';
        i_ack_i <= '0';
        c_req_i <= '0';
        last_b  <= '0';
        last_i  <= '0';
      else
        case st is

          when ST_IDLE =>
            -- who is next: the order after the master served last
            --   last A: I, B, A    last I: B, A, I    last B: A, I, B
            pick := 3;
            if last_b = '1' then
              if a_pend = '1' then pick := 0; elsif i_pend = '1' then pick := 2; elsif b_pend = '1' then pick := 1; end if;
            elsif last_i = '1' then
              if b_pend = '1' then pick := 1; elsif a_pend = '1' then pick := 0; elsif i_pend = '1' then pick := 2; end if;
            else
              if i_pend = '1' then pick := 2; elsif b_pend = '1' then pick := 1; elsif a_pend = '1' then pick := 0; end if;
            end if;
            if pick = 0 then
              c_we      <= a_we;
              c_addr    <= a_addr;
              c_wdata   <= a_wdata;
              c_be      <= a_be;
              c_line    <= a_line;
              c_wdata_x <= a_wdata_x;
              c_be_x    <= a_be_x;
              a_tog_l   <= a_s(1);
              grant_b   <= '0';
              grant_i   <= '0';
              c_req_i   <= not c_req_i;
              st        <= ST_BUSY;
            elsif pick = 2 then
              c_we      <= i_we;
              c_addr    <= i_addr;
              c_wdata   <= i_wdata;
              c_be      <= i_be;
              c_line    <= i_line;
              c_wdata_x <= i_wdata_x;
              c_be_x    <= i_be_x;
              i_tog_l   <= i_s(1);
              grant_b   <= '0';
              grant_i   <= '1';
              c_req_i   <= not c_req_i;
              st        <= ST_BUSY;
            elsif pick = 1 then
              c_we      <= b_we;
              c_addr    <= b_addr;
              c_wdata   <= b_wdata;
              c_be      <= b_be;
              c_line    <= '0';
              c_wdata_x <= (others => '0');
              c_be_x    <= (others => '0');
              grant_b   <= '1';
              grant_i   <= '0';
              c_req_i   <= not c_req_i;
              st        <= ST_BUSY;
            end if;

          when ST_BUSY =>
            if c_ack_tog = c_req_i then
              if grant_b = '1' then
                b_rdata_i <= c_rdata;
                b_ack_i   <= b_req_tog;
              elsif grant_i = '1' then
                i_rdata_i <= c_rdata;
                i_rdx_i   <= c_rdata_x;
                i_ack_i   <= i_tog_l;
              else
                a_rdata_i <= c_rdata;
                a_rdx_i   <= c_rdata_x;
                a_ack_i   <= a_tog_l;
              end if;
              last_b <= grant_b;
              last_i <= grant_i;
              st     <= ST_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
