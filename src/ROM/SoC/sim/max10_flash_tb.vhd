-- =============================================================================
-- Banco de teste do controlador da flash do MAX 10 com o modelo da megafunção
--
-- Liga o max10_flash ao max10_flash_model pelas interfaces Avalon-MM de dados e de
-- CSR, como o topo da placa liga o controlador ao IP gerado. O reset do modelo é o
-- inverso do reset do controlador, como o reset_n da megafunção.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity max10_flash_tb is
    generic (
        -- Largura do endereço de palavra da interface de dados.
        data_addr_bits : positive                     := 8;
        -- Setores que o apagar pode atingir.
        erase_allowed  : std_logic_vector(4 downto 0) := "00011";
        -- Palavras de cada setor do modelo.
        sector_words   : positive                     := 16;
        -- Bordas de uma gravação no modelo.
        write_cycles   : positive                     := 6;
        -- Bordas de um apagar no modelo.
        erase_cycles   : positive                     := 30
    );
    port (
        -- Clock do sistema.
        i_clk      : in    std_logic;
        -- Reset, ativo em '1'.
        i_rst      : in    std_logic;
        -- Barramento: índice do registrador.
        i_address  : in    std_logic_vector(2 downto 0);
        -- Barramento: escrita.
        i_write    : in    std_logic;
        -- Barramento: leitura.
        i_read     : in    std_logic;
        -- Barramento: dado de escrita.
        i_data_in  : in    std_logic_vector(31 downto 0);
        -- Barramento: dado de leitura.
        o_data_out : out   std_logic_vector(31 downto 0);
        -- Interrupção.
        o_irq      : out   std_logic
    );
end entity max10_flash_tb;

architecture sim of max10_flash_tb is

    -- Pedido de leitura de dados.
    signal data_read   : std_logic;
    -- Pedido de escrita de dados.
    signal data_write  : std_logic;
    -- Endereço de dados.
    signal data_addr   : std_logic_vector(data_addr_bits - 1 downto 0);
    -- Palavra de escrita.
    signal data_wdata  : std_logic_vector(31 downto 0);
    -- Espera de dados.
    signal data_wait   : std_logic;
    -- Palavra de leitura válida.
    signal data_rvalid : std_logic;
    -- Palavra de leitura.
    signal data_rdata  : std_logic_vector(31 downto 0);
    -- Pedido de leitura do CSR.
    signal csr_read    : std_logic;
    -- Pedido de escrita do CSR.
    signal csr_write   : std_logic;
    -- Registrador do CSR.
    signal csr_addr    : std_logic;
    -- Palavra de escrita do CSR.
    signal csr_wdata   : std_logic_vector(31 downto 0);
    -- Palavra de leitura do CSR.
    signal csr_rdata   : std_logic_vector(31 downto 0);
    -- Reset do modelo, ativo em '0'.
    signal reset_n     : std_logic;

begin

    reset_n <= not i_rst;

    u_ctrl : entity work.max10_flash
        generic map (
            data_addr_bits => data_addr_bits,
            erase_allowed  => erase_allowed
        )
        port map (
            i_clk         => i_clk,
            i_rst         => i_rst,
            i_address     => i_address,
            i_write       => i_write,
            i_read        => i_read,
            i_data_in     => i_data_in,
            o_data_out    => o_data_out,
            o_irq         => o_irq,
            o_data_read   => data_read,
            o_data_write  => data_write,
            o_data_addr   => data_addr,
            o_data_wdata  => data_wdata,
            i_data_wait   => data_wait,
            i_data_rvalid => data_rvalid,
            i_data_rdata  => data_rdata,
            o_csr_read    => csr_read,
            o_csr_write   => csr_write,
            o_csr_addr    => csr_addr,
            o_csr_wdata   => csr_wdata,
            i_csr_rdata   => csr_rdata
        );

    u_model : entity work.max10_flash_model
        generic map (
            data_addr_bits => data_addr_bits,
            sector_words   => sector_words,
            write_cycles   => write_cycles,
            erase_cycles   => erase_cycles
        )
        port map (
            i_clk         => i_clk,
            i_reset_n     => reset_n,
            i_data_read   => data_read,
            i_data_write  => data_write,
            i_data_addr   => data_addr,
            i_data_wdata  => data_wdata,
            o_data_wait   => data_wait,
            o_data_rvalid => data_rvalid,
            o_data_rdata  => data_rdata,
            i_csr_read    => csr_read,
            i_csr_write   => csr_write,
            i_csr_addr    => csr_addr,
            i_csr_wdata   => csr_wdata,
            o_csr_rdata   => csr_rdata
        );

end architecture sim;
