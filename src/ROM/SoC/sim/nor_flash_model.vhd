-- =============================================================================
-- Modelo de simulação do chip de FLASH NOR paralela de 8 bits
--
-- Faz o papel do S29GL064N da DE2-115 nos pinos do nor_flash_ctrl: leitura
-- assíncrona com acesso aleatório e de página, e os ciclos de escrita de comando
-- do chip em modo byte (desbloqueio AAA/AA e 555/55, comando A0 de gravar byte ou
-- 80 mais AAA/AA, 555/55 e 30 de apagar setor, F0 de voltar à leitura), com a
-- operação interna durando t_prog_ns ou t_erase_ns e o pino RY# baixo enquanto
-- dura. Não é sintetizável: usa o tempo de simulação.
--
-- O modelo FALHA a simulação (assert com severity failure) quando o controlador
-- viola um tempo ou uma regra de uso do chip, e o sinal o_violation dá um pulso de
-- 1 ns a cada violação (com abort_on_violation falso, só avisa e segue, para o
-- teste do próprio modelo). As violações verificadas:
--   - leitura encerrada, por mudança de endereço ou por CE#/OE# em nível alto,
--     antes do tempo de acesso (t_acc_ns de acesso aleatório e de CE#, t_pacc_ns
--     dentro da página, t_oe_ns de OE#);
--   - largura do pulso de WE# menor que t_wp_ns, WE# em nível alto menor que
--     t_wph_ns, ciclo de escrita menor que t_wc_ns, dado estável por menos de
--     t_ds_ns antes da subida de WE#, endereço mudando antes de t_ah_ns depois da
--     descida de WE# ou durante o pulso, dado indefinido na subida de WE#;
--   - WE# sem CE# baixo, WE# e OE# baixos juntos, escrita com RESET# baixo;
--   - ciclo de escrita fora da sequência de comando, ou durante uma operação
--     interna (a leitura durante a operação é permitida e devolve o estado);
--   - RESET# baixo por menos de t_rp_ns, ou CE# baixo antes de t_rh_ns depois de
--     RESET# subir.
-- Os tempos são generics em ns; os padrões vêm de chip_timing_pkg e estão
-- marcados "inferido" na ficha da DE2-115.
--
-- Leitura durante a operação interna devolve o estado: no bit 7, o complemento do
-- bit 7 do dado gravado (gravação) ou '0' (apagar), e zero nos demais; o bit 6 de
-- alternância não é modelado. RY# fica baixo de t_busy_ns depois da subida de WE#
-- do último ciclo até o fim da operação. RESET# baixo aborta a operação e deixa o
-- conteúdo como estava. A proteção de hardware WP# em nível baixo ignora gravar e
-- apagar no último setor.
--
-- Conteúdo inicial: o padrão determinístico de pattern_byte (reproduzido nos
-- testes) ou tudo em 0xFF (apagado) com erased_init.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.utils_pkg.all;
use work.chip_timing_pkg.all;
use work.sim_util_pkg.all;

entity nor_flash_model is
    generic (
        -- Tamanho do chip em bytes, uma potência de dois de 8 KB a 8 MB.
        size_bytes         : positive := 8388608;
        -- Tamanho do setor em bytes, potência de dois.
        sector_bytes       : positive := 65536;
        -- Acesso aleatório e de CE#, em ns.
        t_acc_ns           : natural  := NOR_T_ACC_NS;
        -- Acesso dentro da página, em ns.
        t_pacc_ns          : natural  := NOR_T_PACC_NS;
        -- Saída habilitada até o dado, em ns.
        t_oe_ns            : natural  := NOR_T_OE_NS;
        -- Ciclo de escrita, em ns.
        t_wc_ns            : natural  := NOR_T_WC_NS;
        -- Largura do pulso de WE#, em ns.
        t_wp_ns            : natural  := NOR_T_WP_NS;
        -- Largura de WE# em nível alto, em ns.
        t_wph_ns           : natural  := NOR_T_WPH_NS;
        -- Dado estável antes da subida de WE#, em ns.
        t_ds_ns            : natural  := NOR_T_DS_NS;
        -- Endereço estável depois da descida de WE#, em ns.
        t_ah_ns            : natural  := NOR_T_AH_NS;
        -- Da subida de WE# à descida de RY#, em ns.
        t_busy_ns          : natural  := NOR_T_BUSY_NS;
        -- Largura do pulso de RESET#, em ns.
        t_rp_ns            : natural  := NOR_T_RP_NS;
        -- Da subida de RESET# ao primeiro acesso, em ns.
        t_rh_ns            : natural  := NOR_T_RH_NS;
        -- Duração da gravação de um byte, em ns.
        t_prog_ns          : natural  := NOR_T_PROG_NS;
        -- Duração do apagar de um setor, em ns.
        t_erase_ns         : natural  := NOR_T_ERASE_NS;
        -- Conteúdo inicial todo em 0xFF, em vez do padrão determinístico.
        erased_init        : boolean  := false;
        -- Uma violação aborta a simulação (verdadeiro) ou só pulsa o_violation e avisa (falso).
        abort_on_violation : boolean  := true
    );
    port (
        -- Endereço de byte (FL_ADDR[22:0]).
        i_fl_addr   : in    std_logic_vector(22 downto 0);
        -- Dado vindo do controlador (FL_DQ[7:0] como o controlador o dirige, 'Z' quando solto).
        i_fl_dq     : in    std_logic_vector(7 downto 0);
        -- Dado dirigido pelo chip, 'Z' quando solto.
        o_fl_dq     : out   std_logic_vector(7 downto 0) := (others => 'Z');
        -- Chip habilitado, ativo em '0'.
        i_fl_ce_n   : in    std_logic;
        -- Saída habilitada, ativo em '0'.
        i_fl_oe_n   : in    std_logic;
        -- Escrita habilitada, ativo em '0'.
        i_fl_we_n   : in    std_logic;
        -- Reset, ativo em '0'.
        i_fl_rst_n  : in    std_logic;
        -- Proteção de hardware, ativo em '0'.
        i_fl_wp_n   : in    std_logic;
        -- Pronto ('1') ou ocupado ('0').
        o_fl_ry     : out   std_logic                    := '1';
        -- Pulso de 1 ns a cada violação de tempo ou de uso.
        o_violation : out   std_logic                    := '0'
    );
end entity nor_flash_model;

architecture sim of nor_flash_model is

    -- Nome do modelo, prefixo das mensagens de violação.
    constant MODEL_NAME : string := "nor_flash_model";

    -- Bits de endereço da janela do chip (falha se size_bytes não for uma potência de dois).
    constant WINDOW_BITS : natural := log2_exact(size_bytes);
    -- Bits de endereço dentro de um setor.
    constant SECTOR_BITS : natural := log2_exact(sector_bytes);

    -- Um byte do chip.
    subtype byte_t is natural range 0 to 255;

    -- O conteúdo do chip.
    type mem_t is array (0 to size_bytes - 1) of byte_t;

    -- Estados do decodificador de comandos do chip.
    type cmd_state_t is (C_READ, C_U1, C_U2, C_PROG, C_E1, C_E2, C_E3);

    -- Padrão determinístico do conteúdo inicial do byte de endereço a: o byte 3 da palavra de
    -- pattern_word(a).

    function pattern_byte (a : natural) return byte_t is

        -- Palavra do padrão no endereço do byte.
        variable w : std_logic_vector(31 downto 0);

    begin

        w := pattern_word(std_logic_vector(to_unsigned(a, 32)));
        return to_integer(unsigned(w(31 downto 24)));

    end function pattern_byte;

begin

    assert size_bytes >= 8192 and size_bytes <= 2 ** 23
        report "size_bytes must be between 8 KB and 8 MB"
        severity failure;

    process is

        -- O conteúdo do chip.
        variable mem        : mem_t;
        -- Estado do decodificador de comandos.
        variable cs         : cmd_state_t           := C_READ;
        -- Instante da última mudança de endereço.
        variable t_addr     : time                  := 0 ns;
        -- Instante da última descida de CE#.
        variable t_ce       : time                  := 0 ns;
        -- Instante da última descida de OE#.
        variable t_oe       : time                  := 0 ns;
        -- Instante da última descida de WE# (nenhum antes da primeira).
        variable t_we_fall  : time                  := 0 ns;
        -- Instante da última subida de WE#.
        variable t_we_rise  : time                  := 0 ns;
        -- Instante da última mudança do dado vindo do controlador.
        variable t_dq       : time                  := 0 ns;
        -- Instante da última descida de RESET#.
        variable t_rst_fall : time                  := 0 ns;
        -- Instante da última subida de RESET#.
        variable t_rst_rise : time                  := 0 ns;
        -- Já houve uma descida de WE#.
        variable seen_we    : boolean               := false;
        -- Já houve uma subida de RESET#.
        variable seen_rst   : boolean               := false;
        -- O acesso em curso é aleatório (a página mudou, ou CE# acabou de descer).
        variable rand       : boolean               := true;
        -- Endereço anterior, para saber se a página mudou.
        variable prev_addr  : unsigned(22 downto 0) := (others => '0');
        -- Havia uma leitura em curso (CE# e OE# baixos, WE# alto, RESET# alto) no passo anterior.
        variable was_active : boolean               := false;
        -- Há uma leitura em curso agora.
        variable cur_active : boolean;
        -- Endereço do ciclo de escrita, capturado na descida de WE#.
        variable wr_addr    : unsigned(22 downto 0) := (others => '0');
        -- Uma operação interna está em andamento.
        variable op_active  : boolean               := false;
        -- Instante do fim da operação interna.
        variable op_end_at  : time;
        -- A operação interna é um apagar.
        variable op_erase   : boolean               := false;
        -- Endereço da operação interna (do byte gravado, ou do início do setor apagado).
        variable op_addr    : natural               := 0;
        -- Dado gravado pela operação (já combinado com o conteúdo anterior).
        variable op_data    : byte_t                := 0;
        -- RY# vai baixar no instante ry_fall_at.
        variable ry_pending : boolean               := false;
        -- Instante em que RY# baixa.
        variable ry_fall_at : time;
        -- Próximo instante em que o modelo precisa acordar sem evento de entrada.
        variable next_t     : time;
        -- Instante em que o dado da leitura fica válido.
        variable avail      : time;
        -- Tempo de acesso exigido pelo tipo de acesso.
        variable req        : time;
        -- Dado da leitura.
        variable rd_data    : byte_t;
        -- Dado do ciclo de escrita.
        variable wr_data    : byte_t;
        -- Endereço do ciclo de escrita, 12 bits baixos.
        variable a12        : natural;

        -- Endereço de byte do chip como natural, dentro da janela.

        function idx (a : unsigned(22 downto 0)) return natural is
        begin

            return to_integer(a(WINDOW_BITS - 1 downto 0));

        end function idx;

    begin

        for i in 0 to size_bytes - 1 loop

            if erased_init then
                mem(i) := 255;
            else
                mem(i) := pattern_byte(i);
            end if;

        end loop;

        loop

            next_t := time'high;

            if ry_pending then
                next_t := ry_fall_at;
            end if;

            if op_active and op_end_at < next_t then
                next_t := op_end_at;
            end if;

            if next_t /= time'high and next_t > now then
                wait on i_fl_addr, i_fl_dq, i_fl_ce_n, i_fl_oe_n, i_fl_we_n, i_fl_rst_n, i_fl_wp_n for next_t - now;
            elsif next_t = time'high then
                wait on i_fl_addr, i_fl_dq, i_fl_ce_n, i_fl_oe_n, i_fl_we_n, i_fl_rst_n, i_fl_wp_n;
            end if;

            -- Eventos de tempo: RY# baixa, a operação interna termina.
            if ry_pending and now >= ry_fall_at then
                o_fl_ry    <= '0';
                ry_pending := false;
            end if;

            if op_active and now >= op_end_at then
                if op_erase then

                    for i in 0 to sector_bytes - 1 loop

                        mem(op_addr + i) := 255;

                    end loop;

                else
                    mem(op_addr) := op_data;
                end if;
                op_active := false;
                o_fl_ry   <= '1';
            end if;

            -- RESET#.
            if i_fl_rst_n'event then
                if i_fl_rst_n = '0' then
                    t_rst_fall := now;
                    cs         := C_READ;
                    op_active  := false;
                    ry_pending := false;
                    o_fl_ry    <= '1';
                elsif i_fl_rst_n = '1' then
                    if now - t_rst_fall < tns(t_rp_ns) then
                        violate(o_violation, MODEL_NAME, abort_on_violation,
                                "RESET# em nivel baixo por menos de t_rp");
                    end if;
                    t_rst_rise := now;
                    seen_rst   := true;
                end if;
            end if;

            cur_active := i_fl_ce_n = '0' and i_fl_oe_n = '0' and i_fl_we_n = '1' and i_fl_rst_n = '1';

            -- A leitura que estava em curso termina por mudança de endereço ou por perder CE#/OE#: o dado já tinha de estar válido.
            if was_active and i_fl_rst_n = '1' and (i_fl_addr'event or not cur_active) then
                if rand then
                    req := tns(t_acc_ns);
                else
                    req := tns(t_pacc_ns);
                end if;
                avail := t_addr + req;
                if t_ce + tns(t_acc_ns) > avail then
                    avail := t_ce + tns(t_acc_ns);
                end if;
                if t_oe + tns(t_oe_ns) > avail then
                    avail := t_oe + tns(t_oe_ns);
                end if;
                if now < avail then
                    violate(o_violation, MODEL_NAME, abort_on_violation,
                            "leitura encerrada antes do tempo de acesso");
                end if;
            end if;

            -- Endereço: tempo de espera depois da descida de WE# e escrita em curso.
            if i_fl_addr'event then
                if seen_we and i_fl_ce_n = '0' and now - t_we_fall < tns(t_ah_ns) and not is_x(i_fl_addr) then
                    violate(o_violation, MODEL_NAME, abort_on_violation,
                            "endereco mudou antes de t_ah depois da descida de WE#");
                end if;
                if unsigned(i_fl_addr(22 downto 4)) /= prev_addr(22 downto 4) then
                    rand := true;
                else
                    rand := false;
                end if;
                if not is_x(i_fl_addr) then
                    prev_addr := unsigned(i_fl_addr);
                end if;
                t_addr := now;
            end if;

            if i_fl_ce_n'event and i_fl_ce_n = '0' then
                t_ce := now;
                rand := true;
                if seen_rst and now - t_rst_rise < tns(t_rh_ns) then
                    violate(o_violation, MODEL_NAME, abort_on_violation,
                            "CE# baixo antes de t_rh depois de RESET#");
                end if;
            end if;

            if i_fl_oe_n'event and i_fl_oe_n = '0' then
                t_oe := now;
            end if;

            -- O dado vindo do controlador, quando o chip não o dirige.
            if i_fl_dq'event and not was_active then
                t_dq := now;
            end if;

            -- Escrita: descida de WE#.
            if i_fl_we_n'event and i_fl_we_n = '0' and i_fl_rst_n = '1' then
                if i_fl_ce_n /= '0' then
                    violate(o_violation, MODEL_NAME, abort_on_violation, "WE# baixo sem CE# baixo");
                end if;
                if i_fl_oe_n /= '1' then
                    violate(o_violation, MODEL_NAME, abort_on_violation, "WE# e OE# baixos juntos");
                end if;
                if seen_we and now - t_we_fall < tns(t_wc_ns) then
                    violate(o_violation, MODEL_NAME, abort_on_violation, "ciclo de escrita menor que t_wc");
                end if;
                if seen_we and now - t_we_rise < tns(t_wph_ns) then
                    violate(o_violation, MODEL_NAME, abort_on_violation,
                            "WE# em nivel alto por menos de t_wph");
                end if;
                t_we_fall := now;
                seen_we   := true;
                wr_addr   := unsigned(i_fl_addr);
            elsif i_fl_we_n'event and i_fl_we_n = '1' and seen_we and now > t_we_fall then
                -- Escrita: subida de WE#. O ciclo vale.
                t_we_rise := now;
                if now - t_we_fall < tns(t_wp_ns) then
                    violate(o_violation, MODEL_NAME, abort_on_violation, "pulso de WE# menor que t_wp");
                end if;
                if now - t_dq < tns(t_ds_ns) then
                    violate(o_violation, MODEL_NAME, abort_on_violation,
                            "dado estavel por menos de t_ds antes da subida de WE#");
                end if;
                if is_x(i_fl_dq) then
                    violate(o_violation, MODEL_NAME, abort_on_violation, "dado indefinido na subida de WE#");
                elsif i_fl_rst_n = '1' and i_fl_ce_n = '0' then
                    wr_data := to_integer(unsigned(i_fl_dq));
                    a12     := to_integer(wr_addr(11 downto 0));
                    if op_active then
                        violate(o_violation, MODEL_NAME, abort_on_violation,
                                "ciclo de escrita durante a operacao interna");
                    else

                        case cs is

                            when C_READ =>

                                if a12 = 16#AAA# and wr_data = 16#AA# then
                                    cs := C_U1;
                                elsif wr_data /= 16#F0# then
                                    violate(o_violation, MODEL_NAME, abort_on_violation,
                                            "ciclo de escrita fora da sequencia de comando (endereco "
                                            & natural'image(a12)
                                            & ", dado " & natural'image(wr_data) & ")");
                                end if;

                            when C_U1 =>

                                if a12 = 16#555# and wr_data = 16#55# then
                                    cs := C_U2;
                                else
                                    violate(o_violation, MODEL_NAME, abort_on_violation,
                                            "segundo ciclo de desbloqueio invalido");
                                    cs := C_READ;
                                end if;

                            when C_U2 =>

                                if a12 = 16#AAA# and wr_data = 16#A0# then
                                    cs := C_PROG;
                                elsif a12 = 16#AAA# and wr_data = 16#80# then
                                    cs := C_E1;
                                else
                                    violate(o_violation, MODEL_NAME, abort_on_violation,
                                            "comando invalido depois do desbloqueio");
                                    cs := C_READ;
                                end if;

                            when C_PROG =>

                                cs := C_READ;
                                if i_fl_wp_n = '0' and idx(wr_addr) / sector_bytes = size_bytes / sector_bytes - 1 then
                                    null;
                                else
                                    op_active  := true;
                                    op_erase   := false;
                                    op_addr    := idx(wr_addr);
                                    op_data    := to_integer(to_unsigned(mem(op_addr), 8) and to_unsigned(wr_data, 8));
                                    op_end_at  := now + tns(t_prog_ns);
                                    ry_pending := true;
                                    ry_fall_at := now + tns(t_busy_ns);
                                end if;

                            when C_E1 =>

                                if a12 = 16#AAA# and wr_data = 16#AA# then
                                    cs := C_E2;
                                else
                                    violate(o_violation, MODEL_NAME, abort_on_violation,
                                            "primeiro ciclo de desbloqueio do apagar invalido");
                                    cs := C_READ;
                                end if;

                            when C_E2 =>

                                if a12 = 16#555# and wr_data = 16#55# then
                                    cs := C_E3;
                                else
                                    violate(o_violation, MODEL_NAME, abort_on_violation,
                                            "segundo ciclo de desbloqueio do apagar invalido");
                                    cs := C_READ;
                                end if;

                            when C_E3 =>

                                cs := C_READ;
                                if wr_data /= 16#30# then
                                    violate(o_violation, MODEL_NAME, abort_on_violation,
                                            "apagar sem o comando de setor 30 (apagar o chip nao e modelado)");
                                elsif i_fl_wp_n = '0' and idx(wr_addr) / sector_bytes = size_bytes / sector_bytes - 1 then
                                    null;
                                else
                                    op_active  := true;
                                    op_erase   := true;
                                    op_addr    := (idx(wr_addr) / sector_bytes) * sector_bytes;
                                    op_end_at  := now + tns(t_erase_ns);
                                    ry_pending := true;
                                    ry_fall_at := now + tns(t_busy_ns);
                                end if;

                        end case;

                    end if;
                end if;
            end if;

            -- Saída de dados.
            if cur_active and not is_x(i_fl_addr) then
                if op_active then
                    if op_erase then
                        rd_data := 0;
                    else
                        rd_data := 128 * (1 - op_data / 128) mod 256;
                    end if;
                    o_fl_dq <= transport std_logic_vector(to_unsigned(rd_data, 8));
                else
                    rd_data := mem(idx(unsigned(i_fl_addr)));
                    if rand then
                        req := tns(t_acc_ns);
                    else
                        req := tns(t_pacc_ns);
                    end if;
                    avail := t_addr + req;
                    if t_ce + tns(t_acc_ns) > avail then
                        avail := t_ce + tns(t_acc_ns);
                    end if;
                    if t_oe + tns(t_oe_ns) > avail then
                        avail := t_oe + tns(t_oe_ns);
                    end if;
                    o_fl_dq <= transport (others => 'X');
                    if avail > now then
                        o_fl_dq <= transport std_logic_vector(to_unsigned(rd_data, 8)) after avail - now;
                    else
                        o_fl_dq <= transport std_logic_vector(to_unsigned(rd_data, 8));
                    end if;
                end if;
            else
                o_fl_dq <= transport (others => 'Z');
            end if;

            was_active := cur_active;

        end loop;

    end process;

end architecture sim;
