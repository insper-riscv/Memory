library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;

-- Simulation top: the self test straight on the controller and the chip model,
-- on one clock (the bring-up configuration of the board).
entity sdram_bist_system is
  generic (
    WINDOW_LOG2 : natural := 8;
    SWEEP_LOG2  : natural := 10;
    RANDOM_LOG2 : natural := 8;
    CAPTURE_EXTRA : natural := 0
  );
  port (
    i_clk        : in  std_logic;
    i_rst        : in  std_logic;
    i_start      : in  std_logic;
    i_mode       : in  std_logic_vector(1 downto 0);
    o_init_done  : out std_logic;
    o_busy, o_done, o_fail, o_timeout : out std_logic;
    o_phase      : out std_logic_vector(4 downto 0);
    o_err_count  : out std_logic_vector(31 downto 0);
    o_first_addr : out std_logic_vector(23 downto 0);
    o_first_exp  : out std_logic_vector(31 downto 0);
    o_first_got  : out std_logic_vector(31 downto 0);
    o_ops_done   : out std_logic_vector(31 downto 0);

    i_dbg_word_addr : in  std_logic_vector(23 downto 0);
    o_dbg_word_data : out std_logic_vector(31 downto 0);
    i_dbg_flip      : in  std_logic;
    i_dbg_flip_addr : in  std_logic_vector(23 downto 0);
    i_dbg_flip_bit  : in  std_logic_vector(4 downto 0);
    o_dbg_refreshes : out std_logic_vector(31 downto 0)
  );
end entity sdram_bist_system;

architecture sim of sdram_bist_system is
  signal req_tog, ack_tog, init_i, c_we : std_logic;
  signal c_addr  : std_logic_vector(23 downto 0);
  signal c_wdata, c_rdata : std_logic_vector(31 downto 0);
  signal c_be    : std_logic_vector(3 downto 0);
  signal cke, cs_n, ras_n, cas_n, we_n : std_logic;
  signal ba   : std_logic_vector(1 downto 0);
  signal a    : std_logic_vector(12 downto 0);
  signal dqm  : std_logic_vector(1 downto 0);
  signal dq, dq_out : std_logic_vector(15 downto 0);
  signal dq_oe : std_logic;
  signal dq_in_r : std_logic_vector(15 downto 0);
  signal init_ok : std_logic;
begin

  o_init_done <= init_i;

  u_bist : entity work.sdram_bist
    generic map (WINDOW_LOG2 => WINDOW_LOG2, SWEEP_LOG2 => SWEEP_LOG2, RANDOM_LOG2 => RANDOM_LOG2)
    port map (
      i_clk => i_clk, i_rst => i_rst, i_start => i_start, i_mode => i_mode, i_init_done => init_i,
      o_busy => o_busy, o_done => o_done, o_fail => o_fail, o_timeout => o_timeout, o_phase => o_phase,
      o_err_count => o_err_count, o_first_addr => o_first_addr, o_first_exp => o_first_exp,
      o_first_got => o_first_got, o_ops_done => o_ops_done,
      o_c_req_tog => req_tog, i_c_ack_tog => ack_tog, o_c_we => c_we, o_c_addr => c_addr,
      o_c_wdata => c_wdata, o_c_be => c_be, i_c_rdata => c_rdata
    );

  u_ctrl : entity work.sdram_ctrl
    generic map (CAPTURE_EXTRA => CAPTURE_EXTRA)
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_req_tog => req_tog, o_ack_tog => ack_tog, o_init_done => init_i,
      i_we => c_we, i_addr => c_addr, i_wdata => c_wdata, i_be => c_be, o_rdata => c_rdata,
      o_dram_cke => cke, o_dram_cs_n => cs_n, o_dram_ras_n => ras_n, o_dram_cas_n => cas_n,
      o_dram_we_n => we_n, o_dram_ba => ba, o_dram_addr => a, o_dram_dqm => dqm,
      o_dram_dq_out => dq_out, o_dram_dq_oe => dq_oe, i_dram_dq_in => dq_in_r
    );

  dq <= dq_out when dq_oe = '1' else (others => 'Z');

  -- the pins are registered once on the way in, as the board's IO cells do
  gen_registered : if CAPTURE_EXTRA = 1 generate
    process (i_clk)
    begin
      if rising_edge(i_clk) then
        dq_in_r <= dq;
      end if;
    end process;
  end generate;
  gen_direct : if CAPTURE_EXTRA = 0 generate
    dq_in_r <= dq;
  end generate;

  u_chip : entity work.sdram_model
    port map (
      i_clk => i_clk, i_cke => cke, i_cs_n => cs_n, i_ras_n => ras_n, i_cas_n => cas_n,
      i_we_n => we_n, i_ba => ba, i_a => a, i_dqm => dqm, io_dq => dq, i_reinit => i_rst,
      i_dbg_word_addr => i_dbg_word_addr, o_dbg_word_data => o_dbg_word_data,
      i_dbg_flip => i_dbg_flip, i_dbg_flip_addr => i_dbg_flip_addr, i_dbg_flip_bit => i_dbg_flip_bit,
      o_dbg_refreshes => o_dbg_refreshes, o_dbg_init_ok => init_ok
    );

end architecture sim;
