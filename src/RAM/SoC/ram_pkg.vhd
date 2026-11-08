-- =============================================================================
-- Funções comuns às memórias de janela
--
-- O endereço de um acesso a uma memória de chip usa os 26 bits baixos (a
-- região é de 64 MiB), e a janela do chip começa base_kib KiB depois do início
-- da região. A tradução do endereço de byte para o deslocamento dentro da
-- janela era escrita em cada memória; o pacote a reúne numa função só.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package ram_pkg is

  -- Deslocamento em bytes do endereço dentro da janela do chip: os 26 bits baixos de addr menos
  -- base_kib * 1024, em aritmética de 26 bits (abaixo da base o resultado dá a volta, e quem usa
  -- testa a base antes).
  pure function window_offset (
    addr : std_logic_vector(31 downto 0); base_kib : natural
  ) return unsigned;

end package ram_pkg;

package body ram_pkg is

  pure function window_offset (
    addr : std_logic_vector(31 downto 0); base_kib : natural
  ) return unsigned is
  begin
    return unsigned(addr(25 downto 0)) - to_unsigned(base_kib * 1024, 26);
  end function window_offset;

end package body ram_pkg;
