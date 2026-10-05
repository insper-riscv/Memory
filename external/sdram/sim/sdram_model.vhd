library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;

-- Behavioral model of the 32M x 16 SDR SDRAM (simulation only). It stores the
-- written data in a sparse table and it FAILS THE SIMULATION when the controller
-- breaks a rule of the chip: command order, the timings of sdram_pkg, the
-- power-up sequence, the mode register, the refresh interval, a read or write to
-- a bank that is not open, two commands that overlap a burst.
--
-- The word debug port reads the stored content straight from the model (the
-- 32-bit word of a word address), and a pulse on dbg_flip inverts one bit of a
-- stored word, to prove that a check notices a corrupted memory.
entity sdram_model is
  generic (
    TCK_PS : natural := T_CK_PS
  );
  port (
    clk    : in    std_logic;
    cke    : in    std_logic;
    cs_n   : in    std_logic;
    ras_n  : in    std_logic;
    cas_n  : in    std_logic;
    we_n   : in    std_logic;
    ba     : in    std_logic_vector(1 downto 0);
    a      : in    std_logic_vector(12 downto 0);
    dqm    : in    std_logic_vector(1 downto 0);
    dq     : inout std_logic_vector(15 downto 0);
    -- high while the controller is in reset: the chip starts a new power-up
    -- sequence (the wait, PRECHARGE ALL, refreshes and mode register again)
    reinit : in    std_logic;

    dbg_word_addr   : in  std_logic_vector(23 downto 0);
    dbg_word_data   : out std_logic_vector(31 downto 0);
    dbg_flip        : in  std_logic;
    dbg_flip_addr   : in  std_logic_vector(23 downto 0);
    dbg_flip_bit    : in  std_logic_vector(4 downto 0);
    dbg_refreshes   : out std_logic_vector(31 downto 0);
    dbg_init_ok     : out std_logic
  );
end entity sdram_model;

architecture sim of sdram_model is

  -- sparse table of 16-bit halfwords, keyed by row & bank & column (25 bits)
  type node_t;
  type node_ptr is access node_t;
  type node_t is record
    key  : natural;
    val  : std_logic_vector(15 downto 0);
    next_node : node_ptr;
  end record;
  type bucket_array is array (0 to 65535) of node_ptr;

  type sparse_t is protected
    procedure write (key : natural; val : std_logic_vector(15 downto 0));
    impure function read (key : natural) return std_logic_vector;
  end protected sparse_t;

  type sparse_t is protected body
    variable buckets : bucket_array := (others => null);

    procedure write (key : natural; val : std_logic_vector(15 downto 0)) is
      variable p : node_ptr := buckets(key mod 65536);
    begin
      while p /= null loop
        if p.key = key then
          p.val := val;
          return;
        end if;
        p := p.next_node;
      end loop;
      p := new node_t'(key => key, val => val, next_node => buckets(key mod 65536));
      buckets(key mod 65536) := p;
    end procedure;

    impure function read (key : natural) return std_logic_vector is
      variable p : node_ptr := buckets(key mod 65536);
    begin
      while p /= null loop
        if p.key = key then
          return p.val;
        end if;
        p := p.next_node;
      end loop;
      return x"0000";
    end function;
  end protected body sparse_t;

  shared variable mem : sparse_t;

  constant TCK : time := TCK_PS * 1 ps;

  type time_arr  is array (0 to 3) of time;
  type bool_arr  is array (0 to 3) of boolean;
  type row_arr   is array (0 to 3) of natural;

  type rd_slot_t is record
    valid : boolean;
    data  : std_logic_vector(15 downto 0);
  end record;
  type rd_pipe_t is array (1 to 6) of rd_slot_t;

  signal dq_drv : std_logic_vector(15 downto 0) := (others => 'Z');
  signal dq_oe  : std_logic := '0';
  signal refresh_count : natural := 0;
  signal init_ok       : std_logic := '0';

  function key_of (row : natural; bank : natural; col : natural) return natural is
  begin
    return (row * 4 + bank) * 1024 + col;
  end function;

begin

  dq <= dq_drv when dq_oe = '1' else (others => 'Z');

  dbg_refreshes <= std_logic_vector(to_unsigned(refresh_count, 32));
  dbg_init_ok   <= init_ok;

  dbg_read : process (clk)
    variable w : natural;
  begin
    if rising_edge(clk) then
      w := to_integer(unsigned(dbg_word_addr));
      dbg_word_data <= mem.read(2 * w + 1) & mem.read(2 * w);
    end if;
  end process;

  dbg_flipper : process (dbg_flip)
    variable w, k : natural;
    variable v    : std_logic_vector(15 downto 0);
  begin
    if rising_edge(dbg_flip) then
      w := to_integer(unsigned(dbg_flip_addr));
      k := to_integer(unsigned(dbg_flip_bit));
      v := mem.read(2 * w + k / 16);
      v(k mod 16) := not v(k mod 16);
      mem.write(2 * w + k / 16, v);
    end if;
  end process;

  chip : process (clk)
    variable cmd         : std_logic_vector(3 downto 0);
    variable power_up    : time := 0 ns;
    variable seen_cmd    : boolean := false;
    variable pre_all_ok  : boolean := false;
    variable n_refresh   : natural := 0;
    variable mrs_done    : boolean := false;
    variable mrs_until   : time := 0 ns;
    variable ref_until   : time := 0 ns;
    variable last_ref    : time := 0 ns;
    variable ref_check   : boolean := false;
    variable burst_until : time := 0 ns;

    variable bank_open   : bool_arr := (others => false);
    variable bank_row    : row_arr  := (others => 0);
    variable act_time    : time_arr := (others => 0 ns);
    variable idle_time   : time_arr := (others => 0 ns);
    variable last_wr_end : time_arr := (others => 0 ns);

    variable rd_pipe     : rd_pipe_t := (others => (valid => false, data => (others => '0')));
    variable wr_pending  : boolean := false;
    variable wr_key      : natural := 0;
    variable wr_bank     : natural := 0;

    variable b, row, col, key : natural;
    variable pre_start   : time;
    variable ap          : boolean;
    variable old, merged : std_logic_vector(15 downto 0);
  begin
    if rising_edge(clk) then

      if reinit = '1' then
        power_up   := now;
        seen_cmd   := false;
        pre_all_ok := false;
        n_refresh  := 0;
        mrs_done   := false;
        ref_check  := false;
        for i in 0 to 3 loop
          bank_open(i) := false;
          idle_time(i) := now;
        end loop;
        wr_pending := false;
        init_ok    <= '0';
      end if;

      -- 1. data on the pins: launch what the read pipeline holds for this edge
      if rd_pipe(1).valid then
        dq_drv <= rd_pipe(1).data;
        dq_oe  <= '1';
      else
        dq_oe  <= '0';
      end if;
      for i in 1 to 5 loop
        rd_pipe(i) := rd_pipe(i + 1);
      end loop;
      rd_pipe(6).valid := false;

      -- 2. the second beat of a write that was commanded on the previous edge
      if wr_pending then
        old    := mem.read(wr_key);
        merged := old;
        if dqm(0) = '0' then merged(7 downto 0)  := dq(7 downto 0);  end if;
        if dqm(1) = '0' then merged(15 downto 8) := dq(15 downto 8); end if;
        mem.write(wr_key, merged);
        last_wr_end(wr_bank) := now;
        wr_pending := false;
      end if;

      -- 3. refresh interval: after the mode register is set, a refresh at least every tREFI
      if ref_check then
        assert (now - last_ref) <= T_REFI_PS * 1 ps
          report "SDRAM model: no AUTO REFRESH within tREFI" severity failure;
      end if;

      if cke = '1' and cs_n = '0' then
        cmd := cs_n & ras_n & cas_n & we_n;

        if cmd /= CMD_NOP then
          if not seen_cmd then
            seen_cmd := true;
            assert now - power_up >= T_INIT_PS * 1 ps
              report "SDRAM model: first command before the power-up wait" severity failure;
          end if;
        end if;

        b   := to_integer(unsigned(ba));
        row := to_integer(unsigned(a));
        col := to_integer(unsigned(a(9 downto 0)));
        ap  := a(10) = '1';

        if cmd = CMD_LOAD_MODE then
          assert pre_all_ok and n_refresh >= 2
            report "SDRAM model: LOAD MODE REGISTER before PRECHARGE ALL and two refreshes" severity failure;
          assert now >= ref_until report "SDRAM model: LOAD MODE REGISTER inside tRFC" severity failure;
          assert a = MODE_REG
            report "SDRAM model: unexpected mode register value" severity failure;
          mrs_done  := true;
          mrs_until := now + T_MRD_CK * TCK;
          last_ref  := now;
          ref_check := true;
          init_ok   <= '1';

        elsif cmd = CMD_PRECHARGE then
          assert now >= ref_until report "SDRAM model: PRECHARGE inside tRFC" severity failure;
          if ap then
            for i in 0 to 3 loop
              if bank_open(i) then
                assert now - act_time(i) >= T_RAS_PS * 1 ps
                  report "SDRAM model: PRECHARGE before tRAS" severity failure;
              end if;
              bank_open(i) := false;
              idle_time(i) := now + T_RP_PS * 1 ps;
            end loop;
            pre_all_ok := true;
          else
            if bank_open(b) then
              assert now - act_time(b) >= T_RAS_PS * 1 ps
                report "SDRAM model: PRECHARGE before tRAS" severity failure;
              assert now - last_wr_end(b) >= T_WR_PS * 1 ps
                report "SDRAM model: PRECHARGE before tWR" severity failure;
            end if;
            bank_open(b) := false;
            idle_time(b) := now + T_RP_PS * 1 ps;
          end if;

        elsif cmd = CMD_REFRESH then
          for i in 0 to 3 loop
            assert not bank_open(i) and now >= idle_time(i)
              report "SDRAM model: AUTO REFRESH with a bank not idle" severity failure;
          end loop;
          assert now >= ref_until report "SDRAM model: AUTO REFRESH inside tRFC" severity failure;
          assert pre_all_ok report "SDRAM model: AUTO REFRESH before PRECHARGE ALL" severity failure;
          ref_until := now + T_RFC_PS * 1 ps;
          if mrs_done then
            last_ref := now;
          end if;
          n_refresh := n_refresh + 1;
          refresh_count <= refresh_count + 1;

        elsif cmd = CMD_ACTIVE then
          assert mrs_done report "SDRAM model: ACTIVE before the mode register is set" severity failure;
          assert now >= mrs_until report "SDRAM model: ACTIVE inside tMRD" severity failure;
          assert now >= ref_until report "SDRAM model: ACTIVE inside tRFC" severity failure;
          assert not bank_open(b) report "SDRAM model: ACTIVE on an open bank" severity failure;
          assert now >= idle_time(b) report "SDRAM model: ACTIVE inside tRP" severity failure;
          assert now - act_time(b) >= T_RC_PS * 1 ps or act_time(b) = 0 ns
            report "SDRAM model: ACTIVE inside tRC" severity failure;
          bank_open(b) := true;
          bank_row(b)  := row;
          act_time(b)  := now;

        elsif cmd = CMD_READ or cmd = CMD_WRITE then
          assert mrs_done report "SDRAM model: read/write before the mode register is set" severity failure;
          assert bank_open(b) report "SDRAM model: read/write on a bank that is not open" severity failure;
          assert now - act_time(b) >= T_RCD_PS * 1 ps
            report "SDRAM model: read/write inside tRCD" severity failure;
          assert now >= burst_until report "SDRAM model: read/write overlaps a burst" severity failure;
          assert col mod 2 = 0 report "SDRAM model: burst of 2 must start on an even column" severity failure;
          key := key_of(bank_row(b), b, col);

          if cmd = CMD_READ then
            -- first beat launched CL edges after this one, second beat one edge later
            rd_pipe(CAS_LATENCY).valid := true;
            rd_pipe(CAS_LATENCY).data  := mem.read(key);
            rd_pipe(CAS_LATENCY + 1).valid := true;
            rd_pipe(CAS_LATENCY + 1).data  := mem.read(key + 1);
            burst_until := now + (CAS_LATENCY + 2) * TCK;
            if ap then
              pre_start := now + 2 * TCK;
              if act_time(b) + T_RAS_PS * 1 ps > pre_start then
                pre_start := act_time(b) + T_RAS_PS * 1 ps;
              end if;
              bank_open(b) := false;
              idle_time(b) := pre_start + T_RP_PS * 1 ps;
            end if;
          else
            old    := mem.read(key);
            merged := old;
            if dqm(0) = '0' then merged(7 downto 0)  := dq(7 downto 0);  end if;
            if dqm(1) = '0' then merged(15 downto 8) := dq(15 downto 8); end if;
            mem.write(key, merged);
            wr_pending := true;
            wr_key     := key + 1;
            wr_bank    := b;
            burst_until := now + 2 * TCK;
            last_wr_end(b) := now + TCK;
            if ap then
              pre_start := now + TCK + T_WR_PS * 1 ps;
              if act_time(b) + T_RAS_PS * 1 ps > pre_start then
                pre_start := act_time(b) + T_RAS_PS * 1 ps;
              end if;
              bank_open(b) := false;
              idle_time(b) := pre_start + T_RP_PS * 1 ps;
            end if;
          end if;

        end if;
      end if;
    end if;
  end process chip;

end architecture sim;
