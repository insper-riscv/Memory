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
    clk        : in  std_logic;
    rst        : in  std_logic;
    start      : in  std_logic;
    mode       : in  std_logic_vector(1 downto 0);
    init_done  : out std_logic;
    busy, done, fail, timeout : out std_logic;
    phase      : out std_logic_vector(4 downto 0);
    err_count  : out std_logic_vector(31 downto 0);
    first_addr : out std_logic_vector(23 downto 0);
    first_exp  : out std_logic_vector(31 downto 0);
    first_got  : out std_logic_vector(31 downto 0);
    ops_done   : out std_logic_vector(31 downto 0);

    dbg_word_addr : in  std_logic_vector(23 downto 0);
    dbg_word_data : out std_logic_vector(31 downto 0);
    dbg_flip      : in  std_logic;
    dbg_flip_addr : in  std_logic_vector(23 downto 0);
    dbg_flip_bit  : in  std_logic_vector(4 downto 0);
    dbg_refreshes : out std_logic_vector(31 downto 0)
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

  init_done <= init_i;

  u_bist : entity work.sdram_bist
    generic map (WINDOW_LOG2 => WINDOW_LOG2, SWEEP_LOG2 => SWEEP_LOG2, RANDOM_LOG2 => RANDOM_LOG2)
    port map (
      clk => clk, rst => rst, start => start, mode => mode, init_done => init_i,
      busy => busy, done => done, fail => fail, timeout => timeout, phase => phase,
      err_count => err_count, first_addr => first_addr, first_exp => first_exp,
      first_got => first_got, ops_done => ops_done,
      c_req_tog => req_tog, c_ack_tog => ack_tog, c_we => c_we, c_addr => c_addr,
      c_wdata => c_wdata, c_be => c_be, c_rdata => c_rdata
    );

  u_ctrl : entity work.sdram_ctrl
    generic map (CAPTURE_EXTRA => CAPTURE_EXTRA)
    port map (
      clk => clk, rst => rst,
      req_tog => req_tog, ack_tog => ack_tog, init_done => init_i,
      we => c_we, addr => c_addr, wdata => c_wdata, be => c_be, rdata => c_rdata,
      dram_cke => cke, dram_cs_n => cs_n, dram_ras_n => ras_n, dram_cas_n => cas_n,
      dram_we_n => we_n, dram_ba => ba, dram_addr => a, dram_dqm => dqm,
      dram_dq_out => dq_out, dram_dq_oe => dq_oe, dram_dq_in => dq_in_r
    );

  dq <= dq_out when dq_oe = '1' else (others => 'Z');

  -- the pins are registered once on the way in, as the board's IO cells do
  gen_registered : if CAPTURE_EXTRA = 1 generate
    process (clk)
    begin
      if rising_edge(clk) then
        dq_in_r <= dq;
      end if;
    end process;
  end generate;
  gen_direct : if CAPTURE_EXTRA = 0 generate
    dq_in_r <= dq;
  end generate;

  u_chip : entity work.sdram_model
    port map (
      clk => clk, cke => cke, cs_n => cs_n, ras_n => ras_n, cas_n => cas_n,
      we_n => we_n, ba => ba, a => a, dqm => dqm, dq => dq, reinit => rst,
      dbg_word_addr => dbg_word_addr, dbg_word_data => dbg_word_data,
      dbg_flip => dbg_flip, dbg_flip_addr => dbg_flip_addr, dbg_flip_bit => dbg_flip_bit,
      dbg_refreshes => dbg_refreshes, dbg_init_ok => init_ok
    );

end architecture sim;
