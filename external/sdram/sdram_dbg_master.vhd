library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- The debug master: reads and writes words of the SDRAM on behalf of the host, through the
-- arbiter, on the controller clock. A command is a flip of cmd_tog (any clock, synchronized
-- here) with op/be/addr/data holding from the flip until the answer, a flip of done_tog; the
-- result (rsp_*) is stable from before that flip until the next command is accepted.
--
-- Commands (op):
--   0  nothing
--   1  read the word at addr
--   2  write data to the word at addr, bytes by be
--   3  fill count words from addr with data (all bytes); count is set by op 4
--   4  set the count of op 3 to data(23:0)
--   5  read the word after the one accessed last
--   6  write data to the word after the one accessed last, bytes by be
--
-- rsp_addr is the word accessed last, rsp_data what a read returned, rsp_status:
-- bit 1 the controller did not answer (the command was dropped), bit 2 the SDRAM is initialized.
entity sdram_dbg_master is
  generic (
    -- clocks to wait for the arbiter before a command is declared lost
    TIMEOUT_CYCLES : natural := 1 * 2**16
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;  -- synchronous, active high

    cmd_tog    : in  std_logic;
    done_tog   : out std_logic;
    op         : in  std_logic_vector(3 downto 0);
    be         : in  std_logic_vector(3 downto 0);
    addr       : in  std_logic_vector(23 downto 0);
    data       : in  std_logic_vector(31 downto 0);
    rsp_addr   : out std_logic_vector(23 downto 0);
    rsp_data   : out std_logic_vector(31 downto 0);
    rsp_status : out std_logic_vector(7 downto 0);

    init_done  : in  std_logic;

    -- master B of sdram_arbiter
    b_req_tog  : out std_logic;
    b_ack_tog  : in  std_logic;
    b_we       : out std_logic;
    b_addr     : out std_logic_vector(23 downto 0);
    b_wdata    : out std_logic_vector(31 downto 0);
    b_be       : out std_logic_vector(3 downto 0);
    b_rdata    : in  std_logic_vector(31 downto 0)
  );
end entity sdram_dbg_master;

architecture rtl of sdram_dbg_master is

  type state_t is (ST_IDLE, ST_WAIT, ST_NEXT);
  signal st : state_t := ST_IDLE;

  signal cmd_s    : std_logic_vector(1 downto 0) := "00";
  signal done_i   : std_logic := '0';
  signal req_i    : std_logic := '0';
  signal pending  : std_logic;

  signal op_l     : std_logic_vector(3 downto 0) := (others => '0');
  signal be_l     : std_logic_vector(3 downto 0) := (others => '0');
  signal data_l   : std_logic_vector(31 downto 0) := (others => '0');
  signal cur_addr : unsigned(23 downto 0) := (others => '0');   -- the word being accessed
  signal last     : unsigned(23 downto 0) := (others => '0');   -- the word accessed last
  signal count    : unsigned(23 downto 0) := (others => '0');   -- count set for op 3
  signal left     : unsigned(23 downto 0) := (others => '0');   -- words of a fill still to write
  signal wcnt     : natural range 0 to TIMEOUT_CYCLES := 0;
  signal err      : std_logic := '0';
  signal init_s   : std_logic_vector(1 downto 0) := "00";
  signal rdata_i  : std_logic_vector(31 downto 0) := (others => '0');

begin

  done_tog   <= done_i;
  b_req_tog  <= req_i;
  rsp_addr   <= std_logic_vector(last);
  rsp_data   <= rdata_i;
  rsp_status <= "00000" & init_s(1) & err & '0';
  pending    <= '1' when cmd_s(1) /= done_i else '0';

  process (clk)
    procedure issue (a : unsigned(23 downto 0); we : std_logic; d : std_logic_vector(31 downto 0);
                     b : std_logic_vector(3 downto 0)) is
    begin
      b_addr  <= std_logic_vector(a);
      b_we    <= we;
      b_wdata <= d;
      b_be    <= b;
      cur_addr <= a;
      req_i   <= not req_i;
      wcnt    <= 0;
      st      <= ST_WAIT;
    end procedure;
  begin
    if rising_edge(clk) then
      cmd_s  <= cmd_s(0) & cmd_tog;
      init_s <= init_s(0) & init_done;

      if rst = '1' then
        st     <= ST_IDLE;
        cmd_s  <= "00";
        done_i <= '0';
        req_i  <= '0';
        err    <= '0';
        last   <= (others => '0');
        count  <= to_unsigned(1, 24);
        init_s <= "00";
      else
        case st is

          when ST_IDLE =>
            if pending = '1' then
              -- the command buses are stable from the flip of cmd_tog on
              op_l   <= op;
              be_l   <= be;
              data_l <= data;
              err    <= '0';
              case op is
                when "0001" =>
                  issue(unsigned(addr), '0', (others => '0'), "1111");
                when "0010" =>
                  issue(unsigned(addr), '1', data, be);
                when "0011" =>
                  if count = 0 then
                    done_i <= cmd_s(1);
                  else
                    left <= count - 1;
                    issue(unsigned(addr), '1', data, "1111");
                  end if;
                when "0100" =>
                  count  <= unsigned(data(23 downto 0));
                  done_i <= cmd_s(1);
                when "0101" =>
                  issue(last + 1, '0', (others => '0'), "1111");
                when "0110" =>
                  issue(last + 1, '1', data, be);
                when others =>
                  done_i <= cmd_s(1);
              end case;
            end if;

          when ST_WAIT =>
            if b_ack_tog = req_i then
              last    <= cur_addr;
              rdata_i <= b_rdata;
              st      <= ST_NEXT;
            elsif wcnt = TIMEOUT_CYCLES then
              err    <= '1';
              done_i <= cmd_s(1);
              st     <= ST_IDLE;
            else
              wcnt <= wcnt + 1;
            end if;

          when ST_NEXT =>
            if op_l = "0011" and left /= 0 then
              left <= left - 1;
              issue(cur_addr + 1, '1', data_l, "1111");
            else
              done_i <= cmd_s(1);
              st     <= ST_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
