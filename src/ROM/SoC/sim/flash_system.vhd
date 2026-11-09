-- =============================================================================
-- Topo de simulação da FLASH com o carregador
--
-- O modelo da FLASH de duas portas, o carregador e a porta JTAG dele, ligados
-- como no topo da FPGA: a porta A é lida pelo estágio IF, a porta B é do estágio
-- MEM até o comando de parada e depois é do carregador. As portas jtag_*
-- representam uma instância do Virtual JTAG (veja flash_jtag_core) e podem ficar
-- sem conexão.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.utils_pkg.all;

entity flash_system is
    generic (
        -- Tamanho da FLASH em bytes, uma potência de dois.
        size_bytes : positive := 32768;
        -- Arquivo com o conteúdo inicial, uma palavra de 32 bits por linha em hexadecimal.
        rom_file   : string   := ""
    );
    port (
        -- Clock da porta A, o do estágio IF.
        i_clk_if      : in    std_logic;
        -- Clock da porta B, o do estágio MEM e do carregador.
        i_clk_mem     : in    std_logic;
        -- Reset do carregador, ativo em '1'.
        i_rst         : in    std_logic;
        -- Índice da palavra lida pelo estágio IF.
        i_if_address  : in    std_logic_vector(log2_exact(size_bytes) - 3 downto 0);
        -- Habilita de leitura do estágio IF.
        i_if_rden     : in    std_logic;
        -- Palavra lida pelo estágio IF.
        o_if_q        : out   std_logic_vector(31 downto 0);
        -- Índice da palavra lida pelo estágio MEM.
        i_mem_address : in    std_logic_vector(log2_exact(size_bytes) - 3 downto 0);
        -- Habilita de leitura do estágio MEM.
        i_mem_rden    : in    std_logic;
        -- Palavra lida pelo estágio MEM.
        o_mem_q       : out   std_logic_vector(31 downto 0);
        -- Núcleo parado ('1'): é o que se liga ao reset do núcleo.
        o_halt        : out   std_logic;

        -- Clock da cadeia JTAG.
        i_jtag_tck       : in    std_logic                    := '0';
        -- Dado serial vindo do hospedeiro.
        i_jtag_tdi       : in    std_logic                    := '0';
        -- Dado serial para o hospedeiro.
        o_jtag_tdo       : out   std_logic;
        -- Registrador de instrução do Virtual JTAG.
        i_jtag_ir_in     : in    std_logic_vector(1 downto 0) := "00";
        -- Estado Capture-DR da cadeia virtual.
        i_jtag_state_cdr : in    std_logic                    := '0';
        -- Estado Shift-DR da cadeia virtual.
        i_jtag_state_sdr : in    std_logic                    := '0';
        -- Estado Update-DR da cadeia virtual.
        i_jtag_state_udr : in    std_logic                    := '0';
        -- Estado Update-IR da cadeia virtual.
        i_jtag_state_uir : in    std_logic                    := '0'
    );
end entity flash_system;

architecture rtl of flash_system is

    -- Largura em bits do índice de palavra.
    constant ADDR_WIDTH : positive := log2_exact(size_bytes) - 2;

    -- Alternância de comando da porta JTAG ao carregador.
    signal cmd_tog    : std_logic;
    -- Operação do comando.
    signal op         : std_logic_vector(3 downto 0);
    -- Endereço do comando.
    signal addr       : std_logic_vector(23 downto 0);
    -- Dado do comando.
    signal data       : std_logic_vector(31 downto 0);
    -- Alternância de resposta do carregador.
    signal done_tog   : std_logic;
    -- Endereço da resposta.
    signal rsp_addr   : std_logic_vector(23 downto 0);
    -- Dado da resposta.
    signal rsp_data   : std_logic_vector(31 downto 0);
    -- Status da resposta.
    signal rsp_status : std_logic_vector(7 downto 0);
    -- Índice de palavra aplicado à porta B.
    signal address_b  : std_logic_vector(ADDR_WIDTH - 1 downto 0);
    -- Leitura da porta B.
    signal rden_b     : std_logic;
    -- Escrita da porta B.
    signal wren_b     : std_logic;
    -- Dado de escrita da porta B.
    signal data_b     : std_logic_vector(31 downto 0);
    -- Palavra lida pela porta B.
    signal q_b        : std_logic_vector(31 downto 0);

begin

    o_mem_q <= q_b;

    u_flash : entity work.flash_simulation
        generic map (
            size_bytes => size_bytes, rom_file => rom_file
        )
        port map (
            i_clk_a     => i_clk_if,
            i_address_a => i_if_address,
            i_rden_a    => i_if_rden,
            o_q_a       => o_if_q,
            i_clk_b     => i_clk_mem,
            i_address_b => address_b,
            i_rden_b    => rden_b,
            i_wren_b    => wren_b,
            i_data_b    => data_b,
            o_q_b       => q_b
        );

    u_loader : entity work.flash_loader
        generic map (
            addr_width => ADDR_WIDTH
        )
        port map (
            i_clk         => i_clk_mem,
            i_rst         => i_rst,
            i_cmd_tog     => cmd_tog,
            o_done_tog    => done_tog,
            i_op          => op,
            i_addr        => addr,
            i_data        => data,
            o_rsp_addr    => rsp_addr,
            o_rsp_data    => rsp_data,
            o_rsp_status  => rsp_status,
            o_halt        => o_halt,
            i_mem_address => i_mem_address,
            i_mem_rden    => i_mem_rden,
            o_address_b   => address_b,
            o_rden_b      => rden_b,
            o_wren_b      => wren_b,
            o_data_b      => data_b,
            i_q_b         => q_b
        );

    u_jtag : entity work.flash_jtag_core
        port map (
            i_tck        => i_jtag_tck,
            i_tdi        => i_jtag_tdi,
            o_tdo        => o_jtag_tdo,
            i_ir_in      => i_jtag_ir_in,
            i_state_cdr  => i_jtag_state_cdr,
            i_state_sdr  => i_jtag_state_sdr,
            i_state_udr  => i_jtag_state_udr,
            i_state_uir  => i_jtag_state_uir,
            o_cmd_tog    => cmd_tog,
            o_op         => op,
            o_addr       => addr,
            o_data       => data,
            i_done_tog   => done_tog,
            i_rsp_addr   => rsp_addr,
            i_rsp_data   => rsp_data,
            i_rsp_status => rsp_status
        );

end architecture rtl;
