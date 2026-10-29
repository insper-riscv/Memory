library IEEE;
use IEEE.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity RAM_simulation is
  generic (
    dataWidth: natural := 32;
    addrWidth: natural := 30;
    memoryAddrWidth: natural := 9;  -- 0 - 511 posicoes de 32 bits cada
    -- Initial contents, one 32-bit word per line in hexadecimal (the format of
    -- ROM_simulation's ROM_FILE). Empty: the RAM starts at zero.
    RAM_FILE: string := ""
  );
  port (
    i_clk      : in  std_logic;
    i_addr     : in  std_logic_vector(addrWidth-1 downto 0);
    i_data_in  : in  std_logic_vector(dataWidth-1 downto 0);
    o_data_out : out std_logic_vector(dataWidth-1 downto 0);
    i_we_ram    : in  std_logic;                     -- habilita escrita
    i_re_ram    : in  std_logic;                     -- habilita leitura
    i_en_ram     : in  std_logic;                     -- chip enable (RAM ativa)
    i_mask     : in  std_logic_vector(3 downto 0)   -- byte enables
  );
end entity;

architecture rtl of RAM_simulation is
  type mem_t is array(0 to 2**memoryAddrWidth - 1) of std_logic_vector(31 downto 0);
  signal mem : mem_t := (others => (others => '0'));

  -- word index (32-bit aligned)
  signal widx : std_logic_vector(memoryAddrWidth-1 downto 0):= (others => '0');

  signal data_out_reg : std_logic_vector(31 downto 0) := (others => '0'); -- registro de saída

begin
  -- Was hardcoded to addr(8 downto 0) regardless of memoryAddrWidth
  -- (ROM_simulation's equivalent slice already used the generic
  -- correctly) — meant any word beyond the fixed 512-word range
  -- silently aliased to (real_word_index mod 512) instead of being
  -- reachable, no matter how large memoryAddrWidth/mem itself was set.
  widx <= i_addr(memoryAddrWidth - 1 downto 0);

  -- The same process loads the initial image and writes the array afterwards, so
  -- the array keeps a single driver. The image goes through the signal, not
  -- through a function result, because GHDL allocates a function's array on the
  -- stack and a RAM of 2**16 words or more exceeds its limit.
  process
    file f      : text;
    variable l  : line;
    variable w  : std_logic_vector(31 downto 0);
    variable ok : boolean;
    variable idx : natural := 0;
  begin
    if RAM_FILE'length > 0 then
      file_open(f, RAM_FILE, read_mode);
      while not endfile(f) loop
        readline(f, l);
        if l'length >= 8 then
          hread(l, w, ok);
          if ok and idx <= mem'high then
            mem(idx) <= w;
          end if;
          idx := idx + 1;
        end if;
      end loop;
      file_close(f);
    end if;

    loop
      wait until rising_edge(i_clk);
      if (i_we_ram = '1' and i_en_ram = '1') then
        -- update selected bytes inside the 32-bit word
        if i_mask(0) = '1' then
          mem(to_integer(unsigned(widx)))(7 downto 0)   <= i_data_in(7 downto 0);
        end if;
        if i_mask(1) = '1' then
          mem(to_integer(unsigned(widx)))(15 downto 8)  <= i_data_in(15 downto 8);
        end if;
        if i_mask(2) = '1' then
          mem(to_integer(unsigned(widx)))(23 downto 16) <= i_data_in(23 downto 16);
        end if;
        if i_mask(3) = '1' then
          mem(to_integer(unsigned(widx)))(31 downto 24) <= i_data_in(31 downto 24);
        end if;
      end if;
    end loop;
  end process;

  -- leitura síncrona: captura mem(...) na subida do clock se eRAM='1' e reRAM='1'
  sync_read: process(i_clk)
  begin
    if rising_edge(i_clk) then
      if (i_en_ram = '1' and i_re_ram = '1') then
        data_out_reg <= mem(to_integer(unsigned(widx)));
      end if;
      -- caso contrário, mantém o valor anterior (nenhuma alteração)
    end if;
  end process;

  o_data_out <= data_out_reg;

end architecture;
