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
--
-- A line request (line = 1) moves four words, the 16 bytes that start at the word address given
-- (its two low bits are ignored), in one opening of the row: ACTIVE, four READ or WRITE commands two
-- clocks apart (the last with auto-precharge) and eight beats on the data pins with no gap. Word 0
-- travels on wdata/be/rdata as before and words 1 to 3 on wdata_x/be_x/rdata_x (32 bits each, word
-- 1 in the lowest bits). The four words are in the same row because a line is aligned to 16 bytes.
entity sdram_ctrl is
  generic (
    TCK_PS         : natural := T_CK_PS;
    -- cycles waited after power-up before the first command, and between two
    -- refreshes: overridable for short simulations
    INIT_CYCLES    : natural := cycles(T_INIT_PS, T_CK_PS);
    REFRESH_CYCLES : natural := cycles(T_REFI_PS, T_CK_PS) * 9 / 10;
    -- extra clocks before the read data is sampled (board and clock phase tuning)
    CAPTURE_EXTRA  : natural := 0;
    -- true: req_tog comes from another clock and is synchronized here; false: it comes from
    -- this clock (the arbiter) and is used as it is, with no synchronizer latency
    SYNC_REQ       : boolean := true
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
    line      : in  std_logic := '0';
    wdata_x   : in  std_logic_vector(95 downto 0) := (others => '0');
    be_x      : in  std_logic_vector(11 downto 0) := (others => '0');
    rdata_x   : out std_logic_vector(95 downto 0);

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
  -- the same for a line: the last command goes out six clocks after the first, and the last beat
  -- two clocks after that
  constant ACT_TO_ACT_LINE : natural :=
    larger(C_RC, larger(C_RCD + 6 + CAS_LATENCY + 4, C_RCD + 8 + C_WR + C_RP));

  type state_t is (ST_INIT_WAIT, ST_INIT_PRE, ST_INIT_REF, ST_INIT_MRS, ST_WAIT,
                   ST_IDLE, ST_RW, ST_READ, ST_WRITE2, ST_RDGAP);
  signal st  : state_t := ST_INIT_WAIT;
  signal nxt : state_t := ST_INIT_WAIT;

  signal wcnt     : natural range 0 to 2**18 - 1 := 0;
  signal act_cnt  : natural range 0 to 63 := 0;     -- clocks until the next ACTIVE is allowed
  signal ref_cnt  : natural range 0 to 2**14 - 1 := 0;
  signal ref_due  : std_logic := '0';
  signal init_ref : natural range 0 to INIT_REFRESHES := 0;

  signal req_s    : std_logic_vector(1 downto 0) := "00";
  signal req_eff  : std_logic;                      -- the request toggle the controller acts on
  signal ack_i    : std_logic := '0';
  signal tog_l    : std_logic := '0';  -- the toggle of the request in service

  signal we_l     : std_logic := '0';
  signal addr_l   : std_logic_vector(23 downto 0) := (others => '0');
  signal wdata_l  : std_logic_vector(31 downto 0) := (others => '0');
  signal be_l     : std_logic_vector(3 downto 0) := (others => '0');
  signal rd_t     : natural range 0 to 31 := 0;      -- clocks since the first READ command
  signal rd_run   : std_logic := '0';                -- the read data is being sampled
  signal rdata_i  : std_logic_vector(31 downto 0) := (others => '0');
  signal rdx_i    : std_logic_vector(95 downto 0) := (others => '0');
  signal line_l   : std_logic := '0';
  signal wdx_l    : std_logic_vector(95 downto 0) := (others => '0');
  signal bex_l    : std_logic_vector(11 downto 0) := (others => '0');
  signal lcnt     : natural range 0 to 3 := 0;       -- the word of the line the next command is for
  signal init_i   : std_logic := '0';

begin

  ack_tog   <= ack_i;
  req_eff   <= req_s(1) when SYNC_REQ else req_tog;
  init_done <= init_i;
  rdata     <= rdata_i;
  rdata_x   <= rdx_i;
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
    function to_unsigned_bit (b : boolean) return std_logic is
    begin
      if b then
        return '1';
      end if;
      return '0';
    end function;
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
        rd_run   <= '0';
        lcnt     <= 0;
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

        -- read data sampling: beat m (0 to 7) is on the pins in the cycle that ends at the edge
        -- where rd_t = CL + 2 + m; the last beat answers the request
        if rd_run = '1' then
          rd_t <= rd_t + 1;
          for m in 0 to 7 loop
            if rd_t = CAS_LATENCY + 2 + CAPTURE_EXTRA + m then
              if m = 0 then
                rdata_i(15 downto 0) <= dram_dq_in;
              elsif m = 1 then
                rdata_i(31 downto 16) <= dram_dq_in;
              else
                rdx_i(16 * (m - 2) + 15 downto 16 * (m - 2)) <= dram_dq_in;
              end if;
              if (line_l = '0' and m = 1) or m = 7 then
                ack_i  <= tog_l;
                rd_run <= '0';
                st     <= ST_IDLE;
              end if;
            end if;
          end loop;
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
            elsif req_eff /= ack_i and act_cnt = 0 then
              -- the request buses are stable from the flip of req_tog on
              tog_l   <= req_eff;
              we_l    <= we;
              addr_l  <= addr;
              wdata_l <= wdata;
              be_l    <= be;
              line_l  <= line;
              wdx_l   <= wdata_x;
              bex_l   <= be_x;
              lcnt    <= 0;
              cmd     := CMD_ACTIVE;
              dram_ba   <= addr(10 downto 9);
              dram_addr <= addr(23 downto 11);
              if line = '1' then
                act_cnt <= ACT_TO_ACT_LINE;
              else
                act_cnt <= ACT_TO_ACT;
              end if;
              goto_after(C_RCD, ST_RW);
            end if;

          when ST_RW =>
            -- the column of word lcnt of a line (a single word keeps its own column); auto-precharge
            -- on the last command
            dram_ba <= addr_l(10 downto 9);
            if line_l = '1' then
              dram_addr <= "00" & to_unsigned_bit(lcnt = 3) & addr_l(8 downto 2) & std_logic_vector(to_unsigned(lcnt, 2)) & '0';
            else
              dram_addr <= "00" & '1' & addr_l(8 downto 0) & '0';   -- A10 = auto-precharge
            end if;
            if we_l = '1' then
              cmd := CMD_WRITE;
              if lcnt = 0 then
                dram_dq_out <= wdata_l(15 downto 0);
                dram_dqm    <= not be_l(1 downto 0);
              else
                dram_dq_out <= wdx_l(32 * (lcnt - 1) + 15 downto 32 * (lcnt - 1));
                dram_dqm    <= not bex_l(4 * (lcnt - 1) + 1 downto 4 * (lcnt - 1));
              end if;
              dram_dq_oe  <= '1';
              st <= ST_WRITE2;
            else
              cmd := CMD_READ;
              if lcnt = 0 then
                rd_t   <= 1;
                rd_run <= '1';
              end if;
              if line_l = '1' and lcnt /= 3 then
                st <= ST_RDGAP;
              else
                st <= ST_READ;
              end if;
            end if;

          when ST_RDGAP =>
            lcnt <= lcnt + 1;
            st   <= ST_RW;

          when ST_WRITE2 =>
            if lcnt = 0 then
              dram_dq_out <= wdata_l(31 downto 16);
              dram_dqm    <= not be_l(3 downto 2);
            else
              dram_dq_out <= wdx_l(32 * (lcnt - 1) + 31 downto 32 * (lcnt - 1) + 16);
              dram_dqm    <= not bex_l(4 * (lcnt - 1) + 3 downto 4 * (lcnt - 1) + 2);
            end if;
            dram_dq_oe  <= '1';
            if line_l = '1' and lcnt /= 3 then
              lcnt <= lcnt + 1;
              st   <= ST_RW;
            else
              ack_i <= tog_l;
              st    <= ST_IDLE;
            end if;

          when ST_READ =>
            null;    -- the sampling above ends it

        end case;
      end if;

      dram_cs_n  <= cmd(3);
      dram_ras_n <= cmd(2);
      dram_cas_n <= cmd(1);
      dram_we_n  <= cmd(0);
    end if;
  end process;

end architecture rtl;
