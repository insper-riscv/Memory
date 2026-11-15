-- =============================================================================
-- Modelo comportamental da flash serial EPCS (só simulação)
--
-- Modela, no nível dos pinos SPI em modo 0, o chip que guarda o bitstream: o
-- registrador de estado com WIP e WEL, a leitura (READ e FAST_READ), a leitura da
-- identificação (RDID), o habilitar escrita (WREN), a gravação de página (PP) e o
-- apagar de setor (SE). A flash só leva bits de 1 para 0 na gravação, e só o apagar devolve
-- uns. A gravação dá a volta na página, como o chip. O conteúdo nasce com um padrão
-- que depende do endereço, e a parte abaixo de protect_below finge ser o bitstream.
--
-- Violações. O modelo marca o_violation, e a simulação do teste o confere em zero, quando o
-- controlador faz o que um chip real só ignora ou o que o bitstream não tolera: uma PP ou
-- SE sem WREN, uma PP ou SE que toca abaixo de protect_below, uma instrução fora da lista (o
-- apagar do chip todo, a escrita do registrador de estado), qualquer instrução que não seja RDSR
-- durante uma gravação ou um apagar em andamento, e um quadro que termina fora de byte.
--
-- Não confirmado no manual da placa: os bytes de RDID (padrão 0x20 0x20 0x17, o da família
-- M25P64) e os tempos de gravação e de apagar, que são generics de simulação.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity epcs_model is
    generic (
        -- Tamanho do chip em bytes, múltiplo do setor de 64 KB.
        size_bytes    : positive                      := 524288;
        -- Endereço abaixo do qual um PP ou SE é violação (o bitstream).
        protect_below : natural                       := 262144;
        -- Os três bytes do RDID: fabricante, tipo e capacidade.
        id_bytes      : std_logic_vector(23 downto 0) := x"202017";
        -- Duração de uma gravação de página.
        t_program     : time                          := 3 us;
        -- Duração de um apagar de setor.
        t_erase       : time                          := 20 us
    );
    port (
        -- SPI: clock.
        i_sck       : in    std_logic;
        -- SPI: seleção do chip, ativa em '0'.
        i_cs_n      : in    std_logic;
        -- SPI: dado do mestre.
        i_mosi      : in    std_logic;
        -- SPI: dado para o mestre.
        o_miso      : out   std_logic;
        -- Violação do contrato, presa até o fim da simulação.
        o_violation : out   std_logic;
        -- Escrita habilitada (WEL).
        o_wel       : out   std_logic;
        -- Gravação ou apagar em andamento (WIP).
        o_wip       : out   std_logic
    );
end entity epcs_model;

architecture sim of epcs_model is

    -- Conteúdo do chip.
    type mem_t is array (0 to size_bytes - 1) of std_logic_vector(7 downto 0);
    -- Ponteiro para o conteúdo, que fica no heap por ser grande.
    type mem_ptr_t is access mem_t;

    -- Byte inicial do chip no endereço dado.
    function pattern (a : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((a * 37 + a / 256 * 11 + 5) mod 251, 8));
    end function pattern;

    -- Gera o conteúdo inicial.
    impure function init_mem return mem_ptr_t is
        -- Conteúdo em construção.
        variable m : mem_ptr_t := new mem_t;
    begin
        for a in 0 to size_bytes - 1 loop
            m(a) := pattern(a);
        end loop;
        return m;
    end function init_mem;

    -- Buffer de uma página em gravação.
    type page_t is array (0 to 255) of std_logic_vector(7 downto 0);

    -- Escrita habilitada.
    signal wel_s       : std_logic := '0';
    -- Operação em andamento.
    signal wip_s       : std_logic := '0';
    -- Violação.
    signal violation_s : std_logic := '0';
    -- Dado para o mestre.
    signal miso_s      : std_logic := '0';

begin

    o_miso      <= miso_s;
    o_violation <= violation_s;
    o_wel       <= wel_s;
    o_wip       <= wip_s;

    p_chip : process is
        -- Bits recebidos no byte atual.
        variable bit_cnt    : natural := 0;
        -- Bytes completos do quadro.
        variable byte_cnt   : natural := 0;
        -- Byte em montagem.
        variable rx_byte    : std_logic_vector(7 downto 0) := (others => '0');
        -- Instrução do quadro.
        variable ins        : std_logic_vector(7 downto 0) := (others => '0');
        -- Endereço do quadro.
        variable addr       : natural := 0;
        -- Byte a enviar.
        variable tx_byte    : std_logic_vector(7 downto 0) := (others => '0');
        -- Posição do bit a enviar, de 7 a 0.
        variable tx_bit     : natural := 7;
        -- O próximo bit a enviar abre um byte novo.
        variable load_next  : boolean := false;
        -- O quadro está enviando dado.
        variable sending    : boolean := false;
        -- Bytes de dado já enviados ou recebidos.
        variable data_cnt   : natural := 0;
        -- Conteúdo do chip, com o padrão inicial.
        variable mem        : mem_ptr_t := init_mem;
        -- Buffer da página em gravação.
        variable page_buf   : page_t;
        -- Primeiro endereço do buffer da página.
        variable page_first : natural := 0;
        -- Bytes recebidos no buffer.
        variable page_len   : natural := 0;
        -- Fim da operação em andamento.
        variable busy_until : time := 0 ns;
        -- Violação do quadro.
        variable bad        : boolean := false;
        -- Setor do SE.
        variable sec        : natural := 0;
        -- Endereço dentro da página.
        variable pa         : natural := 0;
    begin
        wait on i_sck, i_cs_n;
        if now >= busy_until and wip_s = '1' then
            wip_s <= '0';
        end if;
        if i_cs_n'event and i_cs_n = '0' then
            bit_cnt  := 0;
            byte_cnt := 0;
            sending  := false;
            data_cnt := 0;
            page_len := 0;
            bad      := false;
        elsif i_cs_n'event and i_cs_n = '1' then
            -- Fim do quadro: executa a instrução.
            if bit_cnt /= 0 then
                violation_s <= '1';
            end if;
            if bad then
                violation_s <= '1';
            elsif ins = x"06" and byte_cnt = 1 then
                wel_s <= '1';
            elsif ins = x"02" and byte_cnt >= 5 then
                if wel_s = '0' or addr < protect_below then
                    violation_s <= '1';
                else
                    for k in 0 to page_len - 1 loop
                        pa := (page_first + k) mod 256;
                        mem((addr / 256) * 256 + pa) := mem((addr / 256) * 256 + pa) and page_buf(k);
                    end loop;
                    wip_s      <= '1';
                    busy_until := now + t_program;
                    wel_s      <= '0';
                end if;
            elsif ins = x"D8" and byte_cnt = 4 then
                sec := addr / 65536;
                if wel_s = '0' or sec * 65536 < protect_below then
                    violation_s <= '1';
                else
                    for k in 0 to 65535 loop
                        mem(sec * 65536 + k) := x"FF";
                    end loop;
                    wip_s      <= '1';
                    busy_until := now + t_erase;
                    wel_s      <= '0';
                end if;
            end if;
            sending := false;
            miso_s  <= '0';
        elsif i_cs_n = '0' and i_sck'event and i_sck = '1' then
            -- Subida do clock: amostra o dado do mestre.
            rx_byte := rx_byte(6 downto 0) & i_mosi;
            bit_cnt := bit_cnt + 1;
            if bit_cnt = 8 then
                bit_cnt := 0;
                if byte_cnt = 0 then
                    ins := rx_byte;
                    if now < busy_until and ins /= x"05" then
                        bad := true;
                    elsif ins /= x"9F" and ins /= x"05" and ins /= x"06" and ins /= x"03" and ins /= x"0B"
                          and ins /= x"02" and ins /= x"D8" then
                        bad := true;
                    end if;
                    addr := 0;
                elsif byte_cnt <= 3 and (ins = x"03" or ins = x"0B" or ins = x"02" or ins = x"D8") then
                    addr := addr * 256 + to_integer(unsigned(rx_byte));
                elsif ins = x"02" then
                    if page_len = 0 then
                        page_first := addr mod 256;
                    end if;
                    page_buf(page_len mod 256) := rx_byte;
                    page_len := page_len + 1;
                end if;
                byte_cnt := byte_cnt + 1;
                -- O dado a enviar começa depois do cabeçalho.
                if (ins = x"9F" or ins = x"05") and byte_cnt = 1 then
                    sending   := true;
                    load_next := true;
                    data_cnt  := 0;
                elsif ins = x"03" and byte_cnt = 4 then
                    sending   := true;
                    load_next := true;
                    data_cnt  := 0;
                elsif ins = x"0B" and byte_cnt = 5 then
                    sending   := true;
                    load_next := true;
                    data_cnt  := 0;
                end if;
            end if;
        elsif i_cs_n = '0' and i_sck'event and i_sck = '0' then
            -- Descida do clock: o chip mostra o próximo bit, e carrega o byte seguinte quando precisa.
            if sending then
                if load_next then
                    case ins is
                        when x"9F" =>
                            if data_cnt < 3 then
                                tx_byte := id_bytes(23 - 8 * data_cnt downto 16 - 8 * data_cnt);
                            else
                                tx_byte := x"00";
                            end if;
                        when x"05" =>
                            tx_byte := "000000" & wel_s & wip_s;
                        when others =>
                            tx_byte := mem(addr mod size_bytes);
                            addr    := addr + 1;
                    end case;
                    data_cnt  := data_cnt + 1;
                    tx_bit    := 7;
                    load_next := false;
                end if;
                miso_s <= tx_byte(tx_bit);
                if tx_bit = 0 then
                    load_next := true;
                else
                    tx_bit := tx_bit - 1;
                end if;
            end if;
        end if;
    end process p_chip;

end architecture sim;
