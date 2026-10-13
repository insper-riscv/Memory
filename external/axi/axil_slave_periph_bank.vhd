library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- An AXI4-Lite slave in front of the peripheral window of ext_interconnect: eight peripherals, each
-- with a window of 256 words, selected by bits 30:28 of the address, the word inside it by bits 9:2.
-- The peripheral side is the one ext_interconnect gives: p_we or p_re of the selected peripheral is
-- one pulse of one clock per access, with p_addr, p_wdata and p_byteena beside it, and the
-- peripheral's read data (p_rdata, 32 bits per slot, slot i in bits 32 i + 31 downto 32 i) is read
-- in the clock of that pulse. A read of a window nobody answers gives 0 and a write has no effect;
-- both complete like any other, with OKAY.
--
-- As axil_slave_word_bridge: AW and W in any order, a read yields to a write that is offered or half
-- accepted, one transaction at a time, the response waits for bready/rready.
entity axil_slave_periph_bank is
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;  -- synchronous, active high

    -- AXI4-Lite slave port
    s_awvalid   : in  std_logic;
    s_awready   : out std_logic;
    s_awaddr    : in  std_logic_vector(31 downto 0);
    s_wvalid    : in  std_logic;
    s_wready    : out std_logic;
    s_wdata     : in  std_logic_vector(31 downto 0);
    s_wstrb     : in  std_logic_vector(3 downto 0);
    s_bvalid    : out std_logic;
    s_bready    : in  std_logic;
    s_bresp     : out std_logic_vector(1 downto 0);
    s_arvalid   : in  std_logic;
    s_arready   : out std_logic;
    s_araddr    : in  std_logic_vector(31 downto 0);
    s_rvalid    : out std_logic;
    s_rready    : in  std_logic;
    s_rdata     : out std_logic_vector(31 downto 0);
    s_rresp     : out std_logic_vector(1 downto 0);

    -- the peripherals
    p_addr      : out std_logic_vector(7 downto 0);
    p_wdata     : out std_logic_vector(31 downto 0);
    p_byteena   : out std_logic_vector(3 downto 0);
    p_we        : out std_logic_vector(7 downto 0);
    p_re        : out std_logic_vector(7 downto 0);
    p_rdata     : in  std_logic_vector(8 * 32 - 1 downto 0)
  );
end entity axil_slave_periph_bank;

architecture rtl of axil_slave_periph_bank is

  type state_t is (ST_IDLE, ST_PULSE, ST_RESP);
  signal st      : state_t := ST_IDLE;

  signal aw_got  : std_logic := '0';
  signal w_got   : std_logic := '0';
  signal we_l    : std_logic := '0';
  signal addr_l  : std_logic_vector(31 downto 0) := (others => '0');
  signal wdata_l : std_logic_vector(31 downto 0) := (others => '0');
  signal strb_l  : std_logic_vector(3 downto 0) := (others => '0');
  signal rd_q    : std_logic_vector(31 downto 0) := (others => '0');

  signal awr, wr, arr : std_logic;
  signal id : integer range 0 to 7;

begin

  awr <= '1' when st = ST_IDLE and aw_got = '0' else '0';
  wr  <= '1' when st = ST_IDLE and w_got = '0' else '0';
  arr <= '1' when st = ST_IDLE and aw_got = '0' and w_got = '0'
                  and s_awvalid = '0' and s_wvalid = '0' else '0';
  s_awready <= awr;
  s_wready  <= wr;
  s_arready <= arr;

  id        <= to_integer(unsigned(addr_l(30 downto 28)));
  p_addr    <= addr_l(9 downto 2);
  p_wdata   <= wdata_l;
  p_byteena <= strb_l;

  process (st, id, we_l)
  begin
    p_we <= (others => '0');
    p_re <= (others => '0');
    if st = ST_PULSE then
      p_we(id) <= we_l;
      p_re(id) <= not we_l;
    end if;
  end process;

  s_bvalid <= '1' when st = ST_RESP and we_l = '1' else '0';
  s_bresp  <= "00";
  s_rvalid <= '1' when st = ST_RESP and we_l = '0' else '0';
  s_rresp  <= "00";
  s_rdata  <= rd_q;

  process (clk)
    variable aw_now, w_now : std_logic;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st     <= ST_IDLE;
        aw_got <= '0';
        w_got  <= '0';
        we_l   <= '0';
        rd_q   <= (others => '0');
      else
        case st is

          when ST_IDLE =>
            aw_now := aw_got;
            w_now  := w_got;
            if s_awvalid = '1' and awr = '1' then
              aw_got <= '1';
              aw_now := '1';
              addr_l <= s_awaddr;
            end if;
            if s_wvalid = '1' and wr = '1' then
              w_got   <= '1';
              w_now   := '1';
              wdata_l <= s_wdata;
              strb_l  <= s_wstrb;
            end if;
            if aw_now = '1' and w_now = '1' then
              we_l <= '1';
              st   <= ST_PULSE;
            elsif s_arvalid = '1' and arr = '1' then
              addr_l <= s_araddr;
              strb_l <= "1111";
              we_l   <= '0';
              st     <= ST_PULSE;
            end if;

          when ST_PULSE =>
            rd_q <= p_rdata(32 * id + 31 downto 32 * id);
            st   <= ST_RESP;

          when ST_RESP =>
            if (we_l = '1' and s_bready = '1') or (we_l = '0' and s_rready = '1') then
              aw_got <= '0';
              w_got  <= '0';
              st     <= ST_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
