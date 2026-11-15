-- =============================================================================
-- Banco de teste do controlador da flash serial EPCS com o modelo do chip
--
-- Liga o epcs_ctrl ao epcs_model pelos quatro pinos SPI, como o bloco de interface do
-- dispositivo liga o controlador à flash serial da placa, e expõe as marcas do modelo
-- (violação, escrita habilitada e operação em andamento) para o teste.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity epcs_ctrl_tb is
    generic (
        -- Tamanho do chip em bytes.
        size_bytes  : positive := 524288;
        -- Início da região de usuário em bytes.
        user_base   : natural  := 262144;
        -- Bordas de i_clk em cada meio período do clock SPI.
        clk_div     : positive := 2
    );
    port (
        -- Clock do sistema.
        i_clk       : in    std_logic;
        -- Reset, ativo em '1'.
        i_rst       : in    std_logic;
        -- Barramento: índice do registrador.
        i_address   : in    std_logic_vector(3 downto 0);
        -- Barramento: escrita.
        i_write     : in    std_logic;
        -- Barramento: leitura.
        i_read      : in    std_logic;
        -- Barramento: dado de escrita.
        i_data_in   : in    std_logic_vector(31 downto 0);
        -- Barramento: dado de leitura.
        o_data_out  : out   std_logic_vector(31 downto 0);
        -- Interrupção.
        o_irq       : out   std_logic;
        -- Violação do contrato vista pelo modelo do chip.
        o_violation : out   std_logic;
        -- Escrita habilitada no chip.
        o_chip_wel  : out   std_logic;
        -- Operação em andamento no chip.
        o_chip_wip  : out   std_logic
    );
end entity epcs_ctrl_tb;

architecture sim of epcs_ctrl_tb is

    -- Clock SPI.
    signal sck  : std_logic;
    -- Seleção do chip.
    signal cs_n : std_logic;
    -- Dado para o chip.
    signal mosi : std_logic;
    -- Dado do chip.
    signal miso : std_logic;

begin

    u_ctrl : entity work.epcs_ctrl
        generic map (
            size_bytes => size_bytes,
            user_base  => user_base,
            clk_div    => clk_div
        )
        port map (
            i_clk      => i_clk,
            i_rst      => i_rst,
            i_address  => i_address,
            i_write    => i_write,
            i_read     => i_read,
            i_data_in  => i_data_in,
            o_data_out => o_data_out,
            o_irq      => o_irq,
            o_sck      => sck,
            o_cs_n     => cs_n,
            o_mosi     => mosi,
            i_miso     => miso
        );

    u_chip : entity work.epcs_model
        generic map (
            size_bytes    => size_bytes,
            protect_below => user_base
        )
        port map (
            i_sck       => sck,
            i_cs_n      => cs_n,
            i_mosi      => mosi,
            o_miso      => miso,
            o_violation => o_violation,
            o_wel       => o_chip_wel,
            o_wip       => o_chip_wip
        );

end architecture sim;
