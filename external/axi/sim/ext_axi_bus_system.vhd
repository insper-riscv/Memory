library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Simulation top of the AXI4 external bus, the counterpart of ext_bus_system: the core's port
-- over ext_axi_interconnect, the JTAG UART in peripheral slot 4, and behind the SDRAM slave port a
-- small word memory (4096 words, two clocks to answer) with the value 0x12345678 at 0x40000100.
-- jtag_* stand for a Virtual JTAG instance (see jtag_uart).
entity ext_axi_bus_system is
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;

    addr        : in  std_logic_vector(31 downto 0);
    wdata       : in  std_logic_vector(31 downto 0);
    byteena     : in  std_logic_vector(3 downto 0);
    rden        : in  std_logic;
    wren        : in  std_logic;
    mem_advance : in  std_logic;
    ready       : out std_logic;
    rdata       : out std_logic_vector(31 downto 0);

    flush       : in  std_logic := '0';
    flush_done  : out std_logic;
    busy        : out std_logic;

    -- the word memory behind the SDRAM slave, read without going through the bus
    dbg_word_addr : in  std_logic_vector(11 downto 0) := (others => '0');
    dbg_word_data : out std_logic_vector(31 downto 0);

    jtag_tck        : in  std_logic := '0';
    jtag_tdi        : in  std_logic := '0';
    jtag_tdo        : out std_logic;
    jtag_ir_in      : in  std_logic_vector(1 downto 0) := "00";
    jtag_state_cdr  : in  std_logic := '0';
    jtag_state_sdr  : in  std_logic := '0';
    jtag_state_udr  : in  std_logic := '0';
    jtag_state_uir  : in  std_logic := '0'
  );
end entity ext_axi_bus_system;

architecture sim of ext_axi_bus_system is
  signal awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready, wlast, rlast : std_logic;
  signal awaddr, wdata_a, araddr, rdata_a : std_logic_vector(31 downto 0);
  signal awlen, arlen : std_logic_vector(7 downto 0);
  signal awsize, arsize : std_logic_vector(2 downto 0);
  signal awburst, arburst : std_logic_vector(1 downto 0);
  signal wstrb : std_logic_vector(3 downto 0);
  signal bresp, rresp : std_logic_vector(1 downto 0);

  signal p_addr   : std_logic_vector(7 downto 0);
  signal p_wdata  : std_logic_vector(31 downto 0);
  signal p_byteena : std_logic_vector(3 downto 0);
  signal p_we, p_re : std_logic_vector(7 downto 0);
  signal p_rdata  : std_logic_vector(8 * 32 - 1 downto 0) := (others => '0');

  -- the word memory behind the slave bridge
  signal m_addr, m_wdata, m_rdata : std_logic_vector(31 downto 0) := (others => '0');
  signal m_be : std_logic_vector(3 downto 0);
  signal m_rden, m_wren, m_adv, m_ready, m_line : std_logic;
  signal m_wdx, m_rdx : std_logic_vector(95 downto 0) := (others => '0');
  signal m_bex : std_logic_vector(11 downto 0);

  type mem_t is array (0 to 4095) of std_logic_vector(31 downto 0);
  signal mem : mem_t := (16#40# => x"12345678", others => (others => '0'));
  signal lat : natural range 0 to 3 := 0;
  signal ready_i : std_logic := '0';
begin

  u_ic : entity work.ext_axi_interconnect
    port map (
      clk => clk, rst => rst,
      addr => addr, wdata => wdata, byteena => byteena, rden => rden, wren => wren,
      mem_advance => mem_advance, ready => ready, rdata => rdata,
      flush => flush, flush_done => flush_done, busy => busy,
      m0_awvalid => awvalid, m0_awready => awready, m0_awaddr => awaddr, m0_awlen => awlen,
      m0_awsize => awsize, m0_awburst => awburst,
      m0_wvalid => wvalid, m0_wready => wready, m0_wdata => wdata_a, m0_wstrb => wstrb, m0_wlast => wlast,
      m0_bvalid => bvalid, m0_bready => bready, m0_bresp => bresp,
      m0_arvalid => arvalid, m0_arready => arready, m0_araddr => araddr, m0_arlen => arlen,
      m0_arsize => arsize, m0_arburst => arburst,
      m0_rvalid => rvalid, m0_rready => rready, m0_rdata => rdata_a, m0_rresp => rresp, m0_rlast => rlast,
      p_addr => p_addr, p_wdata => p_wdata, p_byteena => p_byteena, p_we => p_we, p_re => p_re,
      p_rdata => p_rdata
    );

  u_slave : entity work.axi_slave_word_bridge
    port map (
      clk => clk, rst => rst,
      s_awvalid => awvalid, s_awready => awready, s_awaddr => awaddr, s_awlen => awlen,
      s_awsize => awsize, s_awburst => awburst,
      s_wvalid => wvalid, s_wready => wready, s_wdata => wdata_a, s_wstrb => wstrb, s_wlast => wlast,
      s_bvalid => bvalid, s_bready => bready, s_bresp => bresp,
      s_arvalid => arvalid, s_arready => arready, s_araddr => araddr, s_arlen => arlen,
      s_arsize => arsize, s_arburst => arburst,
      s_rvalid => rvalid, s_rready => rready, s_rdata => rdata_a, s_rresp => rresp, s_rlast => rlast,
      addr => m_addr, wdata => m_wdata, byteena => m_be, rden => m_rden, wren => m_wren,
      mem_advance => m_adv, ready => m_ready, rdata => m_rdata,
      line => m_line, wdata_x => m_wdx, byteena_x => m_bex, rdata_x => m_rdx
    );

  -- the memory: ready two clocks after the access starts, a level until mem_advance; the read
  -- data changes on the edge of mem_advance. A line access moves the four words of the line.
  m_ready <= ready_i;
  dbg_word_data <= mem(to_integer(unsigned(dbg_word_addr)));
  process (clk)
    variable i : integer;
  begin
    if rising_edge(clk) then
      i := to_integer(unsigned(m_addr(13 downto 2)));
      if rst = '1' then
        ready_i <= '0';
        lat     <= 0;
      elsif m_adv = '1' then
        ready_i <= '0';
        lat     <= 0;
        if m_rden = '1' then
          m_rdata <= mem(i);
          if m_line = '1' then
            m_rdx <= mem(i + 3) & mem(i + 2) & mem(i + 1);
          end if;
        end if;
      elsif (m_rden = '1' or m_wren = '1') and ready_i = '0' then
        if lat = 1 then
          ready_i <= '1';
          if m_wren = '1' then
            for b in 0 to 3 loop
              if m_be(b) = '1' then
                mem(i)(8 * b + 7 downto 8 * b) <= m_wdata(8 * b + 7 downto 8 * b);
              end if;
            end loop;
            if m_line = '1' then
              for w in 1 to 3 loop
                for b in 0 to 3 loop
                  if m_bex(4 * (w - 1) + b) = '1' then
                    mem(i + w)(8 * b + 7 downto 8 * b) <= m_wdx(32 * (w - 1) + 8 * b + 7 downto 32 * (w - 1) + 8 * b);
                  end if;
                end loop;
              end loop;
            end if;
          end if;
        else
          lat <= lat + 1;
        end if;
      end if;
    end if;
  end process;

  u_uart : entity work.jtag_uart
    port map (
      clk => clk, rst => rst, addr => p_addr, wdata => p_wdata, we => p_we(4), re => p_re(4),
      rdata => p_rdata(32 * 4 + 31 downto 32 * 4),
      tck => jtag_tck, tdi => jtag_tdi, tdo => jtag_tdo, ir_in => jtag_ir_in,
      state_cdr => jtag_state_cdr, state_sdr => jtag_state_sdr,
      state_udr => jtag_state_udr, state_uir => jtag_state_uir
    );

end architecture sim;
