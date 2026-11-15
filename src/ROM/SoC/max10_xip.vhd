-- =============================================================================
-- Adaptador de leitura direta (XIP) da flash interna do MAX 10, só instruções
--
-- Atende o SoC com o contrato do flash_chip, o mesmo do nor_flash_ctrl (pedido de
-- palavra ou de linha de quatro palavras, handshake o_ready/i_advance), e lê a
-- megafunção de flash on-chip (altera_onchip_flash) pela interface Avalon-MM de dados,
-- uma palavra por leitura, com waitrequest e readdatavalid. Só lê: o módulo não tem
-- porta de escrita nem de CSR, então nunca grava, apaga nem muda a proteção.
--
-- A interface de dados tem um só dono por vez. Quando o max10_flash (banco de
-- registradores, que grava e apaga) usa a mesma megafunção, o topo escolhe qual dos dois
-- liga as portas Avalon; este módulo vê i_data_wait em '1' enquanto não é o escolhido.
--
-- Janela. O chip aparece ao SoC como window_bytes bytes, uma potência de dois, e a
-- palavra zero da janela é a palavra base_word do espaço de dados da megafunção. Uma
-- leitura cujos bits 25 até o fim do tamanho da janela não são todos zero está fora
-- dela e devolve zero sem tocar na megafunção.
--
-- Leitura. A palavra pedida é a de endereço alinhado em 4 bytes e a linha começa no
-- alinhado em 16 bytes, e as palavras saem em ordem crescente de endereço, cada uma
-- em uma leitura Avalon. O pedido de leitura fica ativo até a espera cair, e o dado
-- vem com a validade, quando o módulo passa à palavra seguinte. O o_ready sobe com a última
-- palavra capturada e fica em nível alto até i_advance. A latência de cada palavra é a da
-- megafunção, que o modelo de simulação parametriza.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.config_pkg.all;
use work.utils_pkg.all;

entity max10_xip is
    generic (
        -- Largura do endereço de palavra da interface de dados da megafunção (17 bits na 10M50, imagem única).
        data_addr_bits : positive := 17;
        -- Tamanho da janela vista pelo SoC em bytes, uma potência de dois de 16 bytes em diante.
        window_bytes   : positive := 262144;
        -- Palavra do espaço de dados da megafunção que é a palavra zero da janela (16384 é o início da CFM2).
        base_word      : natural  := 16384
    );
    port (
        -- Clock do módulo, o mesmo da megafunção.
        i_clk         : in    std_logic;
        -- Reset síncrono, ativo em '1'.
        i_rst         : in    std_logic;

        -- Leitura: endereço do pedido.
        i_addr        : in    addr_t;
        -- Leitura: pedido de leitura ('1' = lê).
        i_rden        : in    std_logic;
        -- Leitura: pedido de linha de quatro palavras ('1') ou de uma palavra ('0').
        i_line        : in    std_logic;
        -- Leitura: o pedido foi consumido neste ciclo, o adaptador pode aceitar outro.
        i_advance     : in    std_logic;
        -- Leitura: pedido concluído, o dado lido é válido ('1').
        o_ready       : out   std_logic;
        -- Leitura: o adaptador está esperando a megafunção por um pedido ('1' em cada ciclo de espera).
        o_busy        : out   std_logic;
        -- Leitura: palavra pedida (a palavra 0 da linha).
        o_rdata       : out   word_t;
        -- Leitura: palavras 1 a 3 da linha, a palavra 1 nos bits mais baixos.
        o_rdata_x     : out   std_logic_vector(3 * XLEN - 1 downto 0);

        -- Megafunção, dados: pedido de leitura, mantido até a espera cair.
        o_data_read   : out   std_logic;
        -- Megafunção, dados: endereço de palavra.
        o_data_addr   : out   std_logic_vector(data_addr_bits - 1 downto 0);
        -- Megafunção, dados: o pedido ainda não foi aceito ('1').
        i_data_wait   : in    std_logic;
        -- Megafunção, dados: palavra lida válida ('1').
        i_data_rvalid : in    std_logic;
        -- Megafunção, dados: palavra lida.
        i_data_rdata  : in    std_logic_vector(31 downto 0)
    );
end entity max10_xip;

architecture rtl of max10_xip is

    -- Bits de endereço da janela (falha se window_bytes não for uma potência de dois).
    constant WINDOW_BITS : natural := log2_exact(window_bytes);

    -- Estados: livre, pedido de leitura até a espera cair, espera do dado e pedido concluído.
    type state_t is (S_IDLE, S_ISSUE, S_WAIT, S_DONE);

    -- Estado atual.
    signal st      : state_t                                  := S_IDLE;
    -- O pedido de leitura em i_addr está fora da janela da megafunção.
    signal rd_outw : std_logic;
    -- Palavra em andamento dentro do pedido (0 a 3).
    signal word_n  : natural range 0 to 3                     := 0;
    -- Última palavra do pedido (0 para uma palavra, 3 para uma linha).
    signal last_n  : natural range 0 to 3                     := 0;
    -- Endereço de palavra da leitura em andamento, registrado.
    signal addr_q  : unsigned(data_addr_bits - 1 downto 0)    := (others => '0');
    -- Palavras lidas: a palavra 0 nos bits 31 a 0 e as palavras 1 a 3 acima.
    signal line_q  : std_logic_vector(4 * XLEN - 1 downto 0)  := (others => '0');

begin

    -- A linha de 4 palavras e a largura de 32 bits da megafunção só elaboram com XLEN = 32.
    assert XLEN = 32
        report "este bloco só elabora com XLEN = 32"
        severity failure;

    assert window_bytes >= 16 and window_bytes <= 2 ** (data_addr_bits + 2) and WINDOW_BITS <= 25
        report "window_bytes must be between 16 bytes and the data space of the megafunction"
        severity failure;
    assert base_word + window_bytes / 4 <= 2 ** data_addr_bits
        report "base_word + window words must fit the data address of the megafunction"
        severity failure;

    o_ready     <= '1' when st = S_DONE else '0';
    o_busy      <= '1' when st = S_ISSUE or st = S_WAIT else '0';
    o_rdata     <= line_q(XLEN - 1 downto 0);
    o_rdata_x   <= line_q(4 * XLEN - 1 downto XLEN);
    o_data_read <= '1' when st = S_ISSUE else '0';
    o_data_addr <= std_logic_vector(addr_q);

    -- Um pedido de leitura está fora da janela quando os bits 25 até o fim do tamanho não são todos zero.
    rd_outw <= '1' when unsigned(i_addr(25 downto WINDOW_BITS)) /= 0 else '0';

    p_xip_fsm : process (i_clk) is

        -- Palavra da janela do pedido, alinhada a palavra ou a linha.
        variable win_word : unsigned(WINDOW_BITS - 3 downto 0);

    begin

        if rising_edge(i_clk) then
            if i_rst = '1' then
                st <= S_IDLE;
            else

                case st is

                    when S_IDLE =>

                        if i_rden = '1' then
                            if i_line = '1' then
                                win_word := unsigned(i_addr(WINDOW_BITS - 1 downto 4)) & "00";
                                last_n   <= 3;
                            else
                                win_word := unsigned(i_addr(WINDOW_BITS - 1 downto 2));
                                last_n   <= 0;
                            end if;
                            word_n <= 0;
                            if rd_outw = '1' then
                                if i_line = '1' then
                                    line_q <= (others => '0');
                                else
                                    line_q(XLEN - 1 downto 0) <= (others => '0');
                                end if;
                                st <= S_DONE;
                            else
                                addr_q <= to_unsigned(base_word, data_addr_bits) + resize(win_word, data_addr_bits);
                                st     <= S_ISSUE;
                            end if;
                        end if;

                    when S_ISSUE =>

                        if i_data_wait = '0' then
                            st <= S_WAIT;
                        end if;

                    when S_WAIT =>

                        if i_data_rvalid = '1' then

                            for i in 0 to 3 loop

                                if word_n = i then
                                    line_q(32 * i + 31 downto 32 * i) <= i_data_rdata;
                                end if;

                            end loop;

                            if word_n = last_n then
                                st <= S_DONE;
                            else
                                word_n <= word_n + 1;
                                addr_q <= addr_q + 1;
                                st     <= S_ISSUE;
                            end if;
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
