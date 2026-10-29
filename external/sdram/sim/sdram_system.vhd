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
    REFRESH_CYCLES : natural := cycles(T_REFI_PS, T_CK_PS) * 9 / 10;
    INIT_FILE      : string  := ""
  );
  port (
    i_clk_mem     : in  std_logic;
    i_clk_cpu     : in  std_logic;
    i_rst_mem     : in  std_logic;
    i_rst_cpu     : in  std_logic;

    i_addr        : in  std_logic_vector(31 downto 0);
    i_wdata       : in  std_logic_vector(31 downto 0);
    i_byteena     : in  std_logic_vector(3 downto 0);
    i_rden        : in  std_logic;
    i_wren        : in  std_logic;
    i_mem_advance : in  std_logic;
    o_ready       : out std_logic;
    o_rdata       : out std_logic_vector(31 downto 0);
    i_line        : in  std_logic := '0';
    i_wdata_x     : in  std_logic_vector(95 downto 0) := (others => '0');
    i_byteena_x   : in  std_logic_vector(11 downto 0) := (others => '0');
    o_rdata_x     : out std_logic_vector(95 downto 0);

    -- the core's instruction bridge (master I of the arbiter); idle when rden stays low
    i_ins_addr      : in  std_logic_vector(31 downto 0) := (others => '0');
    i_ins_rden      : in  std_logic := '0';
    i_ins_advance   : in  std_logic := '0';
    o_ins_ready     : out std_logic;
    o_ins_rdata     : out std_logic_vector(31 downto 0);
    i_ins_line      : in  std_logic := '0';
    o_ins_rdata_x   : out std_logic_vector(95 downto 0);

    o_init_done       : out std_logic;
    i_dbg_word_addr   : in  std_logic_vector(23 downto 0);
    o_dbg_word_data   : out std_logic_vector(31 downto 0);
    i_dbg_flip        : in  std_logic;
    i_dbg_flip_addr   : in  std_logic_vector(23 downto 0);
    i_dbg_flip_bit    : in  std_logic_vector(4 downto 0);
    o_dbg_refreshes   : out std_logic_vector(31 downto 0);
    o_dbg_init_ok     : out std_logic;

    i_jtag_tck        : in  std_logic := '0';
    i_jtag_tdi        : in  std_logic := '0';
    o_jtag_tdo        : out std_logic;
    i_jtag_ir_in      : in  std_logic_vector(1 downto 0) := "00";
    i_jtag_state_cdr  : in  std_logic := '0';
    i_jtag_state_sdr  : in  std_logic := '0';
    i_jtag_state_udr  : in  std_logic := '0';
    i_jtag_state_uir  : in  std_logic := '0'
  );
end entity sdram_system;

architecture sim of sdram_system is
  signal req_tog, ack_tog, init_i, c_we : std_logic;
  signal c_addr  : std_logic_vector(23 downto 0);
  signal c_wdata, c_rdata : std_logic_vector(31 downto 0);
  signal c_line  : std_logic;
  signal c_wdx, c_rdx : std_logic_vector(95 downto 0);
  signal c_bex   : std_logic_vector(11 downto 0);
  signal a_line  : std_logic;
  signal a_wdx, a_rdx : std_logic_vector(95 downto 0);
  signal a_bex   : std_logic_vector(11 downto 0);
  signal c_be    : std_logic_vector(3 downto 0);

  -- master A (the core's bridge) and master B (the debug master) of the arbiter
  signal a_req, a_ack, a_we : std_logic;
  signal a_addr  : std_logic_vector(23 downto 0);
  signal a_wdata, a_rdata : std_logic_vector(31 downto 0);
  signal a_be    : std_logic_vector(3 downto 0);
  signal i_req, i_ack, i_we : std_logic;
  signal i_caddr  : std_logic_vector(23 downto 0);
  signal i_cwdata, i_crdata : std_logic_vector(31 downto 0);
  signal i_cbe    : std_logic_vector(3 downto 0);
  signal i_cline  : std_logic;
  signal i_cwdx, i_crdx : std_logic_vector(95 downto 0);
  signal i_cbex   : std_logic_vector(11 downto 0);
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

  o_init_done <= init_i;

  u_bridge : entity work.sdram_cpu_bridge
    port map (
      i_clk_cpu => i_clk_cpu, i_rst_cpu => i_rst_cpu,
      i_addr => i_addr, i_wdata => i_wdata, i_byteena => i_byteena, i_rden => i_rden, i_wren => i_wren,
      i_mem_advance => i_mem_advance, o_ready => o_ready, o_rdata => o_rdata,
      i_line => i_line, i_wdata_x => i_wdata_x, i_byteena_x => i_byteena_x, o_rdata_x => o_rdata_x,
      o_req_tog => a_req, i_ack_tog => a_ack, i_init_done => init_i,
      o_c_we => a_we, o_c_addr => a_addr, o_c_wdata => a_wdata, o_c_be => a_be, i_c_rdata => a_rdata,
      o_c_line => a_line, o_c_wdata_x => a_wdx, o_c_be_x => a_bex, i_c_rdata_x => a_rdx
    );

  u_ibridge : entity work.sdram_cpu_bridge
    port map (
      i_clk_cpu => i_clk_cpu, i_rst_cpu => i_rst_cpu,
      i_addr => i_ins_addr, i_wdata => (others => '0'), i_byteena => (others => '0'), i_rden => i_ins_rden, i_wren => '0',
      i_mem_advance => i_ins_advance, o_ready => o_ins_ready, o_rdata => o_ins_rdata,
      i_line => i_ins_line, i_wdata_x => (others => '0'), i_byteena_x => (others => '0'), o_rdata_x => o_ins_rdata_x,
      o_req_tog => i_req, i_ack_tog => i_ack, i_init_done => init_i,
      o_c_we => i_we, o_c_addr => i_caddr, o_c_wdata => i_cwdata, o_c_be => i_cbe, i_c_rdata => i_crdata,
      o_c_line => i_cline, o_c_wdata_x => i_cwdx, o_c_be_x => i_cbex, i_c_rdata_x => i_crdx
    );

  u_jtag : entity work.sdram_jtag_core
    port map (
      i_tck => i_jtag_tck, i_tdi => i_jtag_tdi, o_tdo => o_jtag_tdo, i_ir_in => i_jtag_ir_in,
      i_state_cdr => i_jtag_state_cdr, i_state_sdr => i_jtag_state_sdr,
      i_state_udr => i_jtag_state_udr, i_state_uir => i_jtag_state_uir,
      o_cmd_tog => cmd_tog, o_op => d_op, o_be => d_be, o_addr => d_addr, o_data => d_data,
      i_done_tog => done_tog, i_rsp_addr => r_addr, i_rsp_data => r_data, i_rsp_status => r_status
    );

  u_dbg : entity work.sdram_dbg_master
    port map (
      i_clk => i_clk_mem, i_rst => i_rst_mem,
      i_cmd_tog => cmd_tog, o_done_tog => done_tog, i_op => d_op, i_be => d_be, i_addr => d_addr, i_data => d_data,
      o_rsp_addr => r_addr, o_rsp_data => r_data, o_rsp_status => r_status,
      i_init_done => init_i,
      o_b_req_tog => b_req, i_b_ack_tog => b_ack, o_b_we => b_we, o_b_addr => b_addr,
      o_b_wdata => b_wdata, o_b_be => b_be, i_b_rdata => b_rdata
    );

  u_arb : entity work.sdram_arbiter
    port map (
      i_clk => i_clk_mem, i_rst => i_rst_mem,
      i_a_req_tog => a_req, o_a_ack_tog => a_ack, i_a_we => a_we, i_a_addr => a_addr,
      i_a_wdata => a_wdata, i_a_be => a_be, o_a_rdata => a_rdata,
      i_a_line => a_line, i_a_wdata_x => a_wdx, i_a_be_x => a_bex, o_a_rdata_x => a_rdx,
      i_ins_req_tog => i_req, o_ins_ack_tog => i_ack, i_ins_we => i_we, i_ins_addr => i_caddr,
      i_ins_wdata => i_cwdata, i_ins_be => i_cbe, o_ins_rdata => i_crdata,
      i_ins_line => i_cline, i_ins_wdata_x => i_cwdx, i_ins_be_x => i_cbex, o_ins_rdata_x => i_crdx,
      i_b_req_tog => b_req, o_b_ack_tog => b_ack, i_b_we => b_we, i_b_addr => b_addr,
      i_b_wdata => b_wdata, i_b_be => b_be, o_b_rdata => b_rdata,
      o_c_req_tog => req_tog, i_c_ack_tog => ack_tog, o_c_we => c_we, o_c_addr => c_addr,
      o_c_wdata => c_wdata, o_c_be => c_be, i_c_rdata => c_rdata,
      o_c_line => c_line, o_c_wdata_x => c_wdx, o_c_be_x => c_bex, i_c_rdata_x => c_rdx
    );

  u_ctrl : entity work.sdram_ctrl
    generic map (TCK_PS => TCK_PS, INIT_CYCLES => INIT_CYCLES, REFRESH_CYCLES => REFRESH_CYCLES,
                 SYNC_REQ => false)
    port map (
      i_clk => i_clk_mem, i_rst => i_rst_mem,
      i_req_tog => req_tog, o_ack_tog => ack_tog, o_init_done => init_i,
      i_we => c_we, i_addr => c_addr, i_wdata => c_wdata, i_be => c_be, o_rdata => c_rdata,
      i_line => c_line, i_wdata_x => c_wdx, i_be_x => c_bex, o_rdata_x => c_rdx,
      o_dram_cke => cke, o_dram_cs_n => cs_n, o_dram_ras_n => ras_n, o_dram_cas_n => cas_n,
      o_dram_we_n => we_n, o_dram_ba => ba, o_dram_addr => a, o_dram_dqm => dqm,
      o_dram_dq_out => dq_out, o_dram_dq_oe => dq_oe, i_dram_dq_in => dq
    );

  -- the pins: the controller drives them with its output enable, the model otherwise
  dq <= dq_out when dq_oe = '1' else (others => 'Z');

  u_chip : entity work.sdram_model
    generic map (TCK_PS => TCK_PS, INIT_FILE => INIT_FILE)
    port map (
      i_clk => i_clk_mem, i_cke => cke, i_cs_n => cs_n, i_ras_n => ras_n, i_cas_n => cas_n,
      i_we_n => we_n, i_ba => ba, i_a => a, i_dqm => dqm, io_dq => dq, i_reinit => i_rst_mem,
      i_dbg_word_addr => i_dbg_word_addr, o_dbg_word_data => o_dbg_word_data,
      i_dbg_flip => i_dbg_flip, i_dbg_flip_addr => i_dbg_flip_addr, i_dbg_flip_bit => i_dbg_flip_bit,
      o_dbg_refreshes => o_dbg_refreshes, o_dbg_init_ok => o_dbg_init_ok
    );

end architecture sim;
