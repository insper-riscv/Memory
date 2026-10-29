library ieee;
use ieee.std_logic_1164.all;

-- The core's external data port over AXI4: what ext_interconnect and sdram_cpu_bridge do on a
-- private bus, here as one AXI4 master with two slaves behind it. The cache moves a line as one burst
-- of four beats; everything else is a single beat.
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
-- axi_slave_word_bridge or any other AXI4 slave; the peripheral window is the p_* port of
-- ext_interconnect, behind axi_slave_periph_bank.
entity ext_axi_interconnect is
  generic (
    BASE          : std_logic_vector(5 downto 0) := "010000";
    WRITE_THROUGH : boolean := false      -- the cache writes every store through (see dcache)
  );
  port (
    i_clk         : in  std_logic;
    i_rst         : in  std_logic;  -- synchronous, active high

    -- the core's external port
    i_addr        : in  std_logic_vector(31 downto 0);
    i_wdata       : in  std_logic_vector(31 downto 0);
    i_byteena     : in  std_logic_vector(3 downto 0);
    i_rden        : in  std_logic;
    i_wren        : in  std_logic;
    i_mem_advance : in  std_logic;
    o_ready       : out std_logic;
    o_rdata       : out std_logic_vector(31 downto 0);

    -- the data cache (flush: one pulse asks for a flush, as a write to peripheral 7 does)
    i_flush       : in  std_logic := '0';
    o_flush_done  : out std_logic;
    o_busy        : out std_logic;

    -- AXI4 master port to the SDRAM
    o_m0_awvalid : out std_logic; i_m0_awready : in std_logic; o_m0_awaddr : out std_logic_vector(31 downto 0);
    o_m0_awlen   : out std_logic_vector(7 downto 0); o_m0_awsize : out std_logic_vector(2 downto 0); o_m0_awburst : out std_logic_vector(1 downto 0);
    o_m0_wvalid  : out std_logic; i_m0_wready  : in std_logic; o_m0_wdata  : out std_logic_vector(31 downto 0);
    o_m0_wstrb   : out std_logic_vector(3 downto 0); o_m0_wlast : out std_logic;
    i_m0_bvalid  : in  std_logic; o_m0_bready  : out std_logic; i_m0_bresp : in std_logic_vector(1 downto 0);
    o_m0_arvalid : out std_logic; i_m0_arready : in std_logic; o_m0_araddr : out std_logic_vector(31 downto 0);
    o_m0_arlen   : out std_logic_vector(7 downto 0); o_m0_arsize : out std_logic_vector(2 downto 0); o_m0_arburst : out std_logic_vector(1 downto 0);
    i_m0_rvalid  : in  std_logic; o_m0_rready  : out std_logic;
    i_m0_rdata   : in  std_logic_vector(31 downto 0); i_m0_rresp : in std_logic_vector(1 downto 0); i_m0_rlast : in std_logic;

    -- the peripherals (as ext_interconnect)
    o_p_addr      : out std_logic_vector(7 downto 0);
    o_p_wdata     : out std_logic_vector(31 downto 0);
    o_p_byteena   : out std_logic_vector(3 downto 0);
    o_p_we        : out std_logic_vector(7 downto 0);
    o_p_re        : out std_logic_vector(7 downto 0);
    i_p_rdata     : in  std_logic_vector(8 * 32 - 1 downto 0)
  );
end entity ext_axi_interconnect;

architecture rtl of ext_axi_interconnect is

  signal mmio : std_logic;                   -- the address is not cached
  signal direct : std_logic;                 -- an access that does not go through the cache owns the master
  signal own    : std_logic := '0';          -- one that started and has not been advanced yet
  signal c_busy : std_logic;
  signal flush_i : std_logic;
  signal p_we_i, p_re_i : std_logic_vector(7 downto 0);
  signal p_wdata_i : std_logic_vector(31 downto 0);
  signal p_rdata_i : std_logic_vector(8 * 32 - 1 downto 0);

  -- the data cache
  signal c_rden, c_wren, c_ready : std_logic;
  signal c_rdata : std_logic_vector(31 downto 0);
  signal d_addr, d_wdata, d_rdata : std_logic_vector(31 downto 0);
  signal d_be : std_logic_vector(3 downto 0);
  signal d_rden, d_wren, d_advance, d_ready : std_logic;
  signal d_line : std_logic;
  signal d_wdata_x, d_rdata_x : std_logic_vector(95 downto 0);

  -- the AXI4 master
  signal b_addr, b_wdata, b_rdata : std_logic_vector(31 downto 0);
  signal b_be : std_logic_vector(3 downto 0);
  signal b_rden, b_wren, b_advance, b_ready, b_err : std_logic;
  signal b_line : std_logic;
  signal b_wdata_x, b_rdata_x : std_logic_vector(95 downto 0);

  signal awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready : std_logic;
  signal awaddr, wdata_a, araddr, rdata_a : std_logic_vector(31 downto 0);
  signal awlen, arlen : std_logic_vector(7 downto 0);
  signal awsize, arsize, awprot, arprot : std_logic_vector(2 downto 0);
  signal awburst, arburst : std_logic_vector(1 downto 0);
  signal wstrb : std_logic_vector(3 downto 0);
  signal wlast, rlast : std_logic;
  signal bresp, rresp : std_logic_vector(1 downto 0);

  -- slave 1: the peripherals
  signal m1_awvalid, m1_awready, m1_wvalid, m1_wready, m1_bvalid, m1_bready : std_logic;
  signal m1_arvalid, m1_arready, m1_rvalid, m1_rready, m1_wlast, m1_rlast : std_logic;
  signal m1_awaddr, m1_wdata, m1_araddr, m1_rdata : std_logic_vector(31 downto 0);
  signal m1_awlen, m1_arlen : std_logic_vector(7 downto 0);
  signal m1_awsize, m1_arsize : std_logic_vector(2 downto 0);
  signal m1_awburst, m1_arburst : std_logic_vector(1 downto 0);
  signal m1_wstrb : std_logic_vector(3 downto 0);
  signal m1_bresp, m1_rresp : std_logic_vector(1 downto 0);

  -- where the data of the last completed load came from: 0 the cache, 1 the master (the clock after
  -- it completed), 2 the register that keeps it
  signal sel      : std_logic_vector(1 downto 0) := "00";
  signal hold_q   : std_logic_vector(31 downto 0) := (others => '0');

begin

  mmio   <= '1' when i_addr(31) = '1' or i_addr(25 downto 12) = "11111111111111" else '0';
  -- the core's own access takes the master when the cache is not flushing, or when it already has it
  direct <= mmio and (i_rden or i_wren) and (own or not c_busy);
  o_busy   <= c_busy;
  c_rden <= i_rden and not mmio;
  c_wren <= i_wren and not mmio;

  u_cache : entity work.dcache
    generic map (BASE => BASE, WRITE_THROUGH => WRITE_THROUGH)
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_addr => i_addr, i_wdata => i_wdata, i_byteena => i_byteena, i_rden => c_rden, i_wren => c_wren,
      i_mem_advance => i_mem_advance, o_ready => c_ready, o_rdata => c_rdata,
      i_flush => flush_i, i_invalidate => p_wdata_i(1) and p_we_i(7), o_flush_done => o_flush_done, o_busy => c_busy,
      o_d_addr => d_addr, o_d_wdata => d_wdata, o_d_byteena => d_be, o_d_rden => d_rden, o_d_wren => d_wren,
      o_d_advance => d_advance, i_d_ready => d_ready, i_d_rdata => d_rdata,
      o_d_line => d_line, o_d_wdata_x => d_wdata_x, i_d_rdata_x => d_rdata_x
    );

  -- one access at a time on the AXI4-Lite master: the core's own (not cached) or the cache's; the
  -- core's wins only while it has an access on the port, so a port that rests on a peripheral address
  -- does not keep the cache from its own accesses
  b_addr    <= i_addr    when direct = '1' else d_addr;
  b_wdata   <= i_wdata   when direct = '1' else d_wdata;
  b_be      <= i_byteena when direct = '1' else d_be;
  b_rden    <= i_rden when direct = '1' else d_rden;
  b_wren    <= i_wren when direct = '1' else d_wren;
  b_advance <= i_mem_advance when direct = '1' else d_advance;
  b_line    <= '0' when direct = '1' else d_line;
  b_wdata_x <= d_wdata_x;
  d_ready   <= b_ready and not direct;
  d_rdata   <= b_rdata;
  d_rdata_x <= b_rdata_x;

  o_ready <= (b_ready and direct) when mmio = '1' else c_ready;
  o_rdata <= c_rdata when sel = "00" else b_rdata when sel = "01" else hold_q;

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        sel    <= "00";
        hold_q <= (others => '0');
        own    <= '0';
      elsif i_rden = '1' and i_mem_advance = '1' and ((mmio = '1' and b_ready = '1' and direct = '1') or (mmio = '0' and c_ready = '1')) then
        if mmio = '1' then sel <= "01"; else sel <= "00"; end if;
      elsif sel = "01" then
        hold_q <= b_rdata;
        sel    <= "10";
      end if;
      if direct = '1' then
        own <= '1';
      end if;
      if direct = '1' and i_mem_advance = '1' and b_ready = '1' then
        own <= '0';
      end if;
    end if;
  end process;

  u_master : entity work.axi_master_bridge
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_addr => b_addr, i_wdata => b_wdata, i_byteena => b_be, i_rden => b_rden, i_wren => b_wren,
      i_mem_advance => b_advance, o_ready => b_ready, o_rdata => b_rdata,
      i_line => b_line, i_wdata_x => b_wdata_x, i_byteena_x => (others => '1'), o_rdata_x => b_rdata_x, o_err => b_err,
      o_m_awvalid => awvalid, i_m_awready => awready, o_m_awaddr => awaddr, o_m_awlen => awlen,
      o_m_awsize => awsize, o_m_awburst => awburst, o_m_awprot => awprot,
      o_m_wvalid => wvalid, i_m_wready => wready, o_m_wdata => wdata_a, o_m_wstrb => wstrb, o_m_wlast => wlast,
      i_m_bvalid => bvalid, o_m_bready => bready, i_m_bresp => bresp,
      o_m_arvalid => arvalid, i_m_arready => arready, o_m_araddr => araddr, o_m_arlen => arlen,
      o_m_arsize => arsize, o_m_arburst => arburst, o_m_arprot => arprot,
      i_m_rvalid => rvalid, o_m_rready => rready, i_m_rdata => rdata_a, i_m_rresp => rresp, i_m_rlast => rlast
    );

  u_router : entity work.axi_router
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_s_awvalid => awvalid, o_s_awready => awready, i_s_awaddr => awaddr, i_s_awlen => awlen, i_s_awsize => awsize, i_s_awburst => awburst,
      i_s_wvalid => wvalid, o_s_wready => wready, i_s_wdata => wdata_a, i_s_wstrb => wstrb, i_s_wlast => wlast,
      o_s_bvalid => bvalid, i_s_bready => bready, o_s_bresp => bresp,
      i_s_arvalid => arvalid, o_s_arready => arready, i_s_araddr => araddr, i_s_arlen => arlen, i_s_arsize => arsize, i_s_arburst => arburst,
      o_s_rvalid => rvalid, i_s_rready => rready, o_s_rdata => rdata_a, o_s_rresp => rresp, o_s_rlast => rlast,
      o_m0_awvalid => o_m0_awvalid, i_m0_awready => i_m0_awready, o_m0_awaddr => o_m0_awaddr, o_m0_awlen => o_m0_awlen,
      o_m0_awsize => o_m0_awsize, o_m0_awburst => o_m0_awburst,
      o_m0_wvalid => o_m0_wvalid, i_m0_wready => i_m0_wready, o_m0_wdata => o_m0_wdata, o_m0_wstrb => o_m0_wstrb, o_m0_wlast => o_m0_wlast,
      i_m0_bvalid => i_m0_bvalid, o_m0_bready => o_m0_bready, i_m0_bresp => i_m0_bresp,
      o_m0_arvalid => o_m0_arvalid, i_m0_arready => i_m0_arready, o_m0_araddr => o_m0_araddr, o_m0_arlen => o_m0_arlen,
      o_m0_arsize => o_m0_arsize, o_m0_arburst => o_m0_arburst,
      i_m0_rvalid => i_m0_rvalid, o_m0_rready => o_m0_rready, i_m0_rdata => i_m0_rdata, i_m0_rresp => i_m0_rresp, i_m0_rlast => i_m0_rlast,
      o_m1_awvalid => m1_awvalid, i_m1_awready => m1_awready, o_m1_awaddr => m1_awaddr, o_m1_awlen => m1_awlen,
      o_m1_awsize => m1_awsize, o_m1_awburst => m1_awburst,
      o_m1_wvalid => m1_wvalid, i_m1_wready => m1_wready, o_m1_wdata => m1_wdata, o_m1_wstrb => m1_wstrb, o_m1_wlast => m1_wlast,
      i_m1_bvalid => m1_bvalid, o_m1_bready => m1_bready, i_m1_bresp => m1_bresp,
      o_m1_arvalid => m1_arvalid, i_m1_arready => m1_arready, o_m1_araddr => m1_araddr, o_m1_arlen => m1_arlen,
      o_m1_arsize => m1_arsize, o_m1_arburst => m1_arburst,
      i_m1_rvalid => m1_rvalid, o_m1_rready => m1_rready, i_m1_rdata => m1_rdata, i_m1_rresp => m1_rresp, i_m1_rlast => m1_rlast
    );

  u_periph : entity work.axi_slave_periph_bank
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_s_awvalid => m1_awvalid, o_s_awready => m1_awready, i_s_awaddr => m1_awaddr, i_s_awlen => m1_awlen,
      i_s_awsize => m1_awsize, i_s_awburst => m1_awburst,
      i_s_wvalid => m1_wvalid, o_s_wready => m1_wready, i_s_wdata => m1_wdata, i_s_wstrb => m1_wstrb, i_s_wlast => m1_wlast,
      o_s_bvalid => m1_bvalid, i_s_bready => m1_bready, o_s_bresp => m1_bresp,
      i_s_arvalid => m1_arvalid, o_s_arready => m1_arready, i_s_araddr => m1_araddr, i_s_arlen => m1_arlen,
      i_s_arsize => m1_arsize, i_s_arburst => m1_arburst,
      o_s_rvalid => m1_rvalid, i_s_rready => m1_rready, o_s_rdata => m1_rdata, o_s_rresp => m1_rresp, o_s_rlast => m1_rlast,
      o_p_addr => o_p_addr, o_p_wdata => p_wdata_i, o_p_byteena => o_p_byteena, o_p_we => p_we_i, o_p_re => p_re_i,
      i_p_rdata => p_rdata_i
    );

  -- peripheral 7 is the cache's control
  flush_i <= i_flush or p_we_i(7);
  o_p_wdata <= p_wdata_i;
  o_p_we    <= p_we_i and "01111111";
  o_p_re    <= p_re_i and "01111111";
  p_rdata_i(7 * 32)                           <= c_busy;
  p_rdata_i(8 * 32 - 1 downto 7 * 32 + 1)     <= (others => '0');
  p_rdata_i(7 * 32 - 1 downto 0)      <= i_p_rdata(7 * 32 - 1 downto 0);

end architecture rtl;
