library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;

-- Simulation top: the bridge, the debug port, the controller and the chip model on two clocks
-- plus the JTAG clock. The core side is the port list a core would drive; the debug ports reach
-- the model (see sdram_model); the jtag_* ports stand for a Virtual JTAG instance (see
-- sdram_jtag_core) and may be left unconnected.
entity sdram_system is
  generic (
    TCK_PS         : natural := T_CK_PS;
    INIT_CYCLES    : natural := cycles(T_INIT_PS, T_CK_PS);
    REFRESH_CYCLES : natural := cycles(T_REFI_PS, T_CK_PS) * 9 / 10
  );
  port (
    clk_mem     : in  std_logic;
    clk_cpu     : in  std_logic;
    rst_mem     : in  std_logic;
    rst_cpu     : in  std_logic;

    addr        : in  std_logic_vector(31 downto 0);
    wdata       : in  std_logic_vector(31 downto 0);
    byteena     : in  std_logic_vector(3 downto 0);
    rden        : in  std_logic;
    wren        : in  std_logic;
    mem_advance : in  std_logic;
    ready       : out std_logic;
    rdata       : out std_logic_vector(31 downto 0);

    init_done       : out std_logic;
    dbg_word_addr   : in  std_logic_vector(23 downto 0);
    dbg_word_data   : out std_logic_vector(31 downto 0);
    dbg_flip        : in  std_logic;
    dbg_flip_addr   : in  std_logic_vector(23 downto 0);
    dbg_flip_bit    : in  std_logic_vector(4 downto 0);
    dbg_refreshes   : out std_logic_vector(31 downto 0);
    dbg_init_ok     : out std_logic;

    jtag_tck        : in  std_logic := '0';
    jtag_tdi        : in  std_logic := '0';
    jtag_tdo        : out std_logic;
    jtag_ir_in      : in  std_logic_vector(1 downto 0) := "00";
    jtag_state_cdr  : in  std_logic := '0';
    jtag_state_sdr  : in  std_logic := '0';
    jtag_state_udr  : in  std_logic := '0';
    jtag_state_uir  : in  std_logic := '0'
  );
end entity sdram_system;

architecture sim of sdram_system is
  signal req_tog, ack_tog, init_i, c_we : std_logic;
  signal c_addr  : std_logic_vector(23 downto 0);
  signal c_wdata, c_rdata : std_logic_vector(31 downto 0);
  signal c_be    : std_logic_vector(3 downto 0);

  -- master A (the core's bridge) and master B (the debug master) of the arbiter
  signal a_req, a_ack, a_we : std_logic;
  signal a_addr  : std_logic_vector(23 downto 0);
  signal a_wdata, a_rdata : std_logic_vector(31 downto 0);
  signal a_be    : std_logic_vector(3 downto 0);
  signal b_req, b_ack, b_we : std_logic;
  signal b_addr  : std_logic_vector(23 downto 0);
  signal b_wdata, b_rdata : std_logic_vector(31 downto 0);
  signal b_be    : std_logic_vector(3 downto 0);

  -- the debug port
  signal cmd_tog, done_tog : std_logic;
  signal d_op, d_be : std_logic_vector(3 downto 0);
  signal d_addr, r_addr : std_logic_vector(23 downto 0);
  signal d_data, r_data : std_logic_vector(31 downto 0);
  signal r_status : std_logic_vector(7 downto 0);

  signal cke, cs_n, ras_n, cas_n, we_n : std_logic;
  signal ba   : std_logic_vector(1 downto 0);
  signal a    : std_logic_vector(12 downto 0);
  signal dqm  : std_logic_vector(1 downto 0);
  signal dq   : std_logic_vector(15 downto 0);
  signal dq_out : std_logic_vector(15 downto 0);
  signal dq_oe  : std_logic;
begin

  init_done <= init_i;

  u_bridge : entity work.sdram_cpu_bridge
    port map (
      clk_cpu => clk_cpu, rst_cpu => rst_cpu,
      addr => addr, wdata => wdata, byteena => byteena, rden => rden, wren => wren,
      mem_advance => mem_advance, ready => ready, rdata => rdata,
      req_tog => a_req, ack_tog => a_ack, init_done => init_i,
      c_we => a_we, c_addr => a_addr, c_wdata => a_wdata, c_be => a_be, c_rdata => a_rdata
    );

  u_jtag : entity work.sdram_jtag_core
    port map (
      tck => jtag_tck, tdi => jtag_tdi, tdo => jtag_tdo, ir_in => jtag_ir_in,
      state_cdr => jtag_state_cdr, state_sdr => jtag_state_sdr,
      state_udr => jtag_state_udr, state_uir => jtag_state_uir,
      cmd_tog => cmd_tog, op => d_op, be => d_be, addr => d_addr, data => d_data,
      done_tog => done_tog, rsp_addr => r_addr, rsp_data => r_data, rsp_status => r_status
    );

  u_dbg : entity work.sdram_dbg_master
    port map (
      clk => clk_mem, rst => rst_mem,
      cmd_tog => cmd_tog, done_tog => done_tog, op => d_op, be => d_be, addr => d_addr, data => d_data,
      rsp_addr => r_addr, rsp_data => r_data, rsp_status => r_status,
      init_done => init_i,
      b_req_tog => b_req, b_ack_tog => b_ack, b_we => b_we, b_addr => b_addr,
      b_wdata => b_wdata, b_be => b_be, b_rdata => b_rdata
    );

  u_arb : entity work.sdram_arbiter
    port map (
      clk => clk_mem, rst => rst_mem,
      a_req_tog => a_req, a_ack_tog => a_ack, a_we => a_we, a_addr => a_addr,
      a_wdata => a_wdata, a_be => a_be, a_rdata => a_rdata,
      b_req_tog => b_req, b_ack_tog => b_ack, b_we => b_we, b_addr => b_addr,
      b_wdata => b_wdata, b_be => b_be, b_rdata => b_rdata,
      c_req_tog => req_tog, c_ack_tog => ack_tog, c_we => c_we, c_addr => c_addr,
      c_wdata => c_wdata, c_be => c_be, c_rdata => c_rdata
    );

  u_ctrl : entity work.sdram_ctrl
    generic map (TCK_PS => TCK_PS, INIT_CYCLES => INIT_CYCLES, REFRESH_CYCLES => REFRESH_CYCLES,
                 SYNC_REQ => false)
    port map (
      clk => clk_mem, rst => rst_mem,
      req_tog => req_tog, ack_tog => ack_tog, init_done => init_i,
      we => c_we, addr => c_addr, wdata => c_wdata, be => c_be, rdata => c_rdata,
      dram_cke => cke, dram_cs_n => cs_n, dram_ras_n => ras_n, dram_cas_n => cas_n,
      dram_we_n => we_n, dram_ba => ba, dram_addr => a, dram_dqm => dqm,
      dram_dq_out => dq_out, dram_dq_oe => dq_oe, dram_dq_in => dq
    );

  -- the pins: the controller drives them with its output enable, the model otherwise
  dq <= dq_out when dq_oe = '1' else (others => 'Z');

  u_chip : entity work.sdram_model
    generic map (TCK_PS => TCK_PS)
    port map (
      clk => clk_mem, cke => cke, cs_n => cs_n, ras_n => ras_n, cas_n => cas_n,
      we_n => we_n, ba => ba, a => a, dqm => dqm, dq => dq, reinit => rst_mem,
      dbg_word_addr => dbg_word_addr, dbg_word_data => dbg_word_data,
      dbg_flip => dbg_flip, dbg_flip_addr => dbg_flip_addr, dbg_flip_bit => dbg_flip_bit,
      dbg_refreshes => dbg_refreshes, dbg_init_ok => dbg_init_ok
    );

end architecture sim;
