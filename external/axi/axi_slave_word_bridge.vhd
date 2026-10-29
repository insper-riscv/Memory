library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- An AXI4 slave in front of a memory with the core's word contract (sdram_cpu_bridge, or any memory
-- that follows the same ready/mem_advance rules), with the line extension of that contract.
--
-- Bursts it serves (INCR, 4-byte beats, aligned to 4 bytes, one transaction at a time):
--
--   a burst of four beats aligned to 16 bytes   one line access of the memory (the fast path)
--   any other length                            one word access per beat, in order
--
-- Anything else (a size other than 4 bytes, a burst type other than INCR, an address not aligned
-- to 4 bytes) is answered with SLVERR after all its beats are consumed; nothing reaches the memory.
-- IDs are not carried (width 0).
--
-- AW is taken first, then the beats of W follow; a read waits while a write is in progress and a
-- write that is offered at the same time goes first. The access is held on the word port until
-- ready; mem_advance is one pulse then, because nothing else is stopped. The response waits for
-- bready, and the beats of R wait for rready; no request is accepted before the whole response has
-- been taken.
entity axi_slave_word_bridge is
  port (
    i_clk         : in  std_logic;
    i_rst         : in  std_logic;  -- synchronous, active high

    -- AXI4 slave port
    i_s_awvalid   : in  std_logic;
    o_s_awready   : out std_logic;
    i_s_awaddr    : in  std_logic_vector(31 downto 0);
    i_s_awlen     : in  std_logic_vector(7 downto 0);
    i_s_awsize    : in  std_logic_vector(2 downto 0);
    i_s_awburst   : in  std_logic_vector(1 downto 0);
    i_s_wvalid    : in  std_logic;
    o_s_wready    : out std_logic;
    i_s_wdata     : in  std_logic_vector(31 downto 0);
    i_s_wstrb     : in  std_logic_vector(3 downto 0);
    i_s_wlast     : in  std_logic;
    o_s_bvalid    : out std_logic;
    i_s_bready    : in  std_logic;
    o_s_bresp     : out std_logic_vector(1 downto 0);
    i_s_arvalid   : in  std_logic;
    o_s_arready   : out std_logic;
    i_s_araddr    : in  std_logic_vector(31 downto 0);
    i_s_arlen     : in  std_logic_vector(7 downto 0);
    i_s_arsize    : in  std_logic_vector(2 downto 0);
    i_s_arburst   : in  std_logic_vector(1 downto 0);
    o_s_rvalid    : out std_logic;
    i_s_rready    : in  std_logic;
    o_s_rdata     : out std_logic_vector(31 downto 0);
    o_s_rresp     : out std_logic_vector(1 downto 0);
    o_s_rlast     : out std_logic;

    -- the memory's word port, with the line extension
    o_addr        : out std_logic_vector(31 downto 0);
    o_wdata       : out std_logic_vector(31 downto 0);
    o_byteena     : out std_logic_vector(3 downto 0);
    o_rden        : out std_logic;
    o_wren        : out std_logic;
    o_mem_advance : out std_logic;
    i_ready       : in  std_logic;
    i_rdata       : in  std_logic_vector(31 downto 0);
    o_line        : out std_logic;
    o_wdata_x     : out std_logic_vector(95 downto 0);
    o_byteena_x   : out std_logic_vector(11 downto 0);
    i_rdata_x     : in  std_logic_vector(95 downto 0)
  );
end entity axi_slave_word_bridge;

architecture rtl of axi_slave_word_bridge is

  -- ST_IDLE   waiting for AW or AR
  -- ST_WBEAT  taking the beats of W (stored for a line, one access each otherwise, or dropped)
  -- ST_ACC    the access is on the word port, waiting for ready
  -- ST_ADV    mem_advance, one clock
  -- ST_RBEAT  a beat of R is offered
  -- ST_BRESP  B is offered
  type state_t is (ST_IDLE, ST_WBEAT, ST_ACC, ST_ADV, ST_RBEAT, ST_BRESP);
  signal st      : state_t := ST_IDLE;

  signal we_l    : std_logic := '0';
  signal bad_l   : std_logic := '0';           -- the burst is not one this bridge serves
  signal fast_l  : std_logic := '0';           -- a line access
  signal addr_l  : std_logic_vector(31 downto 0) := (others => '0');
  signal left_l  : unsigned(7 downto 0) := (others => '0');   -- beats still to move, minus one
  signal k       : natural range 0 to 3 := 0;  -- the word of the line being stored or sent
  signal wdata_l : std_logic_vector(31 downto 0) := (others => '0');
  signal strb_l  : std_logic_vector(3 downto 0) := (others => '0');
  signal wdx_l   : std_logic_vector(95 downto 0) := (others => '0');
  signal bex_l   : std_logic_vector(11 downto 0) := (others => '0');
  signal err_l   : std_logic := '0';

  signal awr, arr : std_logic;

  function is_bad (a : std_logic_vector(31 downto 0); size : std_logic_vector(2 downto 0);
                   burst : std_logic_vector(1 downto 0)) return std_logic is
  begin
    if size /= "010" or burst /= "01" or a(1 downto 0) /= "00" then
      return '1';
    end if;
    return '0';
  end function;

  function is_line (a : std_logic_vector(31 downto 0); len : std_logic_vector(7 downto 0)) return std_logic is
  begin
    if len = "00000011" and a(3 downto 0) = "0000" then
      return '1';
    end if;
    return '0';
  end function;

begin

  awr <= '1' when st = ST_IDLE else '0';
  arr <= '1' when st = ST_IDLE and i_s_awvalid = '0' else '0';
  o_s_awready <= awr;
  o_s_arready <= arr;
  o_s_wready  <= '1' when st = ST_WBEAT else '0';

  o_addr        <= addr_l;
  o_wdata       <= wdata_l;
  o_byteena     <= strb_l;
  o_wdata_x     <= wdx_l;
  o_byteena_x   <= bex_l;
  o_line        <= fast_l;
  o_rden        <= '1' when (st = ST_ACC or st = ST_ADV) and we_l = '0' else '0';
  o_wren        <= '1' when (st = ST_ACC or st = ST_ADV) and we_l = '1' else '0';
  o_mem_advance <= '1' when st = ST_ADV else '0';

  o_s_bvalid <= '1' when st = ST_BRESP else '0';
  o_s_bresp  <= "10" when err_l = '1' else "00";

  o_s_rvalid <= '1' when st = ST_RBEAT else '0';
  o_s_rresp  <= "10" when bad_l = '1' else "00";
  o_s_rlast  <= '1' when st = ST_RBEAT and ((fast_l = '1' and k = 3) or (fast_l = '0' and left_l = 0)) else '0';
  -- the memory's read data only changes on its own mem_advance, so it stays valid while a beat waits
  o_s_rdata  <= x"00000000" when bad_l = '1' else
              i_rdata when (fast_l = '0' or k = 0) else
              i_rdata_x(31 downto 0)  when k = 1 else
              i_rdata_x(63 downto 32) when k = 2 else
              i_rdata_x(95 downto 64);

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        st    <= ST_IDLE;
        we_l  <= '0';
        bad_l <= '0';
        fast_l <= '0';
        err_l <= '0';
        k     <= 0;
      else
        case st is

          when ST_IDLE =>
            if i_s_awvalid = '1' then
              addr_l <= i_s_awaddr;
              left_l <= unsigned(i_s_awlen);
              we_l   <= '1';
              bad_l  <= is_bad(i_s_awaddr, i_s_awsize, i_s_awburst);
              if is_bad(i_s_awaddr, i_s_awsize, i_s_awburst) = '0' and is_line(i_s_awaddr, i_s_awlen) = '1' then
                fast_l <= '1';
              else
                fast_l <= '0';
              end if;
              err_l  <= is_bad(i_s_awaddr, i_s_awsize, i_s_awburst);
              k      <= 0;
              st     <= ST_WBEAT;
            elsif i_s_arvalid = '1' then
              addr_l <= i_s_araddr;
              left_l <= unsigned(i_s_arlen);
              we_l   <= '0';
              bad_l  <= is_bad(i_s_araddr, i_s_arsize, i_s_arburst);
              if is_bad(i_s_araddr, i_s_arsize, i_s_arburst) = '0' and is_line(i_s_araddr, i_s_arlen) = '1' then
                fast_l <= '1';
              else
                fast_l <= '0';
              end if;
              k      <= 0;
              if is_bad(i_s_araddr, i_s_arsize, i_s_arburst) = '1' then
                st <= ST_RBEAT;          -- the error beats need no access
              else
                st <= ST_ACC;
              end if;
            end if;

          when ST_WBEAT =>
            if i_s_wvalid = '1' then
              if bad_l = '1' then
                -- consume the beats; nothing reaches the memory
                if i_s_wlast = '1' then
                  st <= ST_BRESP;
                end if;
              elsif fast_l = '1' then
                if k = 0 then
                  wdata_l <= i_s_wdata;
                  strb_l  <= i_s_wstrb;
                elsif k = 1 then
                  wdx_l(31 downto 0)  <= i_s_wdata;
                  bex_l(3 downto 0)   <= i_s_wstrb;
                elsif k = 2 then
                  wdx_l(63 downto 32) <= i_s_wdata;
                  bex_l(7 downto 4)   <= i_s_wstrb;
                else
                  wdx_l(95 downto 64) <= i_s_wdata;
                  bex_l(11 downto 8)  <= i_s_wstrb;
                end if;
                if k = 3 then
                  k  <= 0;
                  st <= ST_ACC;
                else
                  k <= k + 1;
                end if;
              else
                wdata_l <= i_s_wdata;
                strb_l  <= i_s_wstrb;
                st      <= ST_ACC;
              end if;
            end if;

          when ST_ACC =>
            if i_ready = '1' then
              st <= ST_ADV;
            end if;

          when ST_ADV =>
            if we_l = '1' then
              if fast_l = '1' or left_l = 0 then
                st <= ST_BRESP;
              else
                left_l <= left_l - 1;
                addr_l <= std_logic_vector(unsigned(addr_l) + 4);
                st     <= ST_WBEAT;
              end if;
            else
              st <= ST_RBEAT;
            end if;

          when ST_RBEAT =>
            if i_s_rready = '1' then
              if (fast_l = '1' and k = 3) or (fast_l = '0' and left_l = 0) then
                st <= ST_IDLE;
                k  <= 0;
              elsif fast_l = '1' then
                k <= k + 1;
              else
                left_l <= left_l - 1;
                addr_l <= std_logic_vector(unsigned(addr_l) + 4);
                if bad_l = '0' then
                  st <= ST_ACC;
                end if;                    -- an error beat: the next one is offered next clock
              end if;
            end if;

          when ST_BRESP =>
            if i_s_bready = '1' then
              st <= ST_IDLE;
              k  <= 0;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
