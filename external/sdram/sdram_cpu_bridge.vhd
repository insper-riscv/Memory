library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Bridge between the core (clk_cpu) and the SDRAM controller (another clock).
--
-- Core side: the access sits on addr/wdata/byteena/rden/wren while the memory
-- stage is stopped. ready goes high when the access is done and stays high, as a
-- level, until mem_advance says the pipeline moved. The read data (rdata) only
-- changes on that same edge, because the load that is still in the write-back
-- stage reads the previous value until then.
--
-- A line access (line = 1 with rden or wren) moves the four words that start at addr (aligned to 16
-- bytes): word 0 on wdata/byteena/rdata as for a word, words 1 to 3 on wdata_x/byteena_x/rdata_x
-- (32 bits each, word 1 in the lowest bits). The same rules hold for the extra words.
--
-- Controller side: one request is a flip of req_tog with the word on c_we/c_addr/
-- c_wdata/c_be; the controller answers by flipping ack_tog. ack_tog and
-- init_done come from the controller's clock and are synchronized here with two
-- flip-flops. The request buses change on the same edge that flips req_tog and
-- hold until ack_tog flips; the controller samples them only after it has seen
-- the flip, so they need a data-path-only delay constraint (shorter than the
-- synchronizer latency), not synchronizers.
entity sdram_cpu_bridge is
  port (
    i_clk_cpu     : in  std_logic;
    i_rst_cpu     : in  std_logic;  -- synchronous, active high

    -- core side
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

    -- controller side
    o_req_tog     : out std_logic;
    i_ack_tog     : in  std_logic;
    i_init_done   : in  std_logic;
    o_c_we        : out std_logic;
    o_c_addr      : out std_logic_vector(23 downto 0);
    o_c_wdata     : out std_logic_vector(31 downto 0);
    o_c_be        : out std_logic_vector(3 downto 0);
    i_c_rdata     : in  std_logic_vector(31 downto 0);
    o_c_line      : out std_logic;
    o_c_wdata_x   : out std_logic_vector(95 downto 0);
    o_c_be_x      : out std_logic_vector(11 downto 0);
    i_c_rdata_x   : in  std_logic_vector(95 downto 0)
  );
end entity sdram_cpu_bridge;

architecture rtl of sdram_cpu_bridge is

  type state_t is (ST_IDLE, ST_WAIT, ST_DONE);
  signal st : state_t := ST_IDLE;

  signal req_i       : std_logic := '0';
  signal ack_s       : std_logic_vector(1 downto 0) := "00";
  signal init_s      : std_logic_vector(1 downto 0) := "00";
  signal we_l        : std_logic := '0';
  signal pending     : std_logic_vector(31 downto 0) := (others => '0');
  signal rdata_q     : std_logic_vector(31 downto 0) := (others => '0');
  signal pending_x   : std_logic_vector(95 downto 0) := (others => '0');
  signal rdx_q       : std_logic_vector(95 downto 0) := (others => '0');
  signal line_l      : std_logic := '0';

begin

  o_req_tog <= req_i;
  o_c_we    <= we_l;
  o_ready   <= '1' when st = ST_DONE else '0';
  o_rdata   <= rdata_q;
  o_rdata_x <= rdx_q;
  o_c_line  <= line_l;

  process (i_clk_cpu)
  begin
    if rising_edge(i_clk_cpu) then
      ack_s  <= ack_s(0) & i_ack_tog;
      init_s <= init_s(0) & i_init_done;

      if i_rst_cpu = '1' then
        st      <= ST_IDLE;
        req_i   <= '0';
        ack_s   <= "00";
        init_s  <= "00";
        we_l    <= '0';
      else
        case st is

          when ST_IDLE =>
            if (i_rden = '1' or i_wren = '1') and init_s(1) = '1' then
              o_c_addr  <= i_addr(25 downto 2);
              o_c_wdata <= i_wdata;
              o_c_be    <= i_byteena;
              line_l    <= i_line;
              o_c_wdata_x <= i_wdata_x;
              o_c_be_x    <= i_byteena_x;
              we_l    <= i_wren;
              req_i   <= not req_i;
              st      <= ST_WAIT;
            end if;

          when ST_WAIT =>
            if ack_s(1) = req_i then
              pending   <= i_c_rdata;
              pending_x <= i_c_rdata_x;
              st        <= ST_DONE;
            end if;

          when ST_DONE =>
            if i_mem_advance = '1' then
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
