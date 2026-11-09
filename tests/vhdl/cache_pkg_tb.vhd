-- =============================================================================
-- Testbench do pacote cache_pkg
--
-- Expõe nas portas as duas funções do pacote, calculadas de forma
-- combinacional, para o cocotb conduzir os casos de borda: endereço igual à
-- base, igual ao fim, uma unidade abaixo e acima, região vazia (base igual ao
-- fim) e os tamanhos de cache de menor e de maior índice.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cache_pkg.all;

entity cache_pkg_tb is
    port (
        -- Endereço de byte testado por in_window.
        i_addr       : in    std_logic_vector(31 downto 0);
        -- Base da região em KiB (22 bits cobrem os 4 GiB do endereço).
        i_base_kib   : in    std_logic_vector(21 downto 0);
        -- Fim da região em KiB.
        i_end_kib    : in    std_logic_vector(21 downto 0);
        -- Logaritmo de dois do tamanho da cache em bits, de 8 a 31.
        i_size_log2  : in    std_logic_vector(4 downto 0);
        -- Resultado de in_window(i_addr, i_base_kib, i_end_kib).
        o_in_window  : out   std_logic;
        -- Resultado de index_bits_of(2 ** i_size_log2).
        o_index_bits : out   std_logic_vector(4 downto 0)
    );
end entity cache_pkg_tb;

architecture sim of cache_pkg_tb is

begin

    o_in_window <= in_window(
                             i_addr, to_integer(unsigned(i_base_kib)), to_integer(unsigned(i_end_kib))
                         );

    -- Abaixo de 2**8 bits a função falha por projeto, então a saída fica em zero.
    o_index_bits <= std_logic_vector(
                                        to_unsigned(index_bits_of(2 ** to_integer(unsigned(i_size_log2))), 5))
                    when unsigned(i_size_log2) >= 8 else
                    (others => '0');

end architecture sim;
