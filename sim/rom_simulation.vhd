-- =============================================================================
-- Modelo de simulação da ROM de instruções com duas portas de leitura
--
-- O conteúdo vem de rom_file, uma palavra de 32 bits por linha em hexadecimal. A
-- segunda porta lê o mesmo vetor com clock próprio (paridade com a rom2port do
-- hardware real), usada pelo estágio MEM do core.
-- =============================================================================

  library IEEE;
  use IEEE.std_logic_1164.all;
  use ieee.numeric_std.all;
  use std.textio.all;

  entity rom_simulation is
    generic (
      -- Largura do dado em bits.
      data_width: natural := 32;
      -- Largura do endereço em bits.
      addr_width: natural := 30;
      -- Log2 do número de palavras da ROM.
      memory_addr_width: natural := 9;
      -- Arquivo com o conteúdo, uma palavra de 32 bits por linha em hexadecimal.
      rom_file: string := "initROM.hex"
    );
    port (
      -- Endereço da palavra, porta 1.
      i_addr : in  std_logic_vector (addr_width-1 downto 0);
      -- Clock da porta 1.
      i_clk  : in  std_logic;
      -- Habilita de leitura da porta 1.
      i_re   : in  std_logic;
      -- Dado lido na porta 1.
      o_data : out std_logic_vector (data_width-1 downto 0);

      -- Endereço da palavra, porta 2.
      i_addr2 : in  std_logic_vector (addr_width-1 downto 0) := (others => '0');
      -- Clock da porta 2.
      i_clk2  : in  std_logic := '0';
      -- Habilita de leitura da porta 2.
      i_re2   : in  std_logic := '0';
      -- Dado lido na porta 2.
      o_data2 : out std_logic_vector (data_width-1 downto 0)
    );
  end entity;

  architecture rtl of rom_simulation is
    -- Vetor de palavras da ROM.
    type rom_block_t is array(0 to 2**memory_addr_width - 1)
      of std_logic_vector(data_width-1 downto 0);

    -- Conteúdo da ROM.
    signal rom_mem : rom_block_t := (others => (others => '0'));
    -- Índice da palavra lida na porta 1.
    signal local_addr : std_logic_vector(memory_addr_width-1 downto 0) := (others => '0');
    -- Registrador de saída da porta 1.
    signal data_reg : std_logic_vector(data_width-1 downto 0) := (others => '0');

    -- Índice da palavra lida na porta 2.
    signal local_addr2 : std_logic_vector(memory_addr_width-1 downto 0) := (others => '0');
    -- Registrador de saída da porta 2.
    signal data_reg2 : std_logic_vector(data_width-1 downto 0) := (others => '0');

    -- Converte um caractere hexadecimal em um nibble
    function hex_char_to_nibble(c : character) return std_logic_vector is
      -- Dígito hexadecimal convertido.
      variable nibble : std_logic_vector(3 downto 0);
    begin
      case c is
        when '0' => nibble := "0000";
        when '1' => nibble := "0001";
        when '2' => nibble := "0010";
        when '3' => nibble := "0011";
        when '4' => nibble := "0100";
        when '5' => nibble := "0101";
        when '6' => nibble := "0110";
        when '7' => nibble := "0111";
        when '8' => nibble := "1000";
        when '9' => nibble := "1001";
        when 'a'|'A' => nibble := "1010";
        when 'b'|'B' => nibble := "1011";
        when 'c'|'C' => nibble := "1100";
        when 'd'|'D' => nibble := "1101";
        when 'e'|'E' => nibble := "1110";
        when 'f'|'F' => nibble := "1111";
        when others  => nibble := "0000";
      end case;
      return nibble;
    end function;

    -- Converte um texto hexadecimal de 8 caracteres em um std_logic_vector(31 downto 0)
    function hex_string_to_slv(s : string) return std_logic_vector is
      -- Palavra convertida do texto hexadecimal.
      variable result : std_logic_vector(31 downto 0) := (others => '0');
    begin
      for i in 1 to s'length loop
        result := result(27 downto 0) & hex_char_to_nibble(s(i));
      end loop;
      return result;
    end function;

  begin

    init: process
      file f : text open read_mode is rom_file;
      -- Linha lida do arquivo.
      variable l    : line;
      -- Índice da palavra gravada.
      variable idx  : integer := 0;
      -- Texto hexadecimal da linha.
      variable s    : string(1 to 8);
      -- Comprimento do texto hexadecimal.
      variable slen : integer;
      -- Caractere em conversão.
      variable ch   : character;
      -- A leitura da linha teve sucesso.
      variable ok   : boolean;
    begin
      while not endfile(f) loop
        readline(f, l);
        slen := l'length;
        if slen >= 8 then
          for i in 1 to 8 loop
            read(l, ch, ok);
            s(i) := ch;
          end loop;
          if idx <= rom_mem'high then
            rom_mem(idx) <= hex_string_to_slv(s);
          end if;
          idx := idx + 1;
        end if;
      end loop;
      wait;
    end process;

    local_addr <= i_addr(memory_addr_width-1 downto 0);
    local_addr2 <= i_addr2(memory_addr_width-1 downto 0);

    sync_read: process(i_clk)
    begin
      if rising_edge(i_clk) then
        if i_re = '1' then
          data_reg <= rom_mem(to_integer(unsigned(local_addr)));
        end if;
      end if;
    end process;

    sync_read2: process(i_clk2)
    begin
      if rising_edge(i_clk2) then
        if i_re2 = '1' then
          data_reg2 <= rom_mem(to_integer(unsigned(local_addr2)));
        end if;
      end if;
    end process;

    o_data <= data_reg;
    o_data2 <= data_reg2;

  end architecture;
