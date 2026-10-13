library ieee;
use ieee.std_logic_1164.all;

-- The core's external data port over AXI4-Lite: what ext_interconnect and sdram_cpu_bridge do on a
-- private bus, here as one AXI4-Lite master with two slaves behind it.
--
--   bit 31 = 0   the SDRAM space: through the data cache, as lines of four words, except its
--                last 4 KB (0x43FFF000 to 0x43FFFFFF), which is not cached: the words the host
--                shares with the program (mailbox, tohost, fromhost, go flag, stdout) live there,
--                and the host reads and writes them through the debug port of the SDRAM
--   bit 31 = 1   a peripheral window (bits 30:28 the peripheral, 9:2 the word), not cached
--
-- Peripheral 7 is the cache's own control, not an external one: a write to its first word asks the
-- cache to write every dirty line back (a program does it before it ends, so the host reads what
-- the program wrote), and a read of it gives 1 while that is under way, 0 otherwise. An access that
-- does not go through the cache waits while a flush is under way, as the cache's own accesses do.
--
-- Core side, the contract of ext_interconnect: the access sits on the port while the memory stage is
-- stopped; ready is a level until mem_advance; rdata only changes when a load completes and stays
-- until the next one does, because the load in the last stage still reads it while the next access
-- is already on the port.
--
-- Slave 0 of the router (the SDRAM) is the AXI4-Lite master port m0_* of this entity, for
-- axil_slave_word_bridge or any other AXI4-Lite slave; the peripheral window is the p_* port of
-- ext_interconnect, behind axil_slave_periph_bank.
entity ext_axi_interconnect is
  generic (
    BASE : std_logic_vector(5 downto 0) := "010000"
  );
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;  -- synchronous, active high

    -- the core's external port
    addr        : in  std_logic_vector(31 downto 0);
    wdata       : in  std_logic_vector(31 downto 0);
    byteena     : in  std_logic_vector(3 downto 0);
    rden        : in  std_logic;
    wren        : in  std_logic;
    mem_advance : in  std_logic;
    ready       : out std_logic;
    rdata       : out std_logic_vector(31 downto 0);

    -- the data cache (flush: one pulse asks for a flush, as a write to peripheral 7 does)
    flush       : in  std_logic := '0';
    flush_done  : out std_logic;
    busy        : out std_logic;

    -- AXI4-Lite master port to the SDRAM
    m0_awvalid : out std_logic; m0_awready : in std_logic; m0_awaddr : out std_logic_vector(31 downto 0);
    m0_wvalid  : out std_logic; m0_wready  : in std_logic; m0_wdata  : out std_logic_vector(31 downto 0);
    m0_wstrb   : out std_logic_vector(3 downto 0);
    m0_bvalid  : in  std_logic; m0_bready  : out std_logic; m0_bresp : in std_logic_vector(1 downto 0);
    m0_arvalid : out std_logic; m0_arready : in std_logic; m0_araddr : out std_logic_vector(31 downto 0);
    m0_rvalid  : in  std_logic; m0_rready  : out std_logic;
    m0_rdata   : in  std_logic_vector(31 downto 0); m0_rresp : in std_logic_vector(1 downto 0);

    -- the peripherals (as ext_interconnect)
    p_addr      : out std_logic_vector(7 downto 0);
    p_wdata     : out std_logic_vector(31 downto 0);
    p_byteena   : out std_logic_vector(3 downto 0);
    p_we        : out std_logic_vector(7 downto 0);
    p_re        : out std_logic_vector(7 downto 0);
    p_rdata     : in  std_logic_vector(8 * 32 - 1 downto 0)
  );
end entity ext_axi_interconnect;

architecture rtl of ext_axi_interconnect is

  signal mmio : std_logic;                   -- the address is not cached
  signal direct : std_logic;                 -- an access that does not go through the cache owns the master
  signal own    : std_logic := '0';          -- one that started and has not been advanced yet
  signal c_busy : std_logic;
  signal flush_i : std_logic;
  signal p_we_i, p_re_i : std_logic_vector(7 downto 0);
  signal p_rdata_i : std_logic_vector(8 * 32 - 1 downto 0);

  -- the data cache
  signal c_rden, c_wren, c_ready : std_logic;
  signal c_rdata : std_logic_vector(31 downto 0);
  signal d_addr, d_wdata, d_rdata : std_logic_vector(31 downto 0);
  signal d_be : std_logic_vector(3 downto 0);
  signal d_rden, d_wren, d_advance, d_ready : std_logic;

  -- the AXI4-Lite master
  signal b_addr, b_wdata, b_rdata : std_logic_vector(31 downto 0);
  signal b_be : std_logic_vector(3 downto 0);
  signal b_rden, b_wren, b_advance, b_ready, b_err : std_logic;

  signal awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready : std_logic;
  signal awaddr, wdata_a, araddr, rdata_a : std_logic_vector(31 downto 0);
  signal awprot, arprot : std_logic_vector(2 downto 0);
  signal wstrb : std_logic_vector(3 downto 0);
  signal bresp, rresp : std_logic_vector(1 downto 0);

  -- slave 1: the peripherals
  signal m1_awvalid, m1_awready, m1_wvalid, m1_wready, m1_bvalid, m1_bready : std_logic;
  signal m1_arvalid, m1_arready, m1_rvalid, m1_rready : std_logic;
  signal m1_awaddr, m1_wdata, m1_araddr, m1_rdata : std_logic_vector(31 downto 0);
  signal m1_wstrb : std_logic_vector(3 downto 0);
  signal m1_bresp, m1_rresp : std_logic_vector(1 downto 0);

  -- where the data of the last completed load came from: 0 the cache, 1 the master (the clock after
  -- it completed), 2 the register that keeps it
  signal sel      : std_logic_vector(1 downto 0) := "00";
  signal hold_q   : std_logic_vector(31 downto 0) := (others => '0');

begin

  mmio   <= '1' when addr(31) = '1' or addr(25 downto 12) = "11111111111111" else '0';
  -- the core's own access takes the master when the cache is not flushing, or when it already has it
  direct <= mmio and (rden or wren) and (own or not c_busy);
  busy   <= c_busy;
  c_rden <= rden and not mmio;
  c_wren <= wren and not mmio;

  u_cache : entity work.dcache
    generic map (BASE => BASE)
    port map (
      clk => clk, rst => rst,
      addr => addr, wdata => wdata, byteena => byteena, rden => c_rden, wren => c_wren,
      mem_advance => mem_advance, ready => c_ready, rdata => c_rdata,
      flush => flush_i, flush_done => flush_done, busy => c_busy,
      d_addr => d_addr, d_wdata => d_wdata, d_byteena => d_be, d_rden => d_rden, d_wren => d_wren,
      d_advance => d_advance, d_ready => d_ready, d_rdata => d_rdata
    );

  -- one access at a time on the AXI4-Lite master: the core's own (not cached) or the cache's; the
  -- core's wins only while it has an access on the port, so a port that rests on a peripheral address
  -- does not keep the cache from its own accesses
  b_addr    <= addr    when direct = '1' else d_addr;
  b_wdata   <= wdata   when direct = '1' else d_wdata;
  b_be      <= byteena when direct = '1' else d_be;
  b_rden    <= rden when direct = '1' else d_rden;
  b_wren    <= wren when direct = '1' else d_wren;
  b_advance <= mem_advance when direct = '1' else d_advance;
  d_ready   <= b_ready and not direct;
  d_rdata   <= b_rdata;

  ready <= (b_ready and direct) when mmio = '1' else c_ready;
  rdata <= c_rdata when sel = "00" else b_rdata when sel = "01" else hold_q;

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        sel    <= "00";
        hold_q <= (others => '0');
        own    <= '0';
      elsif rden = '1' and mem_advance = '1' and ((mmio = '1' and b_ready = '1' and direct = '1') or (mmio = '0' and c_ready = '1')) then
        if mmio = '1' then sel <= "01"; else sel <= "00"; end if;
      elsif sel = "01" then
        hold_q <= b_rdata;
        sel    <= "10";
      end if;
      if direct = '1' then
        own <= '1';
      end if;
      if direct = '1' and mem_advance = '1' and b_ready = '1' then
        own <= '0';
      end if;
    end if;
  end process;

  u_master : entity work.axil_master_bridge
    port map (
      clk => clk, rst => rst,
      addr => b_addr, wdata => b_wdata, byteena => b_be, rden => b_rden, wren => b_wren,
      mem_advance => b_advance, ready => b_ready, rdata => b_rdata, err => b_err,
      m_awvalid => awvalid, m_awready => awready, m_awaddr => awaddr, m_awprot => awprot,
      m_wvalid => wvalid, m_wready => wready, m_wdata => wdata_a, m_wstrb => wstrb,
      m_bvalid => bvalid, m_bready => bready, m_bresp => bresp,
      m_arvalid => arvalid, m_arready => arready, m_araddr => araddr, m_arprot => arprot,
      m_rvalid => rvalid, m_rready => rready, m_rdata => rdata_a, m_rresp => rresp
    );

  u_router : entity work.axil_router
    port map (
      clk => clk, rst => rst,
      s_awvalid => awvalid, s_awready => awready, s_awaddr => awaddr,
      s_wvalid => wvalid, s_wready => wready, s_wdata => wdata_a, s_wstrb => wstrb,
      s_bvalid => bvalid, s_bready => bready, s_bresp => bresp,
      s_arvalid => arvalid, s_arready => arready, s_araddr => araddr,
      s_rvalid => rvalid, s_rready => rready, s_rdata => rdata_a, s_rresp => rresp,
      m0_awvalid => m0_awvalid, m0_awready => m0_awready, m0_awaddr => m0_awaddr,
      m0_wvalid => m0_wvalid, m0_wready => m0_wready, m0_wdata => m0_wdata, m0_wstrb => m0_wstrb,
      m0_bvalid => m0_bvalid, m0_bready => m0_bready, m0_bresp => m0_bresp,
      m0_arvalid => m0_arvalid, m0_arready => m0_arready, m0_araddr => m0_araddr,
      m0_rvalid => m0_rvalid, m0_rready => m0_rready, m0_rdata => m0_rdata, m0_rresp => m0_rresp,
      m1_awvalid => m1_awvalid, m1_awready => m1_awready, m1_awaddr => m1_awaddr,
      m1_wvalid => m1_wvalid, m1_wready => m1_wready, m1_wdata => m1_wdata, m1_wstrb => m1_wstrb,
      m1_bvalid => m1_bvalid, m1_bready => m1_bready, m1_bresp => m1_bresp,
      m1_arvalid => m1_arvalid, m1_arready => m1_arready, m1_araddr => m1_araddr,
      m1_rvalid => m1_rvalid, m1_rready => m1_rready, m1_rdata => m1_rdata, m1_rresp => m1_rresp
    );

  u_periph : entity work.axil_slave_periph_bank
    port map (
      clk => clk, rst => rst,
      s_awvalid => m1_awvalid, s_awready => m1_awready, s_awaddr => m1_awaddr,
      s_wvalid => m1_wvalid, s_wready => m1_wready, s_wdata => m1_wdata, s_wstrb => m1_wstrb,
      s_bvalid => m1_bvalid, s_bready => m1_bready, s_bresp => m1_bresp,
      s_arvalid => m1_arvalid, s_arready => m1_arready, s_araddr => m1_araddr,
      s_rvalid => m1_rvalid, s_rready => m1_rready, s_rdata => m1_rdata, s_rresp => m1_rresp,
      p_addr => p_addr, p_wdata => p_wdata, p_byteena => p_byteena, p_we => p_we_i, p_re => p_re_i,
      p_rdata => p_rdata_i
    );

  -- peripheral 7 is the cache's control
  flush_i <= flush or p_we_i(7);
  p_we    <= p_we_i and "01111111";
  p_re    <= p_re_i and "01111111";
  p_rdata_i(7 * 32)                           <= c_busy;
  p_rdata_i(8 * 32 - 1 downto 7 * 32 + 1)     <= (others => '0');
  p_rdata_i(7 * 32 - 1 downto 0)      <= p_rdata(7 * 32 - 1 downto 0);

end architecture rtl;
