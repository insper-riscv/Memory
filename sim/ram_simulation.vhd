-- =============================================================================
-- Modelo de simulação da RAM de dados
--
-- Uma porta, leitura e escrita síncronas, com habilita de bytes. O conteúdo
-- inicial vem de ram_file, uma palavra de 32 bits por linha em hexadecimal; vazio
-- significa RAM zerada. O mesmo processo carrega a imagem e escreve o vetor
-- depois, para o vetor ter um único driver.
-- =============================================================================

library IEEE;
use IEEE.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity ram_simulation is
  generic (
    -- Largura do dado em bits.
    data_width: natural := 32;
    -- Largura do endereço em bits.
    addr_width: natural := 30;
    -- Log2 do número de palavras da RAM (9: 512 palavras de 32 bits).
    memory_addr_width: natural := 9;
    -- Arquivo com o conteúdo inicial, uma palavra de 32 bits por linha em hexadecimal (vazio: RAM zerada).
    ram_file: string := ""
  );
  port (
    -- Clock da RAM.
    i_clk      : in  std_logic;
    -- Endereço da palavra, em índice de palavra.
    i_addr     : in  std_logic_vector(addr_width-1 downto 0);
    -- Dado de escrita.
    i_data_in  : in  std_logic_vector(data_width-1 downto 0);
    -- Dado lido, válido no ciclo seguinte ao pedido.
    o_data_out : out std_logic_vector(data_width-1 downto 0);
    -- Habilita de escrita ('1').
    i_we_ram    : in  std_logic;
    -- Habilita de leitura ('1').
    i_re_ram    : in  std_logic;
    -- Habilita do chip ('1' = RAM ativa).
    i_en_ram     : in  std_logic;
    -- Habilita de bytes da escrita, um bit por byte.
    i_mask     : in  std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of ram_simulation is
  -- Vetor de palavras de 32 bits da RAM.
  type mem_t is array(0 to 2**memory_addr_width - 1) of std_logic_vector(31 downto 0);
  -- Conteúdo da RAM.
  signal mem : mem_t := (others => (others => '0'));

  -- Índice da palavra, os bits baixos do endereço.
  signal widx : std_logic_vector(memory_addr_width-1 downto 0):= (others => '0');

  -- Registrador de saída do dado lido.
  signal data_out_reg : std_logic_vector(31 downto 0) := (others => '0');

begin
  -- O índice da palavra são os memory_addr_width bits baixos do endereço, de modo que toda a faixa do vetor é acessível.
  widx <= i_addr(memory_addr_width - 1 downto 0);

  -- O mesmo processo carrega a imagem inicial e depois escreve o vetor, então
  -- o vetor tem um único driver. A imagem passa pelo sinal, não por
  -- um resultado de função, porque o GHDL aloca o vetor de uma função na
  -- pilha e uma RAM de 2**16 palavras ou mais excede o limite dela.
  process
    file f      : text;
    -- Linha lida do arquivo de imagem.
    variable l  : line;
    -- Palavra lida da linha.
    variable w  : std_logic_vector(31 downto 0);
    -- A leitura da linha teve sucesso.
    variable ok : boolean;
    -- Índice da palavra gravada.
    variable idx : natural := 0;
  begin
    if ram_file'length > 0 then
      file_open(f, ram_file, read_mode);
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
        -- atualiza os bytes selecionados dentro da palavra de 32 bits
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
