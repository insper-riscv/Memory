-- =============================================================================
-- Mestre SPI da flash serial EPCS (um quadro por pedido)
--
-- Executa um comando da flash serial EPCS (a família M25P que guarda o bitstream
-- da DE0-CV, DE0-Nano, DE2-115 e DE10-Nano) em SPI modo 0: o clock fica baixo em
-- repouso, o dado sai na descida e o chip amostra na subida, e o mestre amostra
-- MISO na subida. Um pedido (i_req) leva o código da operação, o endereço de byte
-- e a quantidade de bytes de dado, e o módulo monta o quadro inteiro, de CS# baixo a CS# alto:
--
--   código  operação          quadro enviado                     dado
--   1       RDID  (0x9F)      código                             recebe 3 bytes
--   2       RDSR  (0x05)      código                             recebe 1 byte
--   3       WREN  (0x06)      código                             nenhum
--   4       READ  (0x03)      código e endereço de 24 bits       recebe i_len bytes
--   5       FAST_READ (0x0B)  código, endereço, 1 byte dummy     recebe i_len bytes
--   6       PP    (0x02)      código e endereço de 24 bits       envia i_len bytes
--   7       SE    (0xD8)      código e endereço de 24 bits       nenhum
--
-- O módulo nunca envia outro código: não há apagar o chip todo nem escrever o
-- registrador de estado. Cada byte recebido sai num pulso (o_rx_valid) com o
-- índice dele no dado; cada byte a enviar é pedido pelo índice em o_tx_idx, e o
-- dono do buffer devolve o byte em i_tx_data até tx_wait_clocks bordas depois de o
-- índice ficar estável. O quadro termina com CS# alto por gap_ticks meios períodos,
-- que cobre o tempo mínimo de CS# em nível alto do chip, e então sobe o_done.
--
-- Clock SPI. Cada meio período de o_sck dura clk_div bordas de i_clk, então
-- o_sck vale i_clk dividido por 2 * clk_div. Um pedido só é aceito com o_busy baixo.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity epcs_spi is
    generic (
        -- Bordas de i_clk em cada meio período de o_sck, no mínimo 1.
        clk_div       : positive := 2;
        -- Meios períodos com CS# alto depois de cada quadro.
        gap_ticks     : positive := 8;
        -- Bordas de espera por byte a enviar, depois de o índice ficar estável.
        tx_wait_clocks : positive := 3
    );
    port (
        -- Clock do módulo.
        i_clk : in    std_logic;
        -- Reset síncrono, ativo em '1'.
        i_rst : in    std_logic;

        -- Pedido: pulso de um ciclo que inicia um quadro.
        i_req  : in    std_logic;
        -- Pedido: código da operação, de 1 a 7 (outro valor é ignorado).
        i_op   : in    std_logic_vector(2 downto 0);
        -- Pedido: endereço de byte de 24 bits, nas operações que o levam.
        i_addr : in    std_logic_vector(23 downto 0);
        -- Pedido: bytes de dado do READ, do FAST_READ e do PP, de 1 a 256.
        i_len  : in    std_logic_vector(8 downto 0);
        -- Um quadro está em andamento ('1').
        o_busy : out   std_logic;
        -- Pulso de um ciclo quando o quadro termina.
        o_done : out   std_logic;

        -- Recepção: pulso de um ciclo com um byte lido do chip.
        o_rx_valid : out   std_logic;
        -- Recepção: índice do byte no dado do quadro.
        o_rx_idx   : out   std_logic_vector(7 downto 0);
        -- Recepção: byte lido.
        o_rx_data  : out   std_logic_vector(7 downto 0);

        -- Envio: índice do byte de dado a enviar.
        o_tx_idx  : out   std_logic_vector(7 downto 0);
        -- Envio: byte de dado a enviar, válido depois de tx_wait_clocks bordas do índice estável.
        i_tx_data : in    std_logic_vector(7 downto 0);

        -- SPI: clock.
        o_sck  : out   std_logic;
        -- SPI: seleção do chip, ativa em '0'.
        o_cs_n : out   std_logic;
        -- SPI: dado para o chip.
        o_mosi : out   std_logic;
        -- SPI: dado do chip.
        i_miso : in    std_logic
    );
end entity epcs_spi;

architecture rtl of epcs_spi is

    -- Código da operação RDID.
    constant OP_RDID      : std_logic_vector(2 downto 0) := "001";
    -- Código da operação RDSR.
    constant OP_RDSR      : std_logic_vector(2 downto 0) := "010";
    -- Código da operação WREN.
    constant OP_WREN      : std_logic_vector(2 downto 0) := "011";
    -- Código da operação READ.
    constant OP_READ      : std_logic_vector(2 downto 0) := "100";
    -- Código da operação FAST_READ.
    constant OP_FAST_READ : std_logic_vector(2 downto 0) := "101";
    -- Código da operação PP.
    constant OP_PP        : std_logic_vector(2 downto 0) := "110";
    -- Código da operação SE.
    constant OP_SE        : std_logic_vector(2 downto 0) := "111";

    -- Instrução RDID da flash.
    constant INS_RDID      : std_logic_vector(7 downto 0) := x"9F";
    -- Instrução RDSR da flash.
    constant INS_RDSR      : std_logic_vector(7 downto 0) := x"05";
    -- Instrução WREN da flash.
    constant INS_WREN      : std_logic_vector(7 downto 0) := x"06";
    -- Instrução READ da flash.
    constant INS_READ      : std_logic_vector(7 downto 0) := x"03";
    -- Instrução FAST_READ da flash.
    constant INS_FAST_READ : std_logic_vector(7 downto 0) := x"0B";
    -- Instrução PP da flash.
    constant INS_PP        : std_logic_vector(7 downto 0) := x"02";
    -- Instrução SE da flash.
    constant INS_SE        : std_logic_vector(7 downto 0) := x"D8";

    -- Estados: repouso, espera do dado a enviar, clock baixo, clock alto, fim do quadro e intervalo.
    type state_t is (S_IDLE, S_FETCH, S_LOW, S_HIGH, S_END, S_GAP);

    -- Estado atual.
    signal st        : state_t                      := S_IDLE;
    -- Operação do quadro.
    signal op        : std_logic_vector(2 downto 0) := (others => '0');
    -- Endereço do quadro.
    signal addr_q    : std_logic_vector(23 downto 0) := (others => '0');
    -- Bytes de dado do quadro.
    signal data_len  : natural range 0 to 256       := 0;
    -- Bytes de cabeçalho do quadro: código, endereço e dummy.
    signal hdr_len   : natural range 1 to 5         := 1;
    -- Posição do byte atual no quadro, a partir de zero.
    signal pos       : natural range 0 to 261       := 0;
    -- Registrador de deslocamento de envio.
    signal tx_shift  : std_logic_vector(7 downto 0) := (others => '0');
    -- Registrador de deslocamento de recepção.
    signal rx_shift  : std_logic_vector(7 downto 0) := (others => '0');
    -- Bits já enviados do byte atual.
    signal bit_cnt   : natural range 0 to 8         := 0;
    -- Contador do meio período.
    signal div_cnt   : natural range 0 to clk_div   := 0;
    -- Contador de espera do byte a enviar e do intervalo.
    signal wait_cnt  : natural range 0 to 255       := 0;
    -- Clock SPI.
    signal sck_q     : std_logic                    := '0';
    -- Seleção do chip.
    signal cs_q      : std_logic                    := '1';
    -- Dado para o chip.
    signal mosi_q    : std_logic                    := '0';
    -- Recepção válida.
    signal rx_v_q    : std_logic                    := '0';
    -- Índice do byte recebido.
    signal rx_i_q    : std_logic_vector(7 downto 0) := (others => '0');
    -- Byte recebido.
    signal rx_d_q    : std_logic_vector(7 downto 0) := (others => '0');
    -- Fim do quadro.
    signal done_q    : std_logic                    := '0';
    -- Índice do byte de dado a enviar.
    signal tx_idx_q  : std_logic_vector(7 downto 0) := (others => '0');

    -- Byte do cabeçalho na posição p, para a operação e o endereço dados.
    function header_byte (o : std_logic_vector(2 downto 0); a : std_logic_vector(23 downto 0); p : natural)
        return std_logic_vector is
    begin
        if p = 0 then
            case o is
                when OP_RDID      => return INS_RDID;
                when OP_RDSR      => return INS_RDSR;
                when OP_WREN      => return INS_WREN;
                when OP_READ      => return INS_READ;
                when OP_FAST_READ => return INS_FAST_READ;
                when OP_PP        => return INS_PP;
                when others       => return INS_SE;
            end case;
        elsif p = 1 then
            return a(23 downto 16);
        elsif p = 2 then
            return a(15 downto 8);
        elsif p = 3 then
            return a(7 downto 0);
        end if;
        return x"00";
    end function header_byte;

begin

    o_busy     <= '0' when st = S_IDLE else '1';
    o_done     <= done_q;
    o_rx_valid <= rx_v_q;
    o_rx_idx   <= rx_i_q;
    o_rx_data  <= rx_d_q;
    o_tx_idx   <= tx_idx_q;
    o_sck      <= sck_q;
    o_cs_n     <= cs_q;
    o_mosi     <= mosi_q;

    p_spi : process (i_clk) is
        -- Fim do meio período.
        variable tick  : boolean;
        -- O byte atual é um byte de dado a receber.
        variable is_rx : boolean;
        -- O byte atual é um byte de dado a enviar.
        variable is_tx : boolean;
        -- Byte de cabeçalho a enviar.
        variable hb    : std_logic_vector(7 downto 0);
        -- Total de bytes do quadro.
        variable total : natural;
    begin
        if rising_edge(i_clk) then
            rx_v_q <= '0';
            done_q <= '0';
            if i_rst = '1' then
                st      <= S_IDLE;
                sck_q   <= '0';
                cs_q    <= '1';
                mosi_q  <= '0';
                div_cnt <= 0;
            else
                tick := div_cnt = clk_div - 1;
                if tick then
                    div_cnt <= 0;
                else
                    div_cnt <= div_cnt + 1;
                end if;
                total := hdr_len + data_len;
                is_rx := pos >= hdr_len and (op = OP_READ or op = OP_FAST_READ or op = OP_RDID or op = OP_RDSR);
                is_tx := pos >= hdr_len and op = OP_PP;

                case st is
                    when S_IDLE =>
                        div_cnt <= 0;
                        if i_req = '1' and unsigned(i_op) /= 0 then
                            op      <= i_op;
                            addr_q  <= i_addr;
                            pos     <= 0;
                            bit_cnt <= 0;
                            case i_op is
                                when OP_RDID =>
                                    hdr_len  <= 1;
                                    data_len <= 3;
                                when OP_RDSR =>
                                    hdr_len  <= 1;
                                    data_len <= 1;
                                when OP_WREN =>
                                    hdr_len  <= 1;
                                    data_len <= 0;
                                when OP_READ =>
                                    hdr_len  <= 4;
                                    data_len <= to_integer(unsigned(i_len));
                                when OP_FAST_READ =>
                                    hdr_len  <= 5;
                                    data_len <= to_integer(unsigned(i_len));
                                when OP_PP =>
                                    hdr_len  <= 4;
                                    data_len <= to_integer(unsigned(i_len));
                                when others =>
                                    hdr_len  <= 4;
                                    data_len <= 0;
                            end case;
                            cs_q     <= '0';
                            tx_idx_q <= (others => '0');
                            wait_cnt <= 0;
                            st       <= S_FETCH;
                        end if;
                    when S_FETCH =>
                        -- Carrega o byte: do cabeçalho de imediato, ou do buffer depois da espera.
                        if is_tx then
                            tx_idx_q <= std_logic_vector(to_unsigned(pos - hdr_len, 8));
                            if wait_cnt = tx_wait_clocks then
                                tx_shift <= i_tx_data;
                                mosi_q   <= i_tx_data(7);
                                wait_cnt <= 0;
                                div_cnt  <= 0;
                                bit_cnt  <= 0;
                                st       <= S_LOW;
                            else
                                wait_cnt <= wait_cnt + 1;
                            end if;
                        else
                            hb       := header_byte(op, addr_q, pos);
                            tx_shift <= hb;
                            mosi_q   <= hb(7);
                            div_cnt  <= 0;
                            bit_cnt  <= 0;
                            st       <= S_LOW;
                        end if;
                    when S_LOW =>
                        -- Clock baixo, dado estável: no fim do meio período o clock sobe e o mestre amostra.
                        if tick then
                            sck_q    <= '1';
                            rx_shift <= rx_shift(6 downto 0) & i_miso;
                            bit_cnt  <= bit_cnt + 1;
                            st       <= S_HIGH;
                        end if;
                    when S_HIGH =>
                        -- Clock alto: no fim do meio período o clock desce e o dado seguinte sai.
                        if tick then
                            sck_q <= '0';
                            if bit_cnt = 8 then
                                if is_rx then
                                    rx_v_q <= '1';
                                    rx_i_q <= std_logic_vector(to_unsigned(pos - hdr_len, 8));
                                    rx_d_q <= rx_shift;
                                end if;
                                if pos + 1 = total then
                                    st <= S_END;
                                else
                                    pos      <= pos + 1;
                                    wait_cnt <= 0;
                                    st       <= S_FETCH;
                                end if;
                            else
                                tx_shift <= tx_shift(6 downto 0) & '0';
                                mosi_q   <= tx_shift(6);
                                st       <= S_LOW;
                            end if;
                        end if;
                    when S_END =>
                        -- Último byte terminado: CS# sobe depois de um meio período com o clock baixo.
                        if tick then
                            cs_q     <= '1';
                            mosi_q   <= '0';
                            wait_cnt <= 0;
                            st       <= S_GAP;
                        end if;
                    when S_GAP =>
                        if tick then
                            if wait_cnt = gap_ticks - 1 then
                                done_q <= '1';
                                st     <= S_IDLE;
                            else
                                wait_cnt <= wait_cnt + 1;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process p_spi;

end architecture rtl;
