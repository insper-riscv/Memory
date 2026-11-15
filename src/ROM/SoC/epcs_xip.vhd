-- =============================================================================
-- Adaptador de leitura direta (XIP) da flash serial EPCS, só instruções
--
-- Atende o SoC com o contrato do flash_chip, o mesmo do nor_flash_ctrl (pedido de
-- palavra ou de linha de quatro palavras, handshake o_ready/i_advance), e lê o chip
-- por SPI com um quadro READ (0x03) ou FAST_READ (0x0B) por pedido, pelo epcs_spi.
-- Só lê: o módulo nunca monta outro código de operação, então nunca escreve, apaga
-- nem habilita escrita. Os pinos SPI são dele; uma flash serial que também recebe
-- gravação pelo epcs_ctrl precisa de um só dono dos pinos por vez, escolhido pelo topo.
--
-- Janela. O chip aparece ao SoC como window_bytes bytes, uma potência de dois, e o
-- byte zero da janela é o byte chip_offset do chip. Com chip_offset igual ao início da
-- região de usuário, o bitstream, que fica abaixo, nunca é alcançado. Uma leitura cujos
-- bits 25 até o fim do tamanho da janela não são todos zero está fora dela e devolve
-- zero sem tocar no chip.
--
-- Quadro. A palavra pedida começa no endereço alinhado em 4 bytes e a linha no
-- alinhado em 16 bytes, e o quadro traz 4 ou 16 bytes de dado, com o byte de menor
-- endereço nos bits mais baixos da palavra 0. O o_ready sobe no fim do quadro, depois
-- do intervalo de CS# alto do epcs_spi, e fica em nível alto até i_advance.
--
-- Latência. Um quadro leva 8 bits de instrução, 24 de endereço (mais 8 de byte dummy
-- no FAST_READ) e 8 bits por byte lido, cada bit em 2 x clk_div ciclos de i_clk, mais o
-- intervalo de gap_ticks meios períodos. Com clk_div 1, uma palavra leva cerca de 130
-- ciclos e uma linha cerca de 340, centenas de ciclos por linha que só valem atrás de
-- cache. O pedido seguinte espera o fim do quadro.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.config_pkg.all;
use work.utils_pkg.all;

entity epcs_xip is
    generic (
        -- Tamanho da janela vista pelo SoC em bytes, uma potência de dois de 16 bytes a 16 MB.
        window_bytes : positive := 4194304;
        -- Byte do chip que é o byte zero da janela, múltiplo de 16 (o início da região de usuário protege o bitstream).
        chip_offset  : natural  := 4194304;
        -- Bordas de i_clk em cada meio período do clock SPI.
        clk_div      : positive := 2;
        -- Meios períodos com CS# alto depois de cada quadro.
        gap_ticks    : positive := 8;
        -- Lê com FAST_READ (um byte dummy, para clock SPI acima do limite do READ) em vez de READ.
        fast_read    : boolean  := false
    );
    port (
        -- Clock do módulo.
        i_clk     : in    std_logic;
        -- Reset síncrono, ativo em '1'.
        i_rst     : in    std_logic;

        -- Leitura: endereço do pedido.
        i_addr    : in    addr_t;
        -- Leitura: pedido de leitura ('1' = lê).
        i_rden    : in    std_logic;
        -- Leitura: pedido de linha de quatro palavras ('1') ou de uma palavra ('0').
        i_line    : in    std_logic;
        -- Leitura: o pedido foi consumido neste ciclo, o adaptador pode aceitar outro.
        i_advance : in    std_logic;
        -- Leitura: pedido concluído, o dado lido é válido ('1').
        o_ready   : out   std_logic;
        -- Leitura: o adaptador está esperando o chip por um pedido ('1' em cada ciclo de espera).
        o_busy    : out   std_logic;
        -- Leitura: palavra pedida (a palavra 0 da linha).
        o_rdata   : out   word_t;
        -- Leitura: palavras 1 a 3 da linha, a palavra 1 nos bits mais baixos.
        o_rdata_x : out   std_logic_vector(3 * XLEN - 1 downto 0);

        -- SPI: clock.
        o_sck     : out   std_logic;
        -- SPI: seleção do chip, ativa em '0'.
        o_cs_n    : out   std_logic;
        -- SPI: dado para o chip.
        o_mosi    : out   std_logic;
        -- SPI: dado do chip.
        i_miso    : in    std_logic
    );
end entity epcs_xip;

architecture rtl of epcs_xip is

    -- Código da operação READ do epcs_spi.
    constant OP_READ      : std_logic_vector(2 downto 0) := "100";
    -- Código da operação FAST_READ do epcs_spi.
    constant OP_FAST_READ : std_logic_vector(2 downto 0) := "101";

    -- Bits de endereço da janela (falha se window_bytes não for uma potência de dois).
    constant WINDOW_BITS : natural := log2_exact(window_bytes);

    -- Estados: livre, pedido do quadro ao mestre SPI, recepção dos bytes e pedido concluído.
    type state_t is (S_IDLE, S_REQ, S_RX, S_DONE);

    -- Estado atual.
    signal st       : state_t                       := S_IDLE;
    -- O pedido de leitura em i_addr está fora da janela do chip.
    signal rd_outw  : std_logic;
    -- Pulso de um ciclo que pede o quadro ao mestre SPI.
    signal spi_req  : std_logic;
    -- Código da operação do quadro (sempre READ ou FAST_READ).
    signal spi_op   : std_logic_vector(2 downto 0);
    -- Endereço de byte do chip no quadro, registrado.
    signal spi_addr : std_logic_vector(23 downto 0) := (others => '0');
    -- Bytes de dado do quadro: 4 para uma palavra, 16 para uma linha.
    signal spi_len  : std_logic_vector(8 downto 0)  := (others => '0');
    -- O quadro terminou, com o intervalo de CS# alto.
    signal spi_done : std_logic;
    -- Byte recebido válido.
    signal rx_v     : std_logic;
    -- Índice do byte recebido no dado do quadro.
    signal rx_idx   : std_logic_vector(7 downto 0);
    -- Byte recebido.
    signal rx_data  : std_logic_vector(7 downto 0);
    -- Bytes lidos: a palavra 0 nos bits 31 a 0 e as palavras 1 a 3 acima.
    signal line_q   : std_logic_vector(4 * XLEN - 1 downto 0) := (others => '0');

begin

    -- A linha de 4 palavras e a ordem dos bytes supõem a palavra de 32 bits e só elaboram com XLEN = 32.
    assert XLEN = 32
        report "este bloco só elabora com XLEN = 32"
        severity failure;

    assert window_bytes >= 16 and window_bytes <= 2 ** 24
        report "window_bytes must be between 16 bytes and 16 MB"
        severity failure;
    assert chip_offset mod 16 = 0
        report "chip_offset must be a multiple of 16"
        severity failure;
    assert chip_offset + window_bytes <= 2 ** 24
        report "chip_offset + window_bytes must fit the 24-bit address of the chip"
        severity failure;

    o_ready   <= '1' when st = S_DONE else '0';
    o_busy    <= '1' when st = S_REQ or st = S_RX else '0';
    o_rdata   <= line_q(XLEN - 1 downto 0);
    o_rdata_x <= line_q(4 * XLEN - 1 downto XLEN);

    -- Um pedido de leitura está fora da janela quando os bits 25 até o fim do tamanho não são todos zero.
    rd_outw  <= '1' when unsigned(i_addr(25 downto WINDOW_BITS)) /= 0 else '0';
    spi_req  <= '1' when st = S_REQ else '0';
    spi_op   <= OP_FAST_READ when fast_read else OP_READ;

    u_spi : entity work.epcs_spi
        generic map (
            clk_div   => clk_div,
            gap_ticks => gap_ticks
        )
        port map (
            i_clk      => i_clk,
            i_rst      => i_rst,
            i_req      => spi_req,
            i_op       => spi_op,
            i_addr     => spi_addr,
            i_len      => spi_len,
            o_busy     => open,
            o_done     => spi_done,
            o_rx_valid => rx_v,
            o_rx_idx   => rx_idx,
            o_rx_data  => rx_data,
            o_tx_idx   => open,
            i_tx_data  => x"00",
            o_sck      => o_sck,
            o_cs_n     => o_cs_n,
            o_mosi     => o_mosi,
            i_miso     => i_miso
        );

    p_xip_fsm : process (i_clk) is

        -- Endereço de byte do pedido, alinhado a palavra ou a linha.
        variable rd_addr : unsigned(ADDR_BITS - 1 downto 0);
        -- Endereço do chip: deslocamento do pedido na janela somado a chip_offset.
        variable chip_a  : unsigned(23 downto 0);

    begin

        if rising_edge(i_clk) then
            if i_rst = '1' then
                st <= S_IDLE;
            else

                case st is

                    when S_IDLE =>

                        if i_rden = '1' then
                            if i_line = '1' then
                                rd_addr := unsigned(i_addr(31 downto 4)) & "0000";
                                spi_len <= std_logic_vector(to_unsigned(16, 9));
                            else
                                rd_addr := unsigned(i_addr(31 downto 2)) & "00";
                                spi_len <= std_logic_vector(to_unsigned(4, 9));
                            end if;
                            if rd_outw = '1' then
                                if i_line = '1' then
                                    line_q <= (others => '0');
                                else
                                    line_q(XLEN - 1 downto 0) <= (others => '0');
                                end if;
                                st <= S_DONE;
                            else
                                chip_a   := to_unsigned(chip_offset, 24) + resize(rd_addr(WINDOW_BITS - 1 downto 0), 24);
                                spi_addr <= std_logic_vector(chip_a);
                                st       <= S_REQ;
                            end if;
                        end if;

                    when S_REQ =>

                        st <= S_RX;

                    when S_RX =>

                        if rx_v = '1' then

                            for i in 0 to 15 loop

                                if to_integer(unsigned(rx_idx)) = i then
                                    line_q(8 * i + 7 downto 8 * i) <= rx_data;
                                end if;

                            end loop;

                        end if;
                        if spi_done = '1' then
                            st <= S_DONE;
                        end if;

                    when S_DONE =>

                        if i_advance = '1' then
                            st <= S_IDLE;
                        end if;

                end case;

            end if;
        end if;

    end process p_xip_fsm;

end architecture rtl;
