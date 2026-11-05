-- =============================================================================
-- Modelo de simulação da FLASH interna de duas portas
--
-- Equivalente em VHDL puro do IP flash (altsyncram de duas portas verdadeiras),
-- com as mesmas portas e a mesma latência de um ciclo nas duas leituras, e com o
-- vetor de palavras visível ao cocotb. A escrita existe só na porta B. O
-- conteúdo inicial vem de rom_file, uma palavra de 32 bits por linha em
-- hexadecimal; sem arquivo, a memória começa zerada. Uma leitura que coincide
-- com a escrita do mesmo endereço devolve o dado novo na porta B, como o IP.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.utils_pkg.all;

entity flash_simulation is
  generic (
    -- Tamanho da memória em bytes, uma potência de dois.
    size_bytes : positive := 32768;
    -- Arquivo com o conteúdo inicial, uma palavra de 32 bits por linha em hexadecimal.
    rom_file   : string   := ""
  );
  port (
    -- Clock da porta A.
    i_clk_a     : in  std_logic := '1';
    -- Índice da palavra lida pela porta A.
    i_address_a : in  std_logic_vector(log2_exact(size_bytes) - 3 downto 0);
    -- Habilita a leitura da porta A.
    i_rden_a    : in  std_logic := '1';
    -- Palavra lida pela porta A.
    o_q_a       : out std_logic_vector(31 downto 0);
    -- Clock da porta B.
    i_clk_b     : in  std_logic := '1';
    -- Índice da palavra acessada pela porta B.
    i_address_b : in  std_logic_vector(log2_exact(size_bytes) - 3 downto 0);
    -- Habilita a leitura da porta B.
    i_rden_b    : in  std_logic := '1';
    -- Habilita a escrita da porta B.
    i_wren_b    : in  std_logic := '0';
    -- Dado de escrita da porta B.
    i_data_b    : in  std_logic_vector(31 downto 0) := (others => '0');
    -- Palavra lida pela porta B.
    o_q_b       : out std_logic_vector(31 downto 0)
  );
end entity flash_simulation;

architecture rtl of flash_simulation is

  -- Vetor de palavras da FLASH.
  type words_t is array (0 to size_bytes / 4 - 1) of std_logic_vector(31 downto 0);

  -- Lê o conteúdo inicial do arquivo; as palavras que faltam ficam zeradas.
  impure function load_words(path : string) return words_t is
    -- Arquivo de entrada.
    file f         : text;
    -- Resultado da abertura do arquivo.
    variable state : file_open_status;
    -- Conteúdo lido.
    variable words : words_t := (others => (others => '0'));
    -- Linha corrente.
    variable l     : line;
    -- Índice da palavra corrente.
    variable idx   : natural := 0;
  begin
    if path'length > 0 then
      file_open(state, f, path, read_mode);
      if state = open_ok then
        while not endfile(f) and idx < words'length loop
          readline(f, l);
          if l'length > 0 then
            hread(l, words(idx));
            idx := idx + 1;
          end if;
        end loop;
        file_close(f);
      end if;
    end if;
    return words;
  end function;

  -- Conteúdo da FLASH.
  signal mem   : words_t := load_words(rom_file);
  -- Registrador de saída da porta A.
  signal q_a_r : std_logic_vector(31 downto 0) := (others => '0');
  -- Registrador de saída da porta B.
  signal q_b_r : std_logic_vector(31 downto 0) := (others => '0');

begin

  o_q_a <= q_a_r;
  o_q_b <= q_b_r;

  -- Porta A: só lê.
  process (i_clk_a)
  begin
    if rising_edge(i_clk_a) then
      if i_rden_a = '1' then
        q_a_r <= mem(to_integer(unsigned(i_address_a)));
      end if;
    end if;
  end process;

  -- Porta B: lê e escreve.
  process (i_clk_b)
  begin
    if rising_edge(i_clk_b) then
      if i_wren_b = '1' then
        mem(to_integer(unsigned(i_address_b))) <= i_data_b;
        q_b_r <= i_data_b;
      elsif i_rden_b = '1' then
        q_b_r <= mem(to_integer(unsigned(i_address_b)));
      end if;
    end if;
  end process;

end architecture rtl;
