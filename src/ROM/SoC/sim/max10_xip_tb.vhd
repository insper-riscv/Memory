-- =============================================================================
-- Banco de teste do adaptador de leitura direta da flash do MAX 10 com o modelo da megafunção
--
-- Liga o max10_xip e o max10_flash à interface Avalon-MM de dados do max10_flash_model, com a
-- escolha de quem a dirige em i_sel_xip ('1' o adaptador, '0' o banco de registradores), como o
-- topo da placa divide a megafunção entre a leitura direta e a gravação. O banco de registradores
-- programa o conteúdo da flash; o adaptador o lê. O reset do modelo é o inverso do reset do
-- controlador, como o reset_n da megafunção.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.config_pkg.all;

entity max10_xip_tb is
    generic (
        -- Largura do endereço de palavra da interface de dados.
        data_addr_bits : positive := 8;
        -- Tamanho da janela vista pelo SoC em bytes.
        window_bytes   : positive := 256;
        -- Palavra do espaço de dados que é a palavra zero da janela.
        base_word      : natural  := 16;
        -- Palavras de cada setor do modelo.
        sector_words   : positive := 16;
        -- Bordas de uma gravação no modelo.
        write_cycles   : positive := 6
    );
    port (
        -- Clock do sistema.
        i_clk      : in    std_logic;
        -- Reset, ativo em '1'.
        i_rst      : in    std_logic;
        -- Quem dirige a interface de dados: o adaptador ('1') ou o banco de registradores ('0').
        i_sel_xip  : in    std_logic;
        -- Banco de registradores: índice do registrador.
        i_address  : in    std_logic_vector(2 downto 0);
        -- Banco de registradores: escrita.
        i_write    : in    std_logic;
        -- Banco de registradores: leitura.
        i_read     : in    std_logic;
        -- Banco de registradores: dado de escrita.
        i_data_in  : in    std_logic_vector(31 downto 0);
        -- Banco de registradores: dado de leitura.
        o_data_out : out   std_logic_vector(31 downto 0);
        -- Adaptador: endereço do pedido.
        i_addr     : in    addr_t;
        -- Adaptador: pedido de leitura.
        i_rden     : in    std_logic;
        -- Adaptador: pedido de linha.
        i_line     : in    std_logic;
        -- Adaptador: pedido consumido.
        i_advance  : in    std_logic;
        -- Adaptador: pedido concluído.
        o_ready    : out   std_logic;
        -- Adaptador: esperando a megafunção.
        o_busy     : out   std_logic;
        -- Adaptador: palavra pedida.
        o_rdata    : out   word_t;
        -- Adaptador: palavras 1 a 3 da linha.
        o_rdata_x  : out   std_logic_vector(3 * XLEN - 1 downto 0);
        -- Pedido de escrita da interface de dados, para o teste ver que o adaptador nunca escreve.
        o_data_write : out std_logic
    );
end entity max10_xip_tb;

architecture sim of max10_xip_tb is

    -- Pedido de leitura do banco de registradores.
    signal reg_read    : std_logic;
    -- Pedido de escrita do banco de registradores.
    signal reg_write   : std_logic;
    -- Endereço do banco de registradores.
    signal reg_addr    : std_logic_vector(data_addr_bits - 1 downto 0);
    -- Pedido de leitura do adaptador.
    signal xip_read    : std_logic;
    -- Endereço do adaptador.
    signal xip_addr    : std_logic_vector(data_addr_bits - 1 downto 0);
    -- Palavra de escrita do banco de registradores.
    signal data_wdata  : std_logic_vector(31 downto 0);
    -- Pedido de leitura que chega ao modelo.
    signal data_read   : std_logic;
    -- Pedido de escrita que chega ao modelo.
    signal data_write  : std_logic;
    -- Endereço que chega ao modelo.
    signal data_addr   : std_logic_vector(data_addr_bits - 1 downto 0);
    -- Espera do modelo.
    signal data_wait   : std_logic;
    -- Palavra de leitura válida do modelo.
    signal data_rvalid : std_logic;
    -- Palavra de leitura do modelo.
    signal data_rdata  : std_logic_vector(31 downto 0);
    -- Espera vista pelo adaptador.
    signal xip_wait    : std_logic;
    -- Espera vista pelo banco de registradores.
    signal reg_wait    : std_logic;
    -- Validade vista pelo adaptador.
    signal xip_rvalid  : std_logic;
    -- Validade vista pelo banco de registradores.
    signal reg_rvalid  : std_logic;
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

    reset_n      <= not i_rst;
    data_read    <= xip_read when i_sel_xip = '1' else reg_read;
    data_addr    <= xip_addr when i_sel_xip = '1' else reg_addr;
    data_write   <= reg_write when i_sel_xip = '0' else '0';
    o_data_write <= data_write;
    xip_wait     <= data_wait when i_sel_xip = '1' else '1';
    reg_wait     <= data_wait when i_sel_xip = '0' else '1';
    xip_rvalid   <= data_rvalid when i_sel_xip = '1' else '0';
    reg_rvalid   <= data_rvalid when i_sel_xip = '0' else '0';

    u_ctrl : entity work.max10_flash
        generic map (
            data_addr_bits => data_addr_bits
        )
        port map (
            i_clk         => i_clk,
            i_rst         => i_rst,
            i_address     => i_address,
            i_write       => i_write,
            i_read        => i_read,
            i_data_in     => i_data_in,
            o_data_out    => o_data_out,
            o_irq         => open,
            o_data_read   => reg_read,
            o_data_write  => reg_write,
            o_data_addr   => reg_addr,
            o_data_wdata  => data_wdata,
            i_data_wait   => reg_wait,
            i_data_rvalid => reg_rvalid,
            i_data_rdata  => data_rdata,
            o_csr_read    => csr_read,
            o_csr_write   => csr_write,
            o_csr_addr    => csr_addr,
            o_csr_wdata   => csr_wdata,
            i_csr_rdata   => csr_rdata
        );

    u_xip : entity work.max10_xip
        generic map (
            data_addr_bits => data_addr_bits,
            window_bytes   => window_bytes,
            base_word      => base_word
        )
        port map (
            i_clk         => i_clk,
            i_rst         => i_rst,
            i_addr        => i_addr,
            i_rden        => i_rden,
            i_line        => i_line,
            i_advance     => i_advance,
            o_ready       => o_ready,
            o_busy        => o_busy,
            o_rdata       => o_rdata,
            o_rdata_x     => o_rdata_x,
            o_data_read   => xip_read,
            o_data_addr   => xip_addr,
            i_data_wait   => xip_wait,
            i_data_rvalid => xip_rvalid,
            i_data_rdata  => data_rdata
        );

    u_model : entity work.max10_flash_model
        generic map (
            data_addr_bits => data_addr_bits,
            sector_words   => sector_words,
            write_cycles   => write_cycles
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
