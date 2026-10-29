library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- An AXI4 slave in front of the peripheral window of ext_interconnect: eight peripherals, each with
-- a window of 256 words, selected by bits 30:28 of the address, the word inside it by bits 9:2.
-- The peripheral side is the one ext_interconnect gives: p_we or p_re of the selected peripheral is
-- one pulse of one clock per access, with p_addr, p_wdata and p_byteena beside it, and the
-- peripheral's read data (p_rdata, 32 bits per slot, slot i in bits 32 i + 31 downto 32 i) is read
-- in the clock of that pulse. A read of a window nobody answers gives 0 and a write has no effect;
-- both complete like any other, with OKAY.
--
-- Peripherals are not memory: only a single beat of 4 bytes (len 0, size 4 bytes, INCR, aligned) is
-- served. Any other transaction is answered with SLVERR after all its beats are consumed (a write)
-- or given as zeros (a read), and no peripheral is touched. IDs are not carried (width 0).
--
-- As axi_slave_word_bridge: AW first and then the beats of W, a read yields to a write that is
-- offered, one transaction at a time, the response waits for bready/rready.
entity axi_slave_periph_bank is
  port (
    i_clk         : in  std_logic;
    i_rst         : in  std_logic;  -- synchronous, active high

    -- AXI4 slave port
    i_s_awvalid   : in  std_logic;
    o_s_awready   : out std_logic;
    i_s_awaddr    : in  std_logic_vector(31 downto 0);
    i_s_awlen     : in  std_logic_vector(7 downto 0);
    i_s_awsize    : in  std_logic_vector(2 downto 0);
    i_s_awburst   : in  std_logic_vector(1 downto 0);
    i_s_wvalid    : in  std_logic;
    o_s_wready    : out std_logic;
    i_s_wdata     : in  std_logic_vector(31 downto 0);
    i_s_wstrb     : in  std_logic_vector(3 downto 0);
    i_s_wlast     : in  std_logic;
    o_s_bvalid    : out std_logic;
    i_s_bready    : in  std_logic;
    o_s_bresp     : out std_logic_vector(1 downto 0);
    i_s_arvalid   : in  std_logic;
    o_s_arready   : out std_logic;
    i_s_araddr    : in  std_logic_vector(31 downto 0);
    i_s_arlen     : in  std_logic_vector(7 downto 0);
    i_s_arsize    : in  std_logic_vector(2 downto 0);
    i_s_arburst   : in  std_logic_vector(1 downto 0);
    o_s_rvalid    : out std_logic;
    i_s_rready    : in  std_logic;
    o_s_rdata     : out std_logic_vector(31 downto 0);
    o_s_rresp     : out std_logic_vector(1 downto 0);
    o_s_rlast     : out std_logic;

    -- the peripherals
    o_p_addr      : out std_logic_vector(7 downto 0);
    o_p_wdata     : out std_logic_vector(31 downto 0);
    o_p_byteena   : out std_logic_vector(3 downto 0);
    o_p_we        : out std_logic_vector(7 downto 0);
    o_p_re        : out std_logic_vector(7 downto 0);
    i_p_rdata     : in  std_logic_vector(8 * 32 - 1 downto 0)
  );
end entity axi_slave_periph_bank;

architecture rtl of axi_slave_periph_bank is

  -- ST_IDLE   waiting for AW or AR
  -- ST_WBEAT  taking W (the one beat of a served write, or all the beats of a refused one)
  -- ST_PULSE  one clock of p_we or p_re
  -- ST_RESP   B or the single beat of R
  -- ST_RDROP  the beats of a refused read
  type state_t is (ST_IDLE, ST_WBEAT, ST_PULSE, ST_RESP, ST_RDROP);
  signal st      : state_t := ST_IDLE;

  signal we_l    : std_logic := '0';
  signal bad_l   : std_logic := '0';
  signal addr_l  : std_logic_vector(31 downto 0) := (others => '0');
  signal wdata_l : std_logic_vector(31 downto 0) := (others => '0');
  signal strb_l  : std_logic_vector(3 downto 0) := (others => '0');
  signal rd_q    : std_logic_vector(31 downto 0) := (others => '0');
  signal left_l  : unsigned(7 downto 0) := (others => '0');

  signal id : integer range 0 to 7;

  function is_bad (a : std_logic_vector(31 downto 0); len : std_logic_vector(7 downto 0);
                   size : std_logic_vector(2 downto 0); burst : std_logic_vector(1 downto 0)) return std_logic is
  begin
    if len /= "00000000" or size /= "010" or burst /= "01" or a(1 downto 0) /= "00" then
      return '1';
    end if;
    return '0';
  end function;

begin

  o_s_awready <= '1' when st = ST_IDLE else '0';
  o_s_arready <= '1' when st = ST_IDLE and i_s_awvalid = '0' else '0';
  o_s_wready  <= '1' when st = ST_WBEAT else '0';

  id        <= to_integer(unsigned(addr_l(30 downto 28)));
  o_p_addr    <= addr_l(9 downto 2);
  o_p_wdata   <= wdata_l;
  o_p_byteena <= strb_l;

  process (st, id, we_l)
  begin
    o_p_we <= (others => '0');
    o_p_re <= (others => '0');
    if st = ST_PULSE then
      o_p_we(id) <= we_l;
      o_p_re(id) <= not we_l;
    end if;
  end process;

  o_s_bvalid <= '1' when st = ST_RESP and we_l = '1' else '0';
  o_s_bresp  <= "10" when bad_l = '1' else "00";
  o_s_rvalid <= '1' when (st = ST_RESP and we_l = '0') or st = ST_RDROP else '0';
  o_s_rresp  <= "10" when bad_l = '1' else "00";
  o_s_rdata  <= rd_q when bad_l = '0' else x"00000000";
  o_s_rlast  <= '1' when (st = ST_RESP and we_l = '0') or (st = ST_RDROP and left_l = 0) else '0';

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        st    <= ST_IDLE;
        we_l  <= '0';
        bad_l <= '0';
        rd_q  <= (others => '0');
      else
        case st is

          when ST_IDLE =>
            if i_s_awvalid = '1' then
              addr_l <= i_s_awaddr;
              we_l   <= '1';
              bad_l  <= is_bad(i_s_awaddr, i_s_awlen, i_s_awsize, i_s_awburst);
              st     <= ST_WBEAT;
            elsif i_s_arvalid = '1' then
              addr_l <= i_s_araddr;
              we_l   <= '0';
              left_l <= unsigned(i_s_arlen);
              bad_l  <= is_bad(i_s_araddr, i_s_arlen, i_s_arsize, i_s_arburst);
              if is_bad(i_s_araddr, i_s_arlen, i_s_arsize, i_s_arburst) = '1' then
                st <= ST_RDROP;
              else
                strb_l <= "1111";
                st     <= ST_PULSE;
              end if;
            end if;

          when ST_WBEAT =>
            if i_s_wvalid = '1' then
              if bad_l = '1' then
                if i_s_wlast = '1' then
                  st <= ST_RESP;
                end if;
              else
                wdata_l <= i_s_wdata;
                strb_l  <= i_s_wstrb;
                st      <= ST_PULSE;
              end if;
            end if;

          when ST_PULSE =>
            rd_q <= i_p_rdata(32 * id + 31 downto 32 * id);
            st   <= ST_RESP;

          when ST_RESP =>
            if (we_l = '1' and i_s_bready = '1') or (we_l = '0' and i_s_rready = '1') then
              st <= ST_IDLE;
            end if;

          when ST_RDROP =>
            if i_s_rready = '1' then
              if left_l = 0 then
                st <= ST_IDLE;
              else
                left_l <= left_l - 1;
              end if;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
