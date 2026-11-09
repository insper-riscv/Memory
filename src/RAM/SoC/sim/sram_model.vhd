-- =============================================================================
-- Modelo de simulação da SRAM assíncrona de 16 bits
--
-- Faz o papel da IS61WV102416BLL-10 da DE2-115 nos pinos do sram_ctrl: 1M palavras
-- de 16 bits, leitura assíncrona por endereço e escrita comandada por WE#, com
-- LB# e UB# escolhendo o byte baixo e o alto. Não é sintetizável: usa o tempo de
-- simulação. Começa com todo o conteúdo em zero.
--
-- O modelo FALHA a simulação (assert com severity failure) quando o controlador
-- viola um tempo ou uma regra de uso do chip, e o sinal o_violation dá um pulso de
-- 1 ns a cada violação (com abort_on_violation falso, só avisa e segue, para o
-- teste do próprio modelo). As violações verificadas:
--   - leitura encerrada, por mudança de endereço ou por CE#/OE# em nível alto,
--     antes do tempo de acesso t_aa_ns, medido do último endereço, de CE# ou de
--     OE#; endereço mudando em menos de t_rc_ns;
--   - escrita com pulso de WE# menor que t_pwe_ns, endereço estável por menos de
--     t_aw_ns, CE# baixo por menos de t_sce_ns ou dado estável por menos de
--     t_sd_ns antes da subida de WE#; ciclo de escrita menor que t_wc_ns;
--   - endereço ou dado mudando em menos de t_ha_ns ou t_hd_ns depois da subida
--     de WE#, ou o endereço mudando com WE# baixo;
--   - dado indefinido na subida de WE#, e contenção de barramento: o controlador
--     dirigindo o dado enquanto o chip dirige a leitura.
-- Os tempos são generics em ns; os padrões vêm de chip_timing_pkg e estão
-- marcados "inferido" na ficha da DE2-115.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.utils_pkg.all;
use work.chip_timing_pkg.all;
use work.sim_util_pkg.all;

entity sram_model is
    generic (
        -- Tamanho do chip em bytes, uma potência de dois de 16 bytes a 2 MB.
        size_bytes         : positive := 2097152;
        -- Acesso por endereço, em ns.
        t_aa_ns            : natural  := SRAM_T_AA_NS;
        -- Ciclo de leitura, em ns.
        t_rc_ns            : natural  := SRAM_T_RC_NS;
        -- Ciclo de escrita, em ns.
        t_wc_ns            : natural  := SRAM_T_WC_NS;
        -- CE# até o fim da escrita, em ns.
        t_sce_ns           : natural  := SRAM_T_SCE_NS;
        -- Endereço válido até o fim da escrita, em ns.
        t_aw_ns            : natural  := SRAM_T_AW_NS;
        -- Largura do pulso de WE#, em ns.
        t_pwe_ns           : natural  := SRAM_T_PWE_NS;
        -- Dado válido antes da subida de WE#, em ns.
        t_sd_ns            : natural  := SRAM_T_SD_NS;
        -- Endereço mantido depois da subida de WE#, em ns.
        t_ha_ns            : natural  := SRAM_T_HA_NS;
        -- Dado mantido depois da subida de WE#, em ns.
        t_hd_ns            : natural  := SRAM_T_HD_NS;
        -- Uma violação aborta a simulação (verdadeiro) ou só pulsa o_violation e avisa (falso).
        abort_on_violation : boolean  := true
    );
    port (
        -- Endereço de palavra de 16 bits (SRAM_ADDR[19:0]).
        i_sram_addr : in    std_logic_vector(19 downto 0);
        -- Dado dirigido pelo controlador, 'Z' quando solto.
        i_sram_dq   : in    std_logic_vector(15 downto 0);
        -- Dado dirigido pelo chip, 'Z' quando solto.
        o_sram_dq   : out   std_logic_vector(15 downto 0) := (others => 'Z');
        -- Chip habilitado, ativo em '0'.
        i_sram_ce_n : in    std_logic;
        -- Saída habilitada, ativo em '0'.
        i_sram_oe_n : in    std_logic;
        -- Escrita habilitada, ativo em '0'.
        i_sram_we_n : in    std_logic;
        -- Byte baixo habilitado, ativo em '0'.
        i_sram_lb_n : in    std_logic;
        -- Byte alto habilitado, ativo em '0'.
        i_sram_ub_n : in    std_logic;
        -- Pulso de 1 ns a cada violação de tempo ou de uso.
        o_violation : out   std_logic                     := '0'
    );
end entity sram_model;

architecture sim of sram_model is

    -- Nome do modelo, prefixo das mensagens de violação.
    constant MODEL_NAME : string := "sram_model";

    -- Palavras de 16 bits do chip.
    constant HALVES    : natural := size_bytes / 2;
    -- Bits de endereço de palavra da janela do chip (falha se size_bytes não for uma potência de dois).
    constant HALF_BITS : natural := log2_exact(size_bytes) - 1;

    -- Uma palavra de 16 bits do chip.
    subtype half_t is natural range 0 to 65535;

    -- O conteúdo do chip.
    type mem_t is array(0 to HALVES - 1) of half_t;

begin

    assert size_bytes >= 16 and size_bytes <= 2 ** 21
        report "size_bytes must be between 16 bytes and 2 MB"
        severity failure;

    p_chip_model : process is

        -- O conteúdo do chip.
        variable mem          : mem_t     := (others => 0);
        -- Instante da última mudança de endereço.
        variable t_addr       : time      := 0 ns;
        -- Instante da última descida de CE#.
        variable t_ce         : time      := 0 ns;
        -- Instante da última descida de OE#.
        variable t_oe         : time      := 0 ns;
        -- Instante da última descida de WE#.
        variable t_we_fall    : time      := 0 ns;
        -- Instante da última subida de WE#.
        variable t_we_rise    : time      := 0 ns;
        -- Instante da última mudança do dado do controlador.
        variable t_dq         : time      := 0 ns;
        -- Já houve uma descida de WE#.
        variable seen_we      : boolean   := false;
        -- Havia uma leitura em curso no passo anterior.
        variable was_active   : boolean   := false;
        -- Há uma leitura em curso agora.
        variable cur_active   : boolean;
        -- Instante em que o dado da leitura fica válido.
        variable avail        : time;
        -- Endereço do ciclo de escrita, capturado na descida de WE#.
        variable wr_addr      : natural   := 0;
        -- Palavra anterior do chip no endereço escrito.
        variable old          : half_t;
        -- Palavra nova, com os bytes habilitados trocados.
        variable new_h        : unsigned(15 downto 0);
        -- Palavra do chip lida.
        variable rd           : unsigned(15 downto 0);
        -- Bytes habilitados na descida de WE#.
        variable wr_lb, wr_ub : std_logic := '1';
        -- Endereço atual como natural, dentro da janela.
        variable a_now        : natural;

    begin

        loop

            wait on i_sram_addr, i_sram_dq, i_sram_ce_n, i_sram_oe_n, i_sram_we_n, i_sram_lb_n, i_sram_ub_n;

            cur_active := i_sram_ce_n = '0' and i_sram_oe_n = '0' and i_sram_we_n = '1';

            -- A leitura em curso termina por mudança de endereço ou por perder CE#/OE#/WE#: o dado já tinha de estar
            -- válido.
            if was_active and (i_sram_addr'event or not cur_active) then
                avail := t_addr + tns(t_aa_ns);
                if t_ce + tns(t_aa_ns) > avail then
                    avail := t_ce + tns(t_aa_ns);
                end if;
                if t_oe + tns(t_aa_ns) > avail then
                    avail := t_oe + tns(t_aa_ns);
                end if;
                if now < avail then
                    violate(o_violation, MODEL_NAME, abort_on_violation,
                            "leitura encerrada antes do tempo de acesso");
                end if;
            end if;

            if i_sram_addr'event then
                if i_sram_ce_n = '0' and now - t_addr < tns(t_rc_ns) and (was_active or i_sram_we_n = '0') then
                    violate(o_violation, MODEL_NAME, abort_on_violation,
                            "endereco mudou em menos que o ciclo minimo");
                end if;
                if i_sram_ce_n = '0' and i_sram_we_n = '0' then
                    violate(o_violation, MODEL_NAME, abort_on_violation, "endereco mudou com WE# baixo");
                end if;
                if seen_we and now - t_we_rise < tns(t_ha_ns) then
                    violate(o_violation, MODEL_NAME, abort_on_violation,
                            "endereco mudou antes de t_ha depois da subida de WE#");
                end if;
                t_addr := now;
            end if;

            if i_sram_ce_n'event and i_sram_ce_n = '0' then
                t_ce := now;
            end if;

            if i_sram_oe_n'event and i_sram_oe_n = '0' then
                t_oe := now;
            end if;

            if i_sram_dq'event then
                if seen_we and now - t_we_rise < tns(t_hd_ns) and now /= t_we_rise then
                    violate(o_violation, MODEL_NAME, abort_on_violation,
                            "dado mudou antes de t_hd depois da subida de WE#");
                end if;
                t_dq := now;
            end if;

            -- Contenção: o controlador dirige o dado enquanto o chip dirige a leitura.
            if cur_active and not (i_sram_dq = "ZZZZZZZZZZZZZZZZ") and i_sram_dq'event then
                violate(o_violation, MODEL_NAME, abort_on_violation,
                        "controlador dirigindo o dado durante a leitura");
            end if;

            -- Escrita: descida de WE#.
            if i_sram_we_n'event and i_sram_we_n = '0' then
                if i_sram_ce_n /= '0' then
                    violate(o_violation, MODEL_NAME, abort_on_violation, "WE# baixo sem CE# baixo");
                end if;
                if seen_we and now - t_we_fall < tns(t_wc_ns) then
                    violate(o_violation, MODEL_NAME, abort_on_violation, "ciclo de escrita menor que t_wc");
                end if;
                t_we_fall := now;
                seen_we   := true;
                wr_lb     := i_sram_lb_n;
                wr_ub     := i_sram_ub_n;
                if not is_x(i_sram_addr) then
                    wr_addr := to_integer(unsigned(i_sram_addr(HALF_BITS - 1 downto 0)));
                end if;
            elsif i_sram_we_n'event and i_sram_we_n = '1' and seen_we and now > t_we_fall then
                t_we_rise := now;
                if now - t_we_fall < tns(t_pwe_ns) then
                    violate(o_violation, MODEL_NAME, abort_on_violation, "pulso de WE# menor que t_pwe");
                end if;
                if now - t_addr < tns(t_aw_ns) then
                    violate(o_violation, MODEL_NAME, abort_on_violation,
                            "endereco estavel por menos de t_aw antes da subida de WE#");
                end if;
                if now - t_ce < tns(t_sce_ns) then
                    violate(o_violation, MODEL_NAME, abort_on_violation,
                            "CE# baixo por menos de t_sce antes da subida de WE#");
                end if;
                if now - t_dq < tns(t_sd_ns) then
                    violate(o_violation, MODEL_NAME, abort_on_violation,
                            "dado estavel por menos de t_sd antes da subida de WE#");
                end if;
                if wr_lb /= i_sram_lb_n or wr_ub /= i_sram_ub_n then
                    violate(o_violation, MODEL_NAME, abort_on_violation,
                            "LB# ou UB# mudou durante o pulso de WE#");
                end if;
                if is_x(i_sram_dq) then
                    if wr_lb = '0' or wr_ub = '0' then
                        violate(o_violation, MODEL_NAME, abort_on_violation,
                                "dado indefinido na subida de WE#");
                    end if;
                elsif i_sram_ce_n = '0' then
                    old   := mem(wr_addr);
                    new_h := to_unsigned(old, 16);
                    if wr_lb = '0' then
                        new_h(7 downto 0) := unsigned(i_sram_dq(7 downto 0));
                    end if;
                    if wr_ub = '0' then
                        new_h(15 downto 8) := unsigned(i_sram_dq(15 downto 8));
                    end if;
                    mem(wr_addr) := to_integer(new_h);
                end if;
            end if;

            -- Saída de dados.
            if cur_active and not is_x(i_sram_addr) then
                a_now := to_integer(unsigned(i_sram_addr(HALF_BITS - 1 downto 0)));
                rd    := to_unsigned(mem(a_now), 16);
                avail := t_addr + tns(t_aa_ns);
                if t_ce + tns(t_aa_ns) > avail then
                    avail := t_ce + tns(t_aa_ns);
                end if;
                if t_oe + tns(t_aa_ns) > avail then
                    avail := t_oe + tns(t_aa_ns);
                end if;
                o_sram_dq <= transport (others => 'X');
                if avail > now then
                    o_sram_dq <= transport std_logic_vector(rd) after avail - now;
                else
                    o_sram_dq <= transport std_logic_vector(rd);
                end if;
                if i_sram_lb_n = '1' then
                    o_sram_dq(7 downto 0) <= transport (others => 'Z');
                end if;
                if i_sram_ub_n = '1' then
                    o_sram_dq(15 downto 8) <= transport (others => 'Z');
                end if;
            else
                o_sram_dq <= transport (others => 'Z');
            end if;

            was_active := cur_active;

        end loop;

    end process p_chip_model;

end architecture sim;
