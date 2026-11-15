-- =============================================================================
-- Invólucro fino do IP de flash on-chip do MAX 10 (DE10-Lite)
--
-- Instancia por component o IP max10_flash_core, gerado pelo Platform Designer a
-- partir de max10_flash_core.tcl (a megafunção altera_onchip_flash da 10M50DAF484C7G,
-- imagem única sem compressão, cuja interface de dados tem 17 bits de endereço de
-- palavra), e expõe as portas com os nomes e a polaridade do max10_flash: o reset é
-- ativo em '1' (o IP o quer em '0'), o burst é sempre de uma palavra, e a espera da
-- interface de dados sai com o nome i_data_wait. Não há lógica aqui.
--
-- Setores do IP gerado (palavras de 32 bits do espaço de dados): 1 é a UFM1 (0 a 8191),
-- 2 é a UFM0 (8192 a 16383) e 3 é a CFM2 (16384 a 114687), só de leitura nessa geração; o
-- IP classifica os setores 4 e 5 (CFM1 e CFM0) como configuração e os oculta nesse modo. O mesmo IP
-- gerado não é portável a outro dispositivo: outro MAX 10 pede outra geração.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity max10_flash_ip is
    port (
        -- Clock do IP.
        i_clk : in    std_logic;
        -- Reset, ativo em '1'.
        i_rst : in    std_logic;

        -- Dados: pedido de leitura.
        i_data_read   : in    std_logic;
        -- Dados: pedido de escrita.
        i_data_write  : in    std_logic;
        -- Dados: endereço de palavra.
        i_data_addr   : in    std_logic_vector(16 downto 0);
        -- Dados: palavra a escrever.
        i_data_wdata  : in    std_logic_vector(31 downto 0);
        -- Dados: o pedido não foi aceito ('1').
        o_data_wait   : out   std_logic;
        -- Dados: palavra lida válida.
        o_data_rvalid : out   std_logic;
        -- Dados: palavra lida.
        o_data_rdata  : out   std_logic_vector(31 downto 0);

        -- CSR: pedido de leitura.
        i_csr_read  : in    std_logic;
        -- CSR: pedido de escrita.
        i_csr_write : in    std_logic;
        -- CSR: registrador, '0' estado e '1' controle.
        i_csr_addr  : in    std_logic;
        -- CSR: palavra a escrever.
        i_csr_wdata : in    std_logic_vector(31 downto 0);
        -- CSR: palavra lida, valida uma borda depois do pedido.
        o_csr_rdata : out   std_logic_vector(31 downto 0)
    );
end entity max10_flash_ip;

architecture rtl of max10_flash_ip is

    -- IP gerado pelo Platform Designer (max10_flash_core.qip).
    component max10_flash_core is
        port (
            clk_clk            : in  std_logic                     := 'X';
            csr_address        : in  std_logic                     := 'X';
            csr_read           : in  std_logic                     := 'X';
            csr_writedata      : in  std_logic_vector(31 downto 0) := (others => 'X');
            csr_write          : in  std_logic                     := 'X';
            csr_readdata       : out std_logic_vector(31 downto 0);
            data_address       : in  std_logic_vector(16 downto 0) := (others => 'X');
            data_read          : in  std_logic                     := 'X';
            data_writedata     : in  std_logic_vector(31 downto 0) := (others => 'X');
            data_write         : in  std_logic                     := 'X';
            data_readdata      : out std_logic_vector(31 downto 0);
            data_waitrequest   : out std_logic;
            data_readdatavalid : out std_logic;
            data_burstcount    : in  std_logic_vector(3 downto 0)  := (others => 'X');
            reset_reset_n      : in  std_logic                     := 'X'
        );
    end component max10_flash_core;

    -- Reset do IP, ativo em '0'.
    signal reset_n : std_logic;

begin

    reset_n <= not i_rst;

    u_core : component max10_flash_core
        port map (
            clk_clk            => i_clk,
            csr_address        => i_csr_addr,
            csr_read           => i_csr_read,
            csr_writedata      => i_csr_wdata,
            csr_write          => i_csr_write,
            csr_readdata       => o_csr_rdata,
            data_address       => i_data_addr,
            data_read          => i_data_read,
            data_writedata     => i_data_wdata,
            data_write         => i_data_write,
            data_readdata      => o_data_rdata,
            data_waitrequest   => o_data_wait,
            data_readdatavalid => o_data_rvalid,
            data_burstcount    => "0001",
            reset_reset_n      => reset_n
        );

end architecture rtl;
