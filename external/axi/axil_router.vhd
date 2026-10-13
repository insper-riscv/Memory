library ieee;
use ieee.std_logic_1164.all;

-- One AXI4-Lite master to two slaves, by address, with no clock of delay: the channels of the
-- master go to the selected slave and the answers come back by the same choice.
--
--   0x40000000 to 0x43FFFFFF   slave 0 (the SDRAM)
--   0x80000000 to 0xFFFFFFFF   slave 1 (the peripheral window)
--   anything else              no slave: the request is accepted and answered with DECERR (reads give 0)
--
-- AW decides where a write goes. A W that comes before its AW waits (an interconnect may do that),
-- and one that comes with it follows the same decision. B and R come back from the slave that took
-- the request. Each direction has one transaction in flight; a master that sends a second request
-- before the answer to the first waits.
entity axil_router is
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;

    -- the master (this is a slave port)
    s_awvalid : in  std_logic; s_awready : out std_logic; s_awaddr : in std_logic_vector(31 downto 0);
    s_wvalid  : in  std_logic; s_wready  : out std_logic; s_wdata  : in std_logic_vector(31 downto 0);
    s_wstrb   : in  std_logic_vector(3 downto 0);
    s_bvalid  : out std_logic; s_bready  : in  std_logic; s_bresp  : out std_logic_vector(1 downto 0);
    s_arvalid : in  std_logic; s_arready : out std_logic; s_araddr : in std_logic_vector(31 downto 0);
    s_rvalid  : out std_logic; s_rready  : in  std_logic;
    s_rdata   : out std_logic_vector(31 downto 0); s_rresp : out std_logic_vector(1 downto 0);

    -- slave 0
    m0_awvalid : out std_logic; m0_awready : in std_logic; m0_awaddr : out std_logic_vector(31 downto 0);
    m0_wvalid  : out std_logic; m0_wready  : in std_logic; m0_wdata  : out std_logic_vector(31 downto 0);
    m0_wstrb   : out std_logic_vector(3 downto 0);
    m0_bvalid  : in  std_logic; m0_bready  : out std_logic; m0_bresp : in std_logic_vector(1 downto 0);
    m0_arvalid : out std_logic; m0_arready : in std_logic; m0_araddr : out std_logic_vector(31 downto 0);
    m0_rvalid  : in  std_logic; m0_rready  : out std_logic;
    m0_rdata   : in  std_logic_vector(31 downto 0); m0_rresp : in std_logic_vector(1 downto 0);

    -- slave 1
    m1_awvalid : out std_logic; m1_awready : in std_logic; m1_awaddr : out std_logic_vector(31 downto 0);
    m1_wvalid  : out std_logic; m1_wready  : in std_logic; m1_wdata  : out std_logic_vector(31 downto 0);
    m1_wstrb   : out std_logic_vector(3 downto 0);
    m1_bvalid  : in  std_logic; m1_bready  : out std_logic; m1_bresp : in std_logic_vector(1 downto 0);
    m1_arvalid : out std_logic; m1_arready : in std_logic; m1_araddr : out std_logic_vector(31 downto 0);
    m1_rvalid  : in  std_logic; m1_rready  : out std_logic;
    m1_rdata   : in  std_logic_vector(31 downto 0); m1_rresp : in std_logic_vector(1 downto 0)
  );
end entity axil_router;

architecture rtl of axil_router is

  subtype sel_t is std_logic_vector(1 downto 0);   -- 00 slave 0, 01 slave 1, 10 no slave
  constant SEL_0 : sel_t := "00";
  constant SEL_1 : sel_t := "01";
  constant SEL_E : sel_t := "10";

  function decode (a : std_logic_vector(31 downto 0)) return sel_t is
  begin
    if a(31 downto 26) = "010000" then
      return SEL_0;
    elsif a(31) = '1' then
      return SEL_1;
    else
      return SEL_E;
    end if;
  end function;

  signal wr_act, w_done, rd_act : std_logic := '0';
  signal wr_sel, rd_sel : sel_t := SEL_0;
  signal aw_dec, w_sel, ar_dec : sel_t;
  signal w_en : std_logic;
  signal aw_rdy, w_rdy, ar_rdy : std_logic;
  signal aw_ok, w_ok, ar_ok : std_logic;     -- the handshakes of this clock

begin

  aw_dec <= decode(s_awaddr);
  ar_dec <= decode(s_araddr);

  -- write address: only while no write is in flight
  m0_awvalid <= s_awvalid when wr_act = '0' and aw_dec = SEL_0 else '0';
  m1_awvalid <= s_awvalid when wr_act = '0' and aw_dec = SEL_1 else '0';
  m0_awaddr  <= s_awaddr;
  m1_awaddr  <= s_awaddr;
  aw_rdy <= '0' when wr_act = '1' else
            m0_awready when aw_dec = SEL_0 else
            m1_awready when aw_dec = SEL_1 else '1';
  s_awready <= aw_rdy;
  aw_ok <= s_awvalid and aw_rdy;

  -- write data: follows the decision of AW, in the clock of the AW handshake or after it; once per write
  w_en  <= '1' when (wr_act = '1' and w_done = '0') or (wr_act = '0' and aw_ok = '1') else '0';
  w_sel <= wr_sel when wr_act = '1' else aw_dec;
  m0_wvalid <= s_wvalid when w_en = '1' and w_sel = SEL_0 else '0';
  m1_wvalid <= s_wvalid when w_en = '1' and w_sel = SEL_1 else '0';
  m0_wdata <= s_wdata; m1_wdata <= s_wdata;
  m0_wstrb <= s_wstrb; m1_wstrb <= s_wstrb;
  w_rdy <= '0' when w_en = '0' else
           m0_wready when w_sel = SEL_0 else
           m1_wready when w_sel = SEL_1 else '1';
  s_wready <= w_rdy;
  w_ok <= s_wvalid and w_rdy;

  -- write response
  m0_bready <= s_bready when wr_act = '1' and wr_sel = SEL_0 else '0';
  m1_bready <= s_bready when wr_act = '1' and wr_sel = SEL_1 else '0';
  s_bvalid  <= '0' when wr_act = '0' else
               m0_bvalid when wr_sel = SEL_0 else
               m1_bvalid when wr_sel = SEL_1 else w_done;
  s_bresp   <= m0_bresp when wr_sel = SEL_0 else m1_bresp when wr_sel = SEL_1 else "11";

  -- read address and response
  m0_arvalid <= s_arvalid when rd_act = '0' and ar_dec = SEL_0 else '0';
  m1_arvalid <= s_arvalid when rd_act = '0' and ar_dec = SEL_1 else '0';
  m0_araddr  <= s_araddr;
  m1_araddr  <= s_araddr;
  ar_rdy <= '0' when rd_act = '1' else
            m0_arready when ar_dec = SEL_0 else
            m1_arready when ar_dec = SEL_1 else '1';
  s_arready <= ar_rdy;
  ar_ok <= s_arvalid and ar_rdy;

  m0_rready <= s_rready when rd_act = '1' and rd_sel = SEL_0 else '0';
  m1_rready <= s_rready when rd_act = '1' and rd_sel = SEL_1 else '0';
  s_rvalid  <= '0' when rd_act = '0' else
               m0_rvalid when rd_sel = SEL_0 else
               m1_rvalid when rd_sel = SEL_1 else '1';
  s_rdata   <= m0_rdata when rd_sel = SEL_0 else m1_rdata when rd_sel = SEL_1 else (others => '0');
  s_rresp   <= m0_rresp when rd_sel = SEL_0 else m1_rresp when rd_sel = SEL_1 else "11";

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        wr_act <= '0';
        w_done <= '0';
        rd_act <= '0';
      else
        if wr_act = '0' then
          if aw_ok = '1' then
            wr_act <= '1';
            wr_sel <= aw_dec;
            w_done <= w_ok;
          end if;
        else
          if w_ok = '1' then
            w_done <= '1';
          end if;
          if s_bvalid = '1' and s_bready = '1' then
            wr_act <= '0';
            w_done <= '0';
          end if;
        end if;

        if rd_act = '0' then
          if ar_ok = '1' then
            rd_act <= '1';
            rd_sel <= ar_dec;
          end if;
        elsif s_rvalid = '1' and s_rready = '1' then
          rd_act <= '0';
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
