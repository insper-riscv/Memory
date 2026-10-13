library ieee;
use ieee.std_logic_1164.all;

-- Bridge between the core's external data port and an AXI4-Lite slave port (the core is the master).
--
-- Core side, the same contract as sdram_cpu_bridge: the access sits on addr/wdata/byteena/rden/wren
-- while the memory stage is stopped; ready goes high when the access is done and stays high, as a
-- level, until mem_advance says the pipeline moved; rdata only changes on that same edge, because
-- the load still in the write-back stage reads the previous value until then. err is high with
-- ready when the slave answered SLVERR or DECERR (the core has no way to use it yet).
--
-- AXI side, one access at a time (no outstanding transactions, so no IDs and no ordering rules):
--
--   write  AW and W are offered together and accepted in any order (each valid drops when its own
--          ready is seen); the access is done when B arrives. wstrb is byteena.
--   read   AR is offered until accepted; the access is done when R arrives. A read always asks for
--          the whole word; byteena is not used.
--
-- The address and the data are copied when the access starts and hold on the bus, so they stay
-- stable while a valid is up no matter what the core does. bready and rready are raised only after
-- the request has been accepted, so a response that comes before that is not taken.
entity axil_master_bridge is
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
    err         : out std_logic;

    -- AXI4-Lite master port
    m_awvalid   : out std_logic;
    m_awready   : in  std_logic;
    m_awaddr    : out std_logic_vector(31 downto 0);
    m_awprot    : out std_logic_vector(2 downto 0);
    m_wvalid    : out std_logic;
    m_wready    : in  std_logic;
    m_wdata     : out std_logic_vector(31 downto 0);
    m_wstrb     : out std_logic_vector(3 downto 0);
    m_bvalid    : in  std_logic;
    m_bready    : out std_logic;
    m_bresp     : in  std_logic_vector(1 downto 0);
    m_arvalid   : out std_logic;
    m_arready   : in  std_logic;
    m_araddr    : out std_logic_vector(31 downto 0);
    m_arprot    : out std_logic_vector(2 downto 0);
    m_rvalid    : in  std_logic;
    m_rready    : out std_logic;
    m_rdata     : in  std_logic_vector(31 downto 0);
    m_rresp     : in  std_logic_vector(1 downto 0)
  );
end entity axil_master_bridge;

architecture rtl of axil_master_bridge is

  type state_t is (ST_IDLE, ST_WR, ST_RD, ST_DONE);
  signal st      : state_t := ST_IDLE;

  signal awv     : std_logic := '0';
  signal wv      : std_logic := '0';
  signal arv     : std_logic := '0';
  signal addr_l  : std_logic_vector(31 downto 0) := (others => '0');
  signal wdata_l : std_logic_vector(31 downto 0) := (others => '0');
  signal strb_l  : std_logic_vector(3 downto 0) := (others => '0');
  signal we_l    : std_logic := '0';
  signal err_l   : std_logic := '0';
  signal pending : std_logic_vector(31 downto 0) := (others => '0');
  signal rdata_q : std_logic_vector(31 downto 0) := (others => '0');

begin

  m_awvalid <= awv;
  m_awaddr  <= addr_l;
  m_awprot  <= "000";   -- unprivileged, secure, data
  m_wvalid  <= wv;
  m_wdata   <= wdata_l;
  m_wstrb   <= strb_l;
  m_arvalid <= arv;
  m_araddr  <= addr_l;
  m_arprot  <= "000";

  -- a response is taken only once the request it answers was accepted
  m_bready  <= '1' when st = ST_WR and awv = '0' and wv = '0' else '0';
  m_rready  <= '1' when st = ST_RD and arv = '0' else '0';

  ready     <= '1' when st = ST_DONE else '0';
  rdata     <= rdata_q;
  err       <= err_l when st = ST_DONE else '0';

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st    <= ST_IDLE;
        awv   <= '0';
        wv    <= '0';
        arv   <= '0';
        we_l  <= '0';
        err_l <= '0';
      else
        case st is

          when ST_IDLE =>
            if (rden = '1' or wren = '1') then
              addr_l  <= addr;
              wdata_l <= wdata;
              strb_l  <= byteena;
              we_l    <= wren;
              if wren = '1' then
                awv <= '1';
                wv  <= '1';
                st  <= ST_WR;
              else
                arv <= '1';
                st  <= ST_RD;
              end if;
            end if;

          when ST_WR =>
            if awv = '1' and m_awready = '1' then
              awv <= '0';
            end if;
            if wv = '1' and m_wready = '1' then
              wv <= '0';
            end if;
            if m_bvalid = '1' and awv = '0' and wv = '0' then
              err_l <= m_bresp(1);
              st    <= ST_DONE;
            end if;

          when ST_RD =>
            if arv = '1' and m_arready = '1' then
              arv <= '0';
            end if;
            if m_rvalid = '1' and arv = '0' then
              pending <= m_rdata;
              err_l   <= m_rresp(1);
              st      <= ST_DONE;
            end if;

          when ST_DONE =>
            if mem_advance = '1' then
              if we_l = '0' then
                rdata_q <= pending;
              end if;
              st <= ST_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
