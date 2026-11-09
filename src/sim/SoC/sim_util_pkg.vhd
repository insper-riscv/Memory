-- =============================================================================
-- Utilidades dos modelos de simulação de memória
--
-- Reúne o que os modelos de chip e os sistemas de teste repetiam: a conversão
-- de nanossegundos em tempo, o padrão determinístico de dados que enche um
-- chip e que os testes reproduzem, e o registro de uma violação de regra do
-- chip, que pulsa a saída de violação do modelo e falha ou avisa conforme o
-- modelo esteja configurado. O pacote é só de simulação e não entra em
-- síntese.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package sim_util_pkg is

  -- Converte n nanossegundos em tempo.
  pure function tns (n : natural) return time;

  -- Palavra do padrão determinístico no endereço a, (a x 0x9E3779B1) xor 0x5A5A1234 em 32 bits; o
  -- byte de endereço a de um chip é o byte 3 da palavra do endereço a.
  pure function pattern_word (a : std_logic_vector(31 downto 0)) return std_logic_vector;

  -- Registra uma violação: pulsa o_violation por 1 ns e, com abort verdadeiro, falha a simulação,
  -- ou, com abort falso, só avisa. A mensagem leva o prefixo do modelo.
  procedure violate (
    -- Saída de violação do modelo, que recebe o pulso.
    signal   o_violation : out std_logic;
    -- Nome do modelo, prefixo da mensagem.
    constant prefix      : in  string;
    -- Verdadeiro: a violação falha a simulação.
    constant abort       : in  boolean;
    -- Descrição da regra violada.
    constant msg         : in  string
  );

end package sim_util_pkg;

package body sim_util_pkg is

  pure function tns (n : natural) return time is
  begin
    return n * 1 ns;
  end function tns;

  pure function pattern_word (a : std_logic_vector(31 downto 0)) return std_logic_vector is
    -- Produto de 64 bits do endereço pela constante.
    variable p : unsigned(63 downto 0);
  begin
    p := unsigned(a) * unsigned'(x"9E3779B1");
    return std_logic_vector(p(31 downto 0) xor unsigned'(x"5A5A1234"));
  end function pattern_word;

  procedure violate (
    signal   o_violation : out std_logic;
    constant prefix      : in  string;
    constant abort       : in  boolean;
    constant msg         : in  string
  ) is
  begin
    o_violation <= '1';
    o_violation <= transport '0' after 1 ns;
    if abort then
      report prefix & ": " & msg severity failure;
    else
      report prefix & ": " & msg severity warning;
    end if;
  end procedure violate;

end package body sim_util_pkg;
