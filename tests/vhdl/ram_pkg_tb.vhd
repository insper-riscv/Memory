-- =============================================================================
-- Testbench do pacote ram_pkg
--
-- Expõe nas portas o deslocamento na janela do chip, calculado de forma
-- combinacional, para o cocotb conduzir os casos de borda: base zero, base
-- diferente de zero, endereço igual à base, endereço abaixo da base (que dá a
-- volta em 26 bits) e endereço com bits acima dos 26 baixos.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ram_pkg.all;

entity ram_pkg_tb is
    port (
        -- Endereço de byte do acesso.
        i_addr     : in    std_logic_vector(31 downto 0);
        -- Base da janela do chip dentro da região, em KiB.
        i_base_kib : in    std_logic_vector(15 downto 0);
        -- Resultado de window_offset(i_addr, i_base_kib).
        o_offset   : out   std_logic_vector(25 downto 0)
    );
end entity ram_pkg_tb;

architecture sim of ram_pkg_tb is

begin

    o_offset <= std_logic_vector(window_offset(i_addr, to_integer(unsigned(i_base_kib))));

end architecture sim;
