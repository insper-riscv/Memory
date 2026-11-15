-- =============================================================================
-- Banco de teste do adaptador de leitura direta da flash serial EPCS com o modelo do chip
--
-- Liga o epcs_xip ao epcs_model pelos quatro pinos SPI, como o bloco de interface do
-- dispositivo liga o controlador à flash serial da placa, e expõe a marca de violação do
-- modelo (instrução fora da lista, escrita) para o teste.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.config_pkg.all;

entity epcs_xip_tb is
    generic (
        -- Tamanho do chip em bytes.
        size_bytes   : positive := 524288;
        -- Tamanho da janela vista pelo SoC em bytes.
        window_bytes : positive := 262144;
        -- Byte do chip que é o byte zero da janela.
        chip_offset  : natural  := 262144;
        -- Bordas de i_clk em cada meio período do clock SPI.
        clk_div      : positive := 2;
        -- Meios períodos com CS# alto depois de cada quadro.
        gap_ticks    : positive := 8;
        -- Lê com FAST_READ em vez de READ.
        fast_read    : boolean  := false
    );
    port (
        -- Clock do sistema.
        i_clk       : in    std_logic;
        -- Reset, ativo em '1'.
        i_rst       : in    std_logic;
        -- Leitura: endereço do pedido.
        i_addr      : in    addr_t;
        -- Leitura: pedido de leitura.
        i_rden      : in    std_logic;
        -- Leitura: pedido de linha.
        i_line      : in    std_logic;
        -- Leitura: pedido consumido.
        i_advance   : in    std_logic;
        -- Leitura: pedido concluído.
        o_ready     : out   std_logic;
        -- Leitura: esperando o chip.
        o_busy      : out   std_logic;
        -- Leitura: palavra pedida.
        o_rdata     : out   word_t;
        -- Leitura: palavras 1 a 3 da linha.
        o_rdata_x   : out   std_logic_vector(3 * XLEN - 1 downto 0);
        -- Violação do contrato vista pelo modelo do chip.
        o_violation : out   std_logic;
        -- CS# do chip, para o teste ver que uma leitura fora da janela não toca nele.
        o_cs_n      : out   std_logic
    );
end entity epcs_xip_tb;

architecture sim of epcs_xip_tb is

    -- Clock SPI.
    signal sck  : std_logic;
    -- Seleção do chip.
    signal cs_n : std_logic;
    -- Dado para o chip.
    signal mosi : std_logic;
    -- Dado do chip.
    signal miso : std_logic;

begin

    o_cs_n <= cs_n;

    u_xip : entity work.epcs_xip
        generic map (
            window_bytes => window_bytes,
            chip_offset  => chip_offset,
            clk_div      => clk_div,
            gap_ticks    => gap_ticks,
            fast_read    => fast_read
        )
        port map (
            i_clk     => i_clk,
            i_rst     => i_rst,
            i_addr    => i_addr,
            i_rden    => i_rden,
            i_line    => i_line,
            i_advance => i_advance,
            o_ready   => o_ready,
            o_busy    => o_busy,
            o_rdata   => o_rdata,
            o_rdata_x => o_rdata_x,
            o_sck     => sck,
            o_cs_n    => cs_n,
            o_mosi    => mosi,
            i_miso    => miso
        );

    u_chip : entity work.epcs_model
        generic map (
            size_bytes    => size_bytes,
            protect_below => chip_offset
        )
        port map (
            i_sck       => sck,
            i_cs_n      => cs_n,
            i_mosi      => mosi,
            o_miso      => miso,
            o_violation => o_violation,
            o_wel       => open,
            o_wip       => open
        );

end architecture sim;
