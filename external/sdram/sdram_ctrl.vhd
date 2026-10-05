library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;

-- Controller of the 32M x 16 SDR SDRAM. One request moves one 32-bit word as a
-- burst of two 16-bit beats. Closed-page policy: every access activates its row
-- and reads or writes with auto-precharge, so no row is left open and the
-- command order never depends on the previous access.
--
-- Request interface (a toggle handshake, so it crosses clock domains safely):
-- the requester sets we/addr/wdata/be, then flips req_tog; the controller flips
-- ack_tog when the word has moved (read data valid in rdata, or write data given
-- to the chip). we/addr/wdata/be must hold from the flip of req_tog until the
-- flip of ack_tog. req_tog is synchronized here, so it may come from another clock.
--
-- addr is the 32-bit word address: row (13) & bank (2) & column (9).
entity sdram_ctrl is
  generic (
    TCK_PS         : natural := T_CK_PS;
    -- cycles waited after power-up before the first command, and between two
    -- refreshes: overridable for short simulations
    INIT_CYCLES    : natural := cycles(T_INIT_PS, T_CK_PS);
    REFRESH_CYCLES : natural := cycles(T_REFI_PS, T_CK_PS) * 9 / 10;
    -- extra clocks before the read data is sampled (board and clock phase tuning)
    CAPTURE_EXTRA  : natural := 0
  );
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;  -- synchronous, active high

    req_tog   : in  std_logic;
    ack_tog   : out std_logic;
    init_done : out std_logic;
    we        : in  std_logic;
    addr      : in  std_logic_vector(23 downto 0);
    wdata     : in  std_logic_vector(31 downto 0);
    be        : in  std_logic_vector(3 downto 0);
    rdata     : out std_logic_vector(31 downto 0);

    dram_cke   : out std_logic;
    dram_cs_n  : out std_logic;
    dram_ras_n : out std_logic;
    dram_cas_n : out std_logic;
    dram_we_n  : out std_logic;
    dram_ba    : out std_logic_vector(1 downto 0);
    dram_addr  : out std_logic_vector(12 downto 0);
    dram_dqm   : out std_logic_vector(1 downto 0);
    dram_dq_out : out std_logic_vector(15 downto 0);
    dram_dq_oe  : out std_logic;
    dram_dq_in  : in  std_logic_vector(15 downto 0)
  );
end entity sdram_ctrl;

architecture rtl of sdram_ctrl is

  -- (the VHDL-2008 maximum is not accepted by Quartus)
  function larger (a, b : natural) return natural is
  begin
    if a > b then
      return a;
    end if;
    return b;
  end function;

  constant C_RCD : natural := cycles(T_RCD_PS, TCK_PS);
  constant C_RP  : natural := cycles(T_RP_PS, TCK_PS);
  constant C_RC  : natural := cycles(T_RC_PS, TCK_PS);
  constant C_RFC : natural := cycles(T_RFC_PS, TCK_PS);
  constant C_WR  : natural := cycles(T_WR_PS, TCK_PS);
  -- ACTIVE to the next ACTIVE of a closed-page access: the longer of tRC and
  -- the read path (ACTIVE, tRCD, CAS latency, two beats, one clock of margin);
  -- the write path (tRCD, two beats, tWR, tRP) is never longer than the read path.
  constant ACT_TO_ACT : natural :=
    larger(C_RC, larger(C_RCD + CAS_LATENCY + 4, C_RCD + 2 + C_WR + C_RP));

  type state_t is (ST_INIT_WAIT, ST_INIT_PRE, ST_INIT_REF, ST_INIT_MRS, ST_WAIT,
                   ST_IDLE, ST_RW, ST_READ, ST_WRITE2);
  signal st  : state_t := ST_INIT_WAIT;
  signal nxt : state_t := ST_INIT_WAIT;

  signal wcnt     : natural range 0 to 2**18 - 1 := 0;
  signal act_cnt  : natural range 0 to 63 := 0;     -- clocks until the next ACTIVE is allowed
  signal ref_cnt  : natural range 0 to 2**14 - 1 := 0;
  signal ref_due  : std_logic := '0';
  signal init_ref : natural range 0 to INIT_REFRESHES := 0;

  signal req_s    : std_logic_vector(1 downto 0) := "00";
  signal ack_i    : std_logic := '0';
  signal tog_l    : std_logic := '0';  -- the toggle of the request in service

  signal we_l     : std_logic := '0';
  signal addr_l   : std_logic_vector(23 downto 0) := (others => '0');
  signal wdata_l  : std_logic_vector(31 downto 0) := (others => '0');
  signal be_l     : std_logic_vector(3 downto 0) := (others => '0');
  signal rd_t     : natural range 0 to 15 := 0;      -- clocks since the READ command
  signal rdata_i  : std_logic_vector(31 downto 0) := (others => '0');
  signal init_i   : std_logic := '0';

begin

  ack_tog   <= ack_i;
  init_done <= init_i;
  rdata     <= rdata_i;
  dram_cke  <= '1';

  process (clk)
    variable cmd : std_logic_vector(3 downto 0);

    -- next state after n clocks: the command was issued on this edge, the next
    -- one goes out n edges later
    procedure goto_after (n : natural; target : state_t) is
    begin
      if n <= 1 then
        st <= target;
      else
        st   <= ST_WAIT;
        nxt  <= target;
        wcnt <= n - 1;
      end if;
    end procedure;
  begin
    if rising_edge(clk) then
      cmd := CMD_NOP;
      dram_ba     <= "00";
      dram_addr   <= (others => '0');
      dram_dqm    <= "00";
      dram_dq_oe  <= '0';
      dram_dq_out <= (others => '0');

      req_s <= req_s(0) & req_tog;

      if act_cnt /= 0 then
        act_cnt <= act_cnt - 1;
      end if;

      if rst = '1' then
        st       <= ST_INIT_WAIT;
        wcnt     <= INIT_CYCLES;
        act_cnt  <= 0;
        ref_cnt  <= REFRESH_CYCLES;
        ref_due  <= '0';
        init_ref <= 0;
        ack_i    <= '0';
        tog_l    <= '0';
        init_i   <= '0';
        req_s    <= "00";
      else
        -- refresh timer: one AUTO REFRESH is due every REFRESH_CYCLES clocks
        if init_i = '1' then
          if ref_cnt = 0 then
            ref_due <= '1';
            ref_cnt <= REFRESH_CYCLES;
          else
            ref_cnt <= ref_cnt - 1;
          end if;
        end if;

        case st is

          when ST_INIT_WAIT =>
            if wcnt <= 1 then
              st <= ST_INIT_PRE;
            else
              wcnt <= wcnt - 1;
            end if;

          when ST_INIT_PRE =>
            cmd := CMD_PRECHARGE;
            dram_addr(10) <= '1';                 -- all banks
            goto_after(C_RP, ST_INIT_REF);

          when ST_INIT_REF =>
            cmd := CMD_REFRESH;
            if init_ref = INIT_REFRESHES - 1 then
              goto_after(C_RFC, ST_INIT_MRS);
            else
              init_ref <= init_ref + 1;
              goto_after(C_RFC, ST_INIT_REF);
            end if;

          when ST_INIT_MRS =>
            cmd := CMD_LOAD_MODE;
            dram_addr <= MODE_REG;
            init_i    <= '1';
            ref_cnt   <= REFRESH_CYCLES;
            act_cnt   <= T_MRD_CK;
            goto_after(T_MRD_CK, ST_IDLE);

          when ST_WAIT =>
            if wcnt <= 1 then
              st <= nxt;
            else
              wcnt <= wcnt - 1;
            end if;

          when ST_IDLE =>
            if ref_due = '1' and act_cnt = 0 then
              cmd     := CMD_REFRESH;
              ref_due <= '0';
              act_cnt <= C_RFC;
              goto_after(C_RFC, ST_IDLE);
            elsif req_s(1) /= ack_i and act_cnt = 0 then
              -- the request buses are stable from the flip of req_tog on
              tog_l   <= req_s(1);
              we_l    <= we;
              addr_l  <= addr;
              wdata_l <= wdata;
              be_l    <= be;
              cmd     := CMD_ACTIVE;
              dram_ba   <= addr(10 downto 9);
              dram_addr <= addr(23 downto 11);
              act_cnt   <= ACT_TO_ACT;
              goto_after(C_RCD, ST_RW);
            end if;

          when ST_RW =>
            dram_ba   <= addr_l(10 downto 9);
            dram_addr <= "00" & '1' & addr_l(8 downto 0) & '0';   -- A10 = auto-precharge
            if we_l = '1' then
              cmd := CMD_WRITE;
              dram_dq_out <= wdata_l(15 downto 0);
              dram_dq_oe  <= '1';
              dram_dqm    <= not be_l(1 downto 0);
              st <= ST_WRITE2;
            else
              cmd := CMD_READ;
              rd_t <= 1;
              st <= ST_READ;
            end if;

          when ST_WRITE2 =>
            dram_dq_out <= wdata_l(31 downto 16);
            dram_dq_oe  <= '1';
            dram_dqm    <= not be_l(3 downto 2);
            ack_i <= tog_l;
            st    <= ST_IDLE;

          when ST_READ =>
            -- the command went out at edge c; rd_t is k at edge c + k. The first
            -- beat is on the pins during the cycle that ends at edge c + CL + 2.
            rd_t <= rd_t + 1;
            if rd_t = CAS_LATENCY + 2 + CAPTURE_EXTRA then
              rdata_i(15 downto 0) <= dram_dq_in;
            elsif rd_t = CAS_LATENCY + 3 + CAPTURE_EXTRA then
              rdata_i(31 downto 16) <= dram_dq_in;
              ack_i <= tog_l;
              st    <= ST_IDLE;
            end if;

        end case;
      end if;

      dram_cs_n  <= cmd(3);
      dram_ras_n <= cmd(2);
      dram_cas_n <= cmd(1);
      dram_we_n  <= cmd(0);
    end if;
  end process;

end architecture rtl;
