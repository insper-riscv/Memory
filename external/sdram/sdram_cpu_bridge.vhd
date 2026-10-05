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
-- Controller side: one request is a flip of req_tog with the word on c_we/c_addr/
-- c_wdata/c_be; the controller answers by flipping ack_tog. ack_tog and
-- init_done come from the controller's clock and are synchronized here with two
-- flip-flops. The request buses change on the same edge that flips req_tog and
-- hold until ack_tog flips; the controller samples them only after it has seen
-- the flip, so they need a data-path-only delay constraint (shorter than the
-- synchronizer latency), not synchronizers.
entity sdram_cpu_bridge is
  port (
    clk_cpu     : in  std_logic;
    rst_cpu     : in  std_logic;  -- synchronous, active high

    -- core side
    addr        : in  std_logic_vector(31 downto 0);
    wdata       : in  std_logic_vector(31 downto 0);
    byteena     : in  std_logic_vector(3 downto 0);
    rden        : in  std_logic;
    wren        : in  std_logic;
    mem_advance : in  std_logic;
    ready       : out std_logic;
    rdata       : out std_logic_vector(31 downto 0);

    -- controller side
    req_tog     : out std_logic;
    ack_tog     : in  std_logic;
    init_done   : in  std_logic;
    c_we        : out std_logic;
    c_addr      : out std_logic_vector(23 downto 0);
    c_wdata     : out std_logic_vector(31 downto 0);
    c_be        : out std_logic_vector(3 downto 0);
    c_rdata     : in  std_logic_vector(31 downto 0)
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

begin

  req_tog <= req_i;
  c_we    <= we_l;
  ready   <= '1' when st = ST_DONE else '0';
  rdata   <= rdata_q;

  process (clk_cpu)
  begin
    if rising_edge(clk_cpu) then
      ack_s  <= ack_s(0) & ack_tog;
      init_s <= init_s(0) & init_done;

      if rst_cpu = '1' then
        st      <= ST_IDLE;
        req_i   <= '0';
        ack_s   <= "00";
        init_s  <= "00";
        we_l    <= '0';
      else
        case st is

          when ST_IDLE =>
            if (rden = '1' or wren = '1') and init_s(1) = '1' then
              c_addr  <= addr(25 downto 2);
              c_wdata <= wdata;
              c_be    <= byteena;
              we_l    <= wren;
              req_i   <= not req_i;
              st      <= ST_WAIT;
            end if;

          when ST_WAIT =>
            if ack_s(1) = req_i then
              pending <= c_rdata;
              st      <= ST_DONE;
            end if;

          when ST_DONE =>
            if mem_advance = '1' then
              if we_l = '0' then
                rdata_q <= pending;
              end if;
              st <= ST_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
