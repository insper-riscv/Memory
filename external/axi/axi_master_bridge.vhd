library ieee;
use ieee.std_logic_1164.all;

-- Bridge between the core's external data port and an AXI4 slave port (the core is the master).
--
-- Core side, the same contract as sdram_cpu_bridge: the access sits on addr/wdata/byteena/rden/wren
-- while the memory stage is stopped; ready goes high when the access is done and stays high, as a
-- level, until mem_advance says the pipeline moved; rdata/rdata_x only change on that same edge,
-- because the load still in the write-back stage reads the previous value until then. err is high
-- with ready when the slave answered SLVERR or DECERR (the core has no way to use it yet).
--
-- A line access (line = 1; addr aligned to 16 bytes) is one burst of four beats, INCR, 32 bits each:
-- word 0 on wdata/byteena/rdata and words 1 to 3 on wdata_x/byteena_x/rdata_x (word 1 in the lowest
-- bits), as for sdram_cpu_bridge. Without line it is one beat. Every transaction uses ID 0 (the
-- signals are left out), size 4 bytes, no lock, no cache attributes.
--
-- AXI side, one transaction at a time (no outstanding transactions, so no ordering rules):
--
--   write  AW is offered until accepted and the beats of W follow in order, each held until its
--          ready; the access is done when B arrives. wstrb is the byte enable of the beat.
--   read   AR is offered until accepted; the access is done when the last beat of R arrives. A read
--          always asks for whole words; byteena is not used.
--
-- The address and the data are copied when the access starts and hold on the bus, so they stay
-- stable while a valid is up no matter what the core does. bready and rready are raised only after
-- the request has been accepted, so a response that comes before that is not taken. A read whose
-- last beat does not carry rlast is reported in err.
entity axi_master_bridge is
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
    line        : in  std_logic := '0';
    wdata_x     : in  std_logic_vector(95 downto 0) := (others => '0');
    byteena_x   : in  std_logic_vector(11 downto 0) := (others => '0');
    rdata_x     : out std_logic_vector(95 downto 0);
    err         : out std_logic;

    -- AXI4 master port
    m_awvalid   : out std_logic;
    m_awready   : in  std_logic;
    m_awaddr    : out std_logic_vector(31 downto 0);
    m_awlen     : out std_logic_vector(7 downto 0);
    m_awsize    : out std_logic_vector(2 downto 0);
    m_awburst   : out std_logic_vector(1 downto 0);
    m_awprot    : out std_logic_vector(2 downto 0);
    m_wvalid    : out std_logic;
    m_wready    : in  std_logic;
    m_wdata     : out std_logic_vector(31 downto 0);
    m_wstrb     : out std_logic_vector(3 downto 0);
    m_wlast     : out std_logic;
    m_bvalid    : in  std_logic;
    m_bready    : out std_logic;
    m_bresp     : in  std_logic_vector(1 downto 0);
    m_arvalid   : out std_logic;
    m_arready   : in  std_logic;
    m_araddr    : out std_logic_vector(31 downto 0);
    m_arlen     : out std_logic_vector(7 downto 0);
    m_arsize    : out std_logic_vector(2 downto 0);
    m_arburst   : out std_logic_vector(1 downto 0);
    m_arprot    : out std_logic_vector(2 downto 0);
    m_rvalid    : in  std_logic;
    m_rready    : out std_logic;
    m_rdata     : in  std_logic_vector(31 downto 0);
    m_rresp     : in  std_logic_vector(1 downto 0);
    m_rlast     : in  std_logic
  );
end entity axi_master_bridge;

architecture rtl of axi_master_bridge is

  -- word k (1 to 3) of the three extra words, and its four byte enables
  function word_x (v : std_logic_vector(95 downto 0); k : natural) return std_logic_vector is
  begin
    if k = 0 then
      return x"00000000";
    end if;
    return v(32 * k - 1 downto 32 * (k - 1));
  end function;

  function be_x (v : std_logic_vector(11 downto 0); k : natural) return std_logic_vector is
  begin
    if k = 0 then
      return "0000";
    end if;
    return v(4 * k - 1 downto 4 * (k - 1));
  end function;

  type state_t is (ST_IDLE, ST_WR, ST_RD, ST_DONE);
  signal st      : state_t := ST_IDLE;

  signal awv     : std_logic := '0';
  signal wv      : std_logic := '0';
  signal arv     : std_logic := '0';
  signal beat    : natural range 0 to 3 := 0;   -- the beat on W, or the next one of R
  signal last_b  : natural range 0 to 3 := 0;   -- 3 for a line, 0 for a word
  signal addr_l  : std_logic_vector(31 downto 0) := (others => '0');
  signal wdata_l : std_logic_vector(31 downto 0) := (others => '0');
  signal strb_l  : std_logic_vector(3 downto 0) := (others => '0');
  signal wdx_l   : std_logic_vector(95 downto 0) := (others => '0');
  signal bex_l   : std_logic_vector(11 downto 0) := (others => '0');
  signal we_l    : std_logic := '0';
  signal err_l   : std_logic := '0';
  signal pending   : std_logic_vector(31 downto 0) := (others => '0');
  signal pending_x : std_logic_vector(95 downto 0) := (others => '0');
  signal rdata_q   : std_logic_vector(31 downto 0) := (others => '0');
  signal rdx_q     : std_logic_vector(95 downto 0) := (others => '0');

begin

  m_awvalid <= awv;
  m_awaddr  <= addr_l;
  m_awlen   <= "00000011" when last_b = 3 else "00000000";
  m_awsize  <= "010";   -- 4 bytes
  m_awburst <= "01";    -- INCR
  m_awprot  <= "000";   -- unprivileged, secure, data
  m_wvalid  <= wv;
  m_wdata   <= wdata_l when beat = 0 else word_x(wdx_l, beat);
  m_wstrb   <= strb_l  when beat = 0 else be_x(bex_l, beat);
  m_wlast   <= '1' when beat = last_b else '0';
  m_arvalid <= arv;
  m_araddr  <= addr_l;
  m_arlen   <= "00000011" when last_b = 3 else "00000000";
  m_arsize  <= "010";
  m_arburst <= "01";
  m_arprot  <= "000";

  -- a response is taken only once the request it answers was accepted
  m_bready  <= '1' when st = ST_WR and awv = '0' and wv = '0' else '0';
  m_rready  <= '1' when st = ST_RD and arv = '0' else '0';

  ready     <= '1' when st = ST_DONE else '0';
  rdata     <= rdata_q;
  rdata_x   <= rdx_q;
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
        beat  <= 0;
      else
        case st is

          when ST_IDLE =>
            if (rden = '1' or wren = '1') then
              addr_l  <= addr(31 downto 2) & "00";   -- whole words; the byte enables pick the bytes
              wdata_l <= wdata;
              strb_l  <= byteena;
              wdx_l   <= wdata_x;
              bex_l   <= byteena_x;
              we_l    <= wren;
              beat    <= 0;
              err_l   <= '0';
              if line = '1' then
                last_b <= 3;
              else
                last_b <= 0;
              end if;
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
              if beat = last_b then
                wv   <= '0';
                beat <= 0;
              else
                beat <= beat + 1;
              end if;
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
              if beat = 0 then
                pending <= m_rdata;
              else
                pending_x(32 * beat - 1 downto 32 * (beat - 1)) <= m_rdata;   -- beat 1 to 3 here
              end if;
              if m_rresp(1) = '1' then
                err_l <= '1';
              end if;
              if (m_rlast = '1') /= (beat = last_b) then
                err_l <= '1';       -- the burst has a different length than the one asked for
              end if;
              if beat = last_b or m_rlast = '1' then
                st <= ST_DONE;
              else
                beat <= beat + 1;
              end if;
            end if;

          when ST_DONE =>
            if mem_advance = '1' then
              if we_l = '0' then
                rdata_q <= pending;
                rdx_q   <= pending_x;
              end if;
              st <= ST_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
