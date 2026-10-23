library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- The decoder behind the core's external data port. Every access at or above 0x40000000 reaches
-- it; it sends the access to one of two kinds of slave and gives the core back that slave's ready
-- and data:
--
--   bit 31 = 0   a memory with its own ready (the SDRAM bridge): the port is passed through, with
--                the read and write strobes held back while another slave is selected
--   bit 31 = 1   a peripheral window: bits 30:28 are the peripheral id, bits 9:2 the word offset
--                inside it
--
-- A peripheral access takes one core cycle: a single pulse of we or re (even while the core waits
-- for something else), ready as a level until mem_advance, as the core's contract asks. A read of
-- a window nobody answers gives 0 and a write has no effect; both complete like any other.
--
-- The read data of a load stays on rdata until the next load completes, and the choice of which
-- slave it came from is registered when the load completes, so a load still in its last stage
-- sees its own data while the next access is already on the port.
--
-- Peripheral i answers on slot i: p_sel(i), p_we and p_re are one-hot with the id, p_rdata holds
-- 32 bits per slot, slot i in bits 32 i + 31 downto 32 i.
entity ext_interconnect is
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;  -- synchronous, active high

    -- the core's external port
    addr        : in  std_logic_vector(31 downto 0);
    wdata       : in  std_logic_vector(31 downto 0);
    byteena     : in  std_logic_vector(3 downto 0);
    rden        : in  std_logic;
    wren        : in  std_logic;
    mem_advance : in  std_logic;
    ready       : out std_logic;
    rdata       : out std_logic_vector(31 downto 0);

    -- the memory (the SDRAM bridge)
    m_addr      : out std_logic_vector(31 downto 0);
    m_wdata     : out std_logic_vector(31 downto 0);
    m_byteena   : out std_logic_vector(3 downto 0);
    m_rden      : out std_logic;
    m_wren      : out std_logic;
    m_ready     : in  std_logic;
    m_rdata     : in  std_logic_vector(31 downto 0);

    -- the peripherals
    p_addr      : out std_logic_vector(7 downto 0);
    p_wdata     : out std_logic_vector(31 downto 0);
    p_byteena   : out std_logic_vector(3 downto 0);
    p_we        : out std_logic_vector(7 downto 0);
    p_re        : out std_logic_vector(7 downto 0);
    p_rdata     : in  std_logic_vector(8 * 32 - 1 downto 0)
  );
end entity ext_interconnect;

architecture rtl of ext_interconnect is

  type state_t is (ST_IDLE, ST_DONE);
  signal st        : state_t := ST_IDLE;
  signal is_periph : std_logic;
  signal active    : std_logic;
  signal id        : integer range 0 to 7;
  signal sel_wb    : std_logic := '0';           -- 1: the last load came from a peripheral
  signal p_rdata_q : std_logic_vector(31 downto 0) := (others => '0');
  signal pending   : std_logic_vector(31 downto 0) := (others => '0');
  signal pulse     : std_logic;

begin

  is_periph <= addr(31);
  active    <= rden or wren;
  id        <= to_integer(unsigned(addr(30 downto 28)));

  m_addr    <= addr;
  m_wdata   <= wdata;
  m_byteena <= byteena;
  m_rden    <= rden and not is_periph;
  m_wren    <= wren and not is_periph;

  p_addr    <= addr(9 downto 2);
  p_wdata   <= wdata;
  p_byteena <= byteena;

  pulse <= '1' when st = ST_IDLE and is_periph = '1' and active = '1' else '0';
  process (pulse, id, rden, wren)
  begin
    p_we <= (others => '0');
    p_re <= (others => '0');
    if pulse = '1' then
      p_we(id) <= wren;
      p_re(id) <= rden;
    end if;
  end process;

  ready <= (m_ready) when is_periph = '0' else
           '1' when st = ST_DONE else '0';
  rdata <= p_rdata_q when sel_wb = '1' else m_rdata;

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        st        <= ST_IDLE;
        sel_wb    <= '0';
        p_rdata_q <= (others => '0');
        pending   <= (others => '0');
      else
        case st is
          when ST_IDLE =>
            if is_periph = '1' and active = '1' then
              pending <= p_rdata(32 * id + 31 downto 32 * id);
              st      <= ST_DONE;
            end if;
          when ST_DONE =>
            if mem_advance = '1' then
              if rden = '1' then
                p_rdata_q <= pending;
                sel_wb    <= '1';
              end if;
              st <= ST_IDLE;
            end if;
        end case;
        -- a memory access completing hands the data back to the memory
        if is_periph = '0' and rden = '1' and m_ready = '1' and mem_advance = '1' then
          sel_wb <= '0';
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
