-- =============================================================================
-- Controlador de acesso de usuário à flash serial EPCS (leitura, gravação e apagar)
--
-- Junta o epcs_cmd (registradores, guarda da região de usuário e sequenciador) ao
-- epcs_spi (mestre SPI) e entrega o conjunto com um barramento de registradores de
-- 32 bits e os quatro pinos SPI da flash serial de configuração, que a DE0-CV, a
-- DE0-Nano, a DE2-115 e a DE10-Nano usam para guardar o bitstream. O software lê o
-- chip todo, e só grava e apaga acima de user_base, depois de um WREN concluído; o
-- bitstream, que fica abaixo, nunca recebe PP nem SE. Os registradores estão no
-- cabeçalho do epcs_cmd.
--
-- Os pinos SPI vão ao bloco de interface com a flash serial do dispositivo
-- (epcs_asmi_cyclone_iv_e ou epcs_asmi_cyclone_v), ou ao modelo na simulação.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity epcs_ctrl is
    generic (
        -- Tamanho do chip em bytes (8388608 é a EPCS64).
        size_bytes     : positive := 8388608;
        -- Início da região de usuário em bytes, múltiplo do setor de 64 KB.
        user_base      : natural  := 4194304;
        -- Bordas de i_clk em cada meio período do clock SPI.
        clk_div        : positive := 2;
        -- Meios períodos com CS# alto depois de cada quadro.
        gap_ticks      : positive := 8
    );
    port (
        -- Clock do módulo.
        i_clk      : in    std_logic;
        -- Reset síncrono, ativo em '1'.
        i_rst      : in    std_logic;
        -- Barramento: índice do registrador.
        i_address  : in    std_logic_vector(3 downto 0);
        -- Barramento: escrita.
        i_write    : in    std_logic;
        -- Barramento: leitura.
        i_read     : in    std_logic;
        -- Barramento: dado de escrita.
        i_data_in  : in    std_logic_vector(31 downto 0);
        -- Barramento: dado de leitura.
        o_data_out : out   std_logic_vector(31 downto 0);
        -- Interrupção: concluído com a habilitação ligada.
        o_irq      : out   std_logic;
        -- SPI: clock.
        o_sck      : out   std_logic;
        -- SPI: seleção do chip, ativa em '0'.
        o_cs_n     : out   std_logic;
        -- SPI: dado para o chip.
        o_mosi     : out   std_logic;
        -- SPI: dado do chip.
        i_miso     : in    std_logic
    );
end entity epcs_ctrl;

architecture rtl of epcs_ctrl is

    -- Pedido de quadro.
    signal req     : std_logic;
    -- Código da operação.
    signal op      : std_logic_vector(2 downto 0);
    -- Endereço do quadro.
    signal addr    : std_logic_vector(23 downto 0);
    -- Bytes de dado do quadro.
    signal len     : std_logic_vector(8 downto 0);
    -- Mestre SPI ocupado.
    signal busy    : std_logic;
    -- Fim do quadro.
    signal done    : std_logic;
    -- Byte recebido válido.
    signal rx_v    : std_logic;
    -- Índice do byte recebido.
    signal rx_idx  : std_logic_vector(7 downto 0);
    -- Byte recebido.
    signal rx_data : std_logic_vector(7 downto 0);
    -- Índice do byte a enviar.
    signal tx_idx  : std_logic_vector(7 downto 0);
    -- Byte a enviar.
    signal tx_data : std_logic_vector(7 downto 0);

begin

    u_cmd : entity work.epcs_cmd
        generic map (
            size_bytes => size_bytes,
            user_base  => user_base
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
            o_req      => req,
            o_op       => op,
            o_addr     => addr,
            o_len      => len,
            i_busy     => busy,
            i_done     => done,
            i_rx_valid => rx_v,
            i_rx_idx   => rx_idx,
            i_rx_data  => rx_data,
            i_tx_idx   => tx_idx,
            o_tx_data  => tx_data
        );

    u_spi : entity work.epcs_spi
        generic map (
            clk_div   => clk_div,
            gap_ticks => gap_ticks
        )
        port map (
            i_clk      => i_clk,
            i_rst      => i_rst,
            i_req      => req,
            i_op       => op,
            i_addr     => addr,
            i_len      => len,
            o_busy     => busy,
            o_done     => done,
            o_rx_valid => rx_v,
            o_rx_idx   => rx_idx,
            o_rx_data  => rx_data,
            o_tx_idx   => tx_idx,
            i_tx_data  => tx_data,
            o_sck      => o_sck,
            o_cs_n     => o_cs_n,
            o_mosi     => o_mosi,
            i_miso     => i_miso
        );

end architecture rtl;
