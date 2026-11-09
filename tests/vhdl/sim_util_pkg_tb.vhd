-- =============================================================================
-- Testbench do pacote sim_util_pkg
--
-- Expõe nas portas as três utilidades do pacote: a palavra do padrão de dados
-- de um endereço, o atraso em nanossegundos de tns (o pulso o_tick sobe depois
-- de tns(i_delay_ns)) e o registro de uma violação (cada subida de
-- i_violate pulsa o_violation). A violação roda sem abortar, porque o teste
-- precisa ver o pulso e a simulação continua.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sim_util_pkg.all;

entity sim_util_pkg_tb is
    port (
        -- Endereço de byte do padrão.
        i_addr      : in    std_logic_vector(31 downto 0);
        -- Palavra de pattern_word(i_addr).
        o_word      : out   std_logic_vector(31 downto 0);
        -- Atraso pedido a tns, em ns.
        i_delay_ns  : in    std_logic_vector(7 downto 0);
        -- Sobe depois de tns(i_delay_ns) a partir de uma subida de i_start.
        i_start     : in    std_logic;
        -- Sinaliza que o atraso de tns passou.
        o_tick      : out   std_logic;
        -- Pedido de violação: cada subida chama violate.
        i_violate   : in    std_logic;
        -- Pulso de violação registrado por violate.
        o_violation : out   std_logic
    );
end entity sim_util_pkg_tb;

architecture sim of sim_util_pkg_tb is

begin

    o_word <= pattern_word(i_addr);

    -- Mede tns: o_tick sobe depois do atraso pedido.
    p_tick : process is
    begin

        o_tick <= '0';
        wait until rising_edge(i_start);
        wait for tns(to_integer(unsigned(i_delay_ns)));
        o_tick <= '1';
        wait until falling_edge(i_start);

    end process p_tick;

    -- Registra uma violação a cada subida de i_violate.
    p_violation : process is
    begin

        o_violation <= '0';

        loop

            wait until rising_edge(i_violate);
            violate(o_violation, "sim_util_pkg_tb", false, "violacao de teste");

        end loop;

    end process p_violation;

end architecture sim;
