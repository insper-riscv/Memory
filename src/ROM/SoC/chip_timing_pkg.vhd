-- =============================================================================
-- Tempos dos chips de memória de dispositivo (FLASH NOR e SRAM assíncrona)
--
-- Reúne os tempos de datasheet que o controlador e o modelo de cada chip leem,
-- em nanossegundos, e a conversão de um tempo em ciclos de clock. A fonte dos
-- valores é o catálogo de chips (chips/S29GL064N90.yaml e
-- chips/IS61WV102416BLL-10.yaml); o pacote é a forma que o VHDL lê, e
-- tests/python/check_chip_timing.py (make check) falha se uma constante diferir do
-- catálogo. O pacote gerado do catálogo (trilha M.2.3 do plano Multi-FPGA) o
-- substitui sem mudar os nomes que os controladores usam.
--
-- Origem dos valores. Nenhum foi lido no datasheet nesta sessão: todos estão
-- marcados "inferido" na ficha Plans/Multi-FPGA/placas/de2-115.md (seções 5.2 e
-- 5.3) e vêm da memória dos datasheets Spansion S29GL064N90 e ISSI
-- IS61WV102416BLL-10. Quem usar outro chip, ou confirmar a peça no esquemático da
-- placa, troca o generic na instância, nunca estas constantes dentro de uma
-- entidade.
-- =============================================================================

package chip_timing_pkg is

    -- FLASH NOR S29GL064N90 (inferido): acesso aleatório e de chip habilitado, em ns.
    constant NOR_T_ACC_NS   : natural := 90;
    -- FLASH NOR: acesso dentro da página de 8 palavras (16 bytes em modo byte), em ns (inferido).
    constant NOR_T_PACC_NS  : natural := 25;
    -- FLASH NOR: saída habilitada até o dado válido, em ns (inferido).
    constant NOR_T_OE_NS    : natural := 35;
    -- FLASH NOR: tempo de ciclo de escrita, em ns (inferido).
    constant NOR_T_WC_NS    : natural := 90;
    -- FLASH NOR: largura mínima do pulso de WE#, em ns (inferido).
    constant NOR_T_WP_NS    : natural := 35;
    -- FLASH NOR: largura mínima de WE# em nível alto entre dois pulsos, em ns (inferido).
    constant NOR_T_WPH_NS   : natural := 30;
    -- FLASH NOR: dado estável antes da subida de WE#, em ns (inferido).
    constant NOR_T_DS_NS    : natural := 45;
    -- FLASH NOR: endereço estável depois da descida de WE#, em ns (inferido).
    constant NOR_T_AH_NS    : natural := 45;
    -- FLASH NOR: da subida de WE# à descida de RY#, em ns (inferido).
    constant NOR_T_BUSY_NS  : natural := 90;
    -- FLASH NOR: largura mínima do pulso de RESET#, em ns (inferido).
    constant NOR_T_RP_NS    : natural := 500;
    -- FLASH NOR: da subida de RESET# à primeira leitura, em ns (inferido).
    constant NOR_T_RH_NS    : natural := 50;
    -- FLASH NOR: gravação de um byte, valor típico em ns (inferido; 60 us).
    constant NOR_T_PROG_NS  : natural := 60000;
    -- FLASH NOR: apagar de um setor de 64 KB, valor típico em ns (inferido; 0,5 s).
    constant NOR_T_ERASE_NS : natural := 500000000;

    -- SRAM IS61WV102416BLL-10 (inferido): acesso por endereço, em ns.
    constant SRAM_T_AA_NS  : natural := 10;
    -- SRAM: tempo de ciclo de leitura, em ns (inferido).
    constant SRAM_T_RC_NS  : natural := 10;
    -- SRAM: tempo de ciclo de escrita, em ns (inferido).
    constant SRAM_T_WC_NS  : natural := 10;
    -- SRAM: CE# até o fim da escrita, em ns (inferido).
    constant SRAM_T_SCE_NS : natural := 8;
    -- SRAM: endereço válido até o fim da escrita, em ns (inferido).
    constant SRAM_T_AW_NS  : natural := 8;
    -- SRAM: largura mínima do pulso de WE#, em ns (inferido).
    constant SRAM_T_PWE_NS : natural := 8;
    -- SRAM: dado válido antes da subida de WE#, em ns (inferido).
    constant SRAM_T_SD_NS  : natural := 6;
    -- SRAM: endereço mantido depois da subida de WE#, em ns (inferido).
    constant SRAM_T_HA_NS  : natural := 0;
    -- SRAM: dado mantido depois da subida de WE#, em ns (inferido).
    constant SRAM_T_HD_NS  : natural := 0;

    -- Maior de dois naturais (o Quartus Lite não traz a função maximum do VHDL-2008 para natural).

    pure function max_natural (a : natural; b : natural) return natural;

    -- Número de ciclos de período period_ns que cobrem t_ns mais margin_ns, no mínimo um: piso de t sobre T somado
    -- de um, ou seja, o teto de (t + margem) / T.

    pure function cycles_of (t_ns : natural; period_ns : positive; margin_ns : natural) return positive;

end package chip_timing_pkg;

package body chip_timing_pkg is

    pure function max_natural (a : natural; b : natural) return natural is
    begin

        if a > b then
            return a;
        end if;

        return b;

    end function max_natural;

    pure function cycles_of (t_ns : natural; period_ns : positive; margin_ns : natural) return positive is

        -- Teto da divisão do tempo com a margem pelo período.
        variable n : natural;

    begin

        n := (t_ns + margin_ns + period_ns - 1) / period_ns;

        if n < 1 then
            return 1;
        end if;

        return n;

    end function cycles_of;

end package body chip_timing_pkg;
