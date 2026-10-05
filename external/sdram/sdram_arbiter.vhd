library ieee;
use ieee.std_logic_1164.all;

-- Two masters, one controller: the core's bridge and the debug master share the request
-- interface of sdram_ctrl. A request is a flip of req_tog with the word on we/addr/wdata/be,
-- answered by a flip of ack_tog (see sdram_ctrl); this block takes one pending request at a
-- time and, when both masters are waiting, alternates, so the core never waits for more than
-- one debug access.
--
-- Master A comes from another clock (the core's), so its toggle is synchronized here, and its
-- buses hold from the flip until the answer. Master B is on this clock.
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
    c_rdata   : in  std_logic_vector(31 downto 0)
  );
end entity sdram_arbiter;

architecture rtl of sdram_arbiter is

  type state_t is (ST_IDLE, ST_BUSY);
  signal st        : state_t := ST_IDLE;
  signal a_s       : std_logic_vector(1 downto 0) := "00";
  signal a_ack_i   : std_logic := '0';
  signal b_ack_i   : std_logic := '0';
  signal c_req_i   : std_logic := '0';
  signal grant_b   : std_logic := '0';   -- the master being served
  signal last_b    : std_logic := '0';   -- the master served last
  signal a_tog_l   : std_logic := '0';
  signal a_pend    : std_logic;
  signal b_pend    : std_logic;
  signal a_rdata_i : std_logic_vector(31 downto 0) := (others => '0');
  signal b_rdata_i : std_logic_vector(31 downto 0) := (others => '0');

begin

  a_ack_tog <= a_ack_i;
  b_ack_tog <= b_ack_i;
  a_rdata   <= a_rdata_i;
  b_rdata   <= b_rdata_i;
  c_req_tog <= c_req_i;

  a_pend <= '1' when a_s(1) /= a_ack_i else '0';
  b_pend <= '1' when b_req_tog /= b_ack_i else '0';

  process (clk)
  begin
    if rising_edge(clk) then
      a_s <= a_s(0) & a_req_tog;

      if rst = '1' then
        st      <= ST_IDLE;
        a_s     <= "00";
        a_ack_i <= '0';
        b_ack_i <= '0';
        c_req_i <= '0';
        last_b  <= '0';
      else
        case st is

          when ST_IDLE =>
            if a_pend = '1' and (b_pend = '0' or last_b = '1') then
              c_we    <= a_we;
              c_addr  <= a_addr;
              c_wdata <= a_wdata;
              c_be    <= a_be;
              a_tog_l <= a_s(1);
              grant_b <= '0';
              c_req_i <= not c_req_i;
              st      <= ST_BUSY;
            elsif b_pend = '1' then
              c_we    <= b_we;
              c_addr  <= b_addr;
              c_wdata <= b_wdata;
              c_be    <= b_be;
              grant_b <= '1';
              c_req_i <= not c_req_i;
              st      <= ST_BUSY;
            end if;

          when ST_BUSY =>
            if c_ack_tog = c_req_i then
              if grant_b = '1' then
                b_rdata_i <= c_rdata;
                b_ack_i   <= b_req_tog;
              else
                a_rdata_i <= c_rdata;
                a_ack_i   <= a_tog_l;
              end if;
              last_b <= grant_b;
              st     <= ST_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
