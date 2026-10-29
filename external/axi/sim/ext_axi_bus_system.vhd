library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Simulation top of the AXI4 external bus, the counterpart of ext_bus_system: the core's port
-- over ext_axi_interconnect, the JTAG UART in peripheral slot 4, and behind the SDRAM slave port a
-- small word memory (4096 words, two clocks to answer) with the value 0x12345678 at 0x40000100.
-- jtag_* stand for a Virtual JTAG instance (see jtag_uart).
entity ext_axi_bus_system is
  port (
    i_clk         : in  std_logic;
    i_rst         : in  std_logic;

    i_addr        : in  std_logic_vector(31 downto 0);
    i_wdata       : in  std_logic_vector(31 downto 0);
    i_byteena     : in  std_logic_vector(3 downto 0);
    i_rden        : in  std_logic;
    i_wren        : in  std_logic;
    i_mem_advance : in  std_logic;
    o_ready       : out std_logic;
    o_rdata       : out std_logic_vector(31 downto 0);

    i_flush       : in  std_logic := '0';
    o_flush_done  : out std_logic;
    o_busy        : out std_logic;

    -- the word memory behind the SDRAM slave, read without going through the bus
    i_dbg_word_addr : in  std_logic_vector(11 downto 0) := (others => '0');
    o_dbg_word_data : out std_logic_vector(31 downto 0);

    i_jtag_tck        : in  std_logic := '0';
    i_jtag_tdi        : in  std_logic := '0';
    o_jtag_tdo        : out std_logic;
    i_jtag_ir_in      : in  std_logic_vector(1 downto 0) := "00";
    i_jtag_state_cdr  : in  std_logic := '0';
    i_jtag_state_sdr  : in  std_logic := '0';
    i_jtag_state_udr  : in  std_logic := '0';
    i_jtag_state_uir  : in  std_logic := '0'
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
      i_clk => i_clk, i_rst => i_rst,
      i_addr => i_addr, i_wdata => i_wdata, i_byteena => i_byteena, i_rden => i_rden, i_wren => i_wren,
      i_mem_advance => i_mem_advance, o_ready => o_ready, o_rdata => o_rdata,
      i_flush => i_flush, o_flush_done => o_flush_done, o_busy => o_busy,
      o_m0_awvalid => awvalid, i_m0_awready => awready, o_m0_awaddr => awaddr, o_m0_awlen => awlen,
      o_m0_awsize => awsize, o_m0_awburst => awburst,
      o_m0_wvalid => wvalid, i_m0_wready => wready, o_m0_wdata => wdata_a, o_m0_wstrb => wstrb, o_m0_wlast => wlast,
      i_m0_bvalid => bvalid, o_m0_bready => bready, i_m0_bresp => bresp,
      o_m0_arvalid => arvalid, i_m0_arready => arready, o_m0_araddr => araddr, o_m0_arlen => arlen,
      o_m0_arsize => arsize, o_m0_arburst => arburst,
      i_m0_rvalid => rvalid, o_m0_rready => rready, i_m0_rdata => rdata_a, i_m0_rresp => rresp, i_m0_rlast => rlast,
      o_p_addr => p_addr, o_p_wdata => p_wdata, o_p_byteena => p_byteena, o_p_we => p_we, o_p_re => p_re,
      i_p_rdata => p_rdata
    );

  u_slave : entity work.axi_slave_word_bridge
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_s_awvalid => awvalid, o_s_awready => awready, i_s_awaddr => awaddr, i_s_awlen => awlen,
      i_s_awsize => awsize, i_s_awburst => awburst,
      i_s_wvalid => wvalid, o_s_wready => wready, i_s_wdata => wdata_a, i_s_wstrb => wstrb, i_s_wlast => wlast,
      o_s_bvalid => bvalid, i_s_bready => bready, o_s_bresp => bresp,
      i_s_arvalid => arvalid, o_s_arready => arready, i_s_araddr => araddr, i_s_arlen => arlen,
      i_s_arsize => arsize, i_s_arburst => arburst,
      o_s_rvalid => rvalid, i_s_rready => rready, o_s_rdata => rdata_a, o_s_rresp => rresp, o_s_rlast => rlast,
      o_addr => m_addr, o_wdata => m_wdata, o_byteena => m_be, o_rden => m_rden, o_wren => m_wren,
      o_mem_advance => m_adv, i_ready => m_ready, i_rdata => m_rdata,
      o_line => m_line, o_wdata_x => m_wdx, o_byteena_x => m_bex, i_rdata_x => m_rdx
    );

  -- the memory: ready two clocks after the access starts, a level until mem_advance; the read
  -- data changes on the edge of mem_advance. A line access moves the four words of the line.
  m_ready <= ready_i;
  o_dbg_word_data <= mem(to_integer(unsigned(i_dbg_word_addr)));
  process (i_clk)
    variable i : integer;
  begin
    if rising_edge(i_clk) then
      i := to_integer(unsigned(m_addr(13 downto 2)));
      if i_rst = '1' then
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
      i_clk => i_clk, i_rst => i_rst, i_addr => p_addr, i_wdata => p_wdata, i_we => p_we(4), i_re => p_re(4),
      o_rdata => p_rdata(32 * 4 + 31 downto 32 * 4),
      i_tck => i_jtag_tck, i_tdi => i_jtag_tdi, o_tdo => o_jtag_tdo, i_ir_in => i_jtag_ir_in,
      i_state_cdr => i_jtag_state_cdr, i_state_sdr => i_jtag_state_sdr,
      i_state_udr => i_jtag_state_udr, i_state_uir => i_jtag_state_uir
    );

end architecture sim;
