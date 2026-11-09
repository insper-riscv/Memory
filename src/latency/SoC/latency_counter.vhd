-- =============================================================================
-- Máquina de contagem de latência dos modelos de memória
--
-- Bloco-folha que os modelos emulados contam o tempo de um acesso com: o flash_chip
-- (primeira palavra e palavras seguintes), o ram_chip (uma contagem por porta), o
-- adaptador onchip_ram_port (latência da RAM interna igual à do ram_chip) e o
-- flash_cmd_port (espera do apagar e da gravação). A contagem existe aqui uma só vez, de
-- modo que a simulação e o FPGA contam do mesmo jeito.
--
-- Contrato, com E0 a borda em que i_load vale '1' e N o valor de i_count (N = 0 vale 1):
--   - o_last sobe na borda E_N, a N-ésima depois de E0, e só nela: quem comanda age nessa
--     borda (captura o dado, conclui o acesso) e pode pedir uma nova contagem no mesmo
--     ciclo, que tem prioridade sobre o término;
--   - o_wait vale '1' nas bordas E1 até E_(N-1), isto é, enquanto ainda falta mais de uma
--     borda para o término; fora da contagem vale '0';
--   - sem nova carga a contagem termina em E_N e o bloco volta a ficar livre (os dois
--     sinais em '0').
-- Um i_rst em '1' zera a contagem.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity latency_counter is
    generic (
        -- Maior valor de i_count, em bordas.
        max_count : positive := 255
    );
    port (
        -- Clock do módulo.
        i_clk : in    std_logic;
        -- Reset, ativo em '1'.
        i_rst : in    std_logic;

        -- Pulso de um ciclo que inicia uma contagem de i_count bordas.
        i_load  : in    std_logic;
        -- Bordas até o término da contagem, lido junto com i_load (0 conta como 1).
        i_count : in    natural range 0 to max_count;
        -- A contagem termina nesta borda ('1' só na última).
        o_last  : out   std_logic;
        -- Ainda falta mais de uma borda para o término ('1').
        o_wait  : out   std_logic
    );
end entity latency_counter;

architecture rtl of latency_counter is

    -- Bordas que faltam, contando a atual; zero com o bloco livre.
    signal cnt : natural range 0 to max_count := 0;

begin

    o_last <= '1' when cnt = 1 else '0';
    o_wait <= '1' when cnt > 1 else '0';

    process (i_clk) is
    begin

        if rising_edge(i_clk) then
            if i_rst = '1' then
                cnt <= 0;
            elsif i_load = '1' then
                if i_count = 0 then
                    cnt <= 1;
                else
                    cnt <= i_count;
                end if;
            elsif cnt > 1 then
                cnt <= cnt - 1;
            else
                cnt <= 0;
            end if;
        end if;

    end process;

end architecture rtl;
