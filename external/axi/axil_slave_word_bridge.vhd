library ieee;
use ieee.std_logic_1164.all;

-- An AXI4-Lite slave in front of a memory with the core's word contract (sdram_cpu_bridge, or any
-- memory that follows the same ready/mem_advance rules): it turns the five channels into one access
-- at a time on addr/wdata/byteena/rden/wren, and the answer into B or R.
--
-- AW and W are accepted in any order, each once; a read is accepted only when no write is half
-- accepted, and a write that is offered at the same time goes first. The access is held on the
-- word port until ready; mem_advance is one pulse then, because nothing else is stopped. The
-- response (always OKAY: the memory has no error to report) waits for bready/rready, and no
-- request is accepted before it is taken, so there is never more than one transaction.
entity axil_slave_word_bridge is
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

    -- the memory's word port
    addr        : out std_logic_vector(31 downto 0);
    wdata       : out std_logic_vector(31 downto 0);
    byteena     : out std_logic_vector(3 downto 0);
    rden        : out std_logic;
    wren        : out std_logic;
    mem_advance : out std_logic;
    ready       : in  std_logic;
    rdata       : in  std_logic_vector(31 downto 0)
  );
end entity axil_slave_word_bridge;

architecture rtl of axil_slave_word_bridge is

  type state_t is (ST_IDLE, ST_ACC, ST_ADV, ST_RESP);
  signal st      : state_t := ST_IDLE;

  signal aw_got  : std_logic := '0';
  signal w_got   : std_logic := '0';
  signal we_l    : std_logic := '0';
  signal addr_l  : std_logic_vector(31 downto 0) := (others => '0');
  signal wdata_l : std_logic_vector(31 downto 0) := (others => '0');
  signal strb_l  : std_logic_vector(3 downto 0) := (others => '0');

  signal awr, wr, arr : std_logic;

begin

  -- requests are taken only while idle; a read waits while a write is offered or half accepted
  awr <= '1' when st = ST_IDLE and aw_got = '0' else '0';
  wr  <= '1' when st = ST_IDLE and w_got = '0' else '0';
  arr <= '1' when st = ST_IDLE and aw_got = '0' and w_got = '0'
                  and s_awvalid = '0' and s_wvalid = '0' else '0';
  s_awready <= awr;
  s_wready  <= wr;
  s_arready <= arr;

  addr        <= addr_l;
  wdata       <= wdata_l;
  byteena     <= strb_l;
  rden        <= '1' when (st = ST_ACC or st = ST_ADV) and we_l = '0' else '0';
  wren        <= '1' when (st = ST_ACC or st = ST_ADV) and we_l = '1' else '0';
  mem_advance <= '1' when st = ST_ADV else '0';

  s_bvalid <= '1' when st = ST_RESP and we_l = '1' else '0';
  s_bresp  <= "00";
  s_rvalid <= '1' when st = ST_RESP and we_l = '0' else '0';
  s_rresp  <= "00";
  s_rdata  <= rdata;

  process (clk)
    variable aw_now, w_now : std_logic;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st     <= ST_IDLE;
        aw_got <= '0';
        w_got  <= '0';
        we_l   <= '0';
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
              st   <= ST_ACC;
            elsif s_arvalid = '1' and arr = '1' then
              addr_l <= s_araddr;
              strb_l <= "1111";
              we_l   <= '0';
              st     <= ST_ACC;
            end if;

          when ST_ACC =>
            if ready = '1' then
              st <= ST_ADV;
            end if;

          when ST_ADV =>
            st <= ST_RESP;

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
