-- =============================================================================
-- Roteador de região dos pedidos de uma cache
--
-- Leva o pedido de um mestre (o lado da memória de uma cache) para a SDRAM ou para
-- a FLASH conforme o endereço esteja na região da FLASH, [flash_base_kib, flash_end_kib), e devolve o ready e o dado da
-- região escolhida. O contrato é o da ponte da SDRAM: o pedido fica no barramento
-- até ready, ready é um nível que só cai com advance, e o dado lido só muda no
-- pedido seguinte. A escolha é combinacional sobre o endereço, que o mestre
-- mantém estável durante o pedido.
--
-- Dois pedidos à FLASH não chegam ao chip. Um store (i_wren) é concluído aqui, sem
-- efeito, como num chip protegido contra escrita; e uma leitura fora da janela de 1 MB
-- (a partir de flash_base_kib + flash_window_kib) devolve zero. Nos dois casos ready
-- sobe um clock depois do pedido e fica em nível até advance. O mestre baixa o
-- pedido na borda em que vê ready, como as caches fazem.
--
-- Para uma cache só de leitura, i_wren fica em '0' e o caso do store não ocorre.
--
-- hold_rdata: com um mestre que não guarda o dado lido (o núcleo ligado direto, sem cache de dados), o endereço
-- continua mudando depois que o pedido termina, e escolher o dado lido por ele faria o estágio de write-back ler
-- a região errada. Com hold_rdata, o_rdata e o_rdata_x seguem a região do último pedido concluído (o_ready e
-- i_advance em '1' com i_rden ou i_wren), registrada na mesma borda em que o chip troca o dado lido, e não
-- mudam até o próximo pedido concluir. Sem hold_rdata a escolha é combinacional sobre o endereço, o que basta
-- a uma cache, que guarda o dado ao terminar o pedido.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.config_pkg.all;
use work.cache_pkg.all;

entity mem_region_router is
    generic (
        -- Base, em KiB, da região da FLASH (0x20000000 por padrão). Origem: o espaço de endereços da
        -- região da FLASH que as caches do Memory enxergam, não o mapa do Core, por isso o padrão
        -- difere dos defaults do Core.
        flash_base_kib   : natural := 524288;
        -- Fim exclusivo, em KiB, da região da FLASH (0x40000000 por padrão). Origem: o espaço de
        -- endereços da região da FLASH que as caches do Memory enxergam, não o mapa do Core, por isso o
        -- padrão difere dos defaults do Core.
        flash_end_kib    : natural := 1048576;
        -- Tamanho, em KiB, da janela que o chip da FLASH atende a partir da base; a leitura além dela devolve zero.
        flash_window_kib : natural := 1024;
        -- O dado lido segue a região do último pedido concluído, e não o endereço atual (mestre sem cache de dados).
        hold_rdata     : boolean := false
    );
    port (
        -- Clock do módulo.
        i_clk : in    std_logic;
        -- Reset, ativo em '1'.
        i_rst : in    std_logic;

        -- Mestre: endereço do pedido.
        i_addr    : in    addr_t;
        -- Mestre: dado de escrita (palavra 0).
        i_wdata   : in    word_t;
        -- Mestre: habilita de bytes da escrita.
        i_byteena : in    std_logic_vector(XLEN / 8 - 1 downto 0);
        -- Mestre: pedido de leitura ('1').
        i_rden    : in    std_logic;
        -- Mestre: pedido de escrita ('1').
        i_wren    : in    std_logic;
        -- Mestre: pedido de linha de quatro palavras ('1').
        i_line    : in    std_logic;
        -- Mestre: palavras 1 a 3 do dado de escrita da linha.
        i_wdata_x : in    std_logic_vector(3 * XLEN - 1 downto 0) := (others => '0');
        -- Mestre: o pedido foi consumido neste ciclo.
        i_advance : in    std_logic;
        -- Mestre: pedido concluído, o dado lido é válido ('1').
        o_ready   : out   std_logic;
        -- Mestre: palavra lida (a palavra 0 da linha).
        o_rdata   : out   word_t;
        -- Mestre: palavras 1 a 3 da linha lida.
        o_rdata_x : out   std_logic_vector(3 * XLEN - 1 downto 0);

        -- SDRAM: endereço do pedido.
        o_s_addr    : out   addr_t;
        -- SDRAM: dado de escrita (palavra 0).
        o_s_wdata   : out   word_t;
        -- SDRAM: habilita de bytes da escrita.
        o_s_byteena : out   std_logic_vector(XLEN / 8 - 1 downto 0);
        -- SDRAM: pedido de leitura ('1' só para endereços da SDRAM).
        o_s_rden    : out   std_logic;
        -- SDRAM: pedido de escrita ('1' só para endereços da SDRAM).
        o_s_wren    : out   std_logic;
        -- SDRAM: pedido de linha.
        o_s_line    : out   std_logic;
        -- SDRAM: palavras 1 a 3 do dado de escrita da linha.
        o_s_wdata_x : out   std_logic_vector(3 * XLEN - 1 downto 0);
        -- SDRAM: o pedido foi consumido (só para endereços da SDRAM).
        o_s_advance : out   std_logic;
        -- SDRAM: pedido concluído.
        i_s_ready   : in    std_logic;
        -- SDRAM: palavra lida.
        i_s_rdata   : in    word_t;
        -- SDRAM: palavras 1 a 3 da linha lida.
        i_s_rdata_x : in    std_logic_vector(3 * XLEN - 1 downto 0) := (others => '0');

        -- FLASH: endereço do pedido.
        o_f_addr    : out   addr_t;
        -- FLASH: pedido de leitura ('1' só para leituras da FLASH dentro da janela).
        o_f_rden    : out   std_logic;
        -- FLASH: pedido de linha.
        o_f_line    : out   std_logic;
        -- FLASH: o pedido foi consumido (só para endereços da FLASH).
        o_f_advance : out   std_logic;
        -- FLASH: pedido concluído.
        i_f_ready   : in    std_logic;
        -- FLASH: palavra lida.
        i_f_rdata   : in    word_t;
        -- FLASH: palavras 1 a 3 da linha lida.
        i_f_rdata_x : in    std_logic_vector(3 * XLEN - 1 downto 0) := (others => '0')
    );
end entity mem_region_router;

architecture rtl of mem_region_router is

    -- O pedido é da FLASH.
    signal is_flash    : std_logic;
    -- O endereço está além da janela que o chip da FLASH atende.
    signal beyond      : std_logic;
    -- O pedido da FLASH é concluído aqui (store ou leitura fora da janela).
    signal is_local    : std_logic;
    -- O pedido local já foi visto, ready sobe e fica até advance.
    signal local_ready : std_logic := '0';
    -- Região que escolhe o dado lido: a do endereço atual, ou a do último pedido concluído com hold_rdata.
    signal rd_flash    : std_logic;
    -- Idem para o dado local (zero).
    signal rd_local    : std_logic;
    -- Pedido concluído da região do endereço atual.
    signal ready_sel   : std_logic;

begin

    -- A palavra do núcleo tem XLEN bits, mas a linha de 4 palavras, o mapa de bits do endereço e a largura física do
    -- dispositivo deste bloco supõem a palavra de 32 bits e só elaboram com XLEN = 32.
    assert XLEN = 32
        report "este bloco só elabora com XLEN = 32"
        severity failure;

    is_flash <= in_window(i_addr, flash_base_kib, flash_end_kib);
    beyond   <= '1' when unsigned(i_addr) >= shift_left(to_unsigned(flash_base_kib + flash_window_kib, ADDR_BITS), 10) else '0';
    is_local <= is_flash and (i_wren or (i_rden and beyond));

    o_s_addr    <= i_addr;
    o_s_wdata   <= i_wdata;
    o_s_byteena <= i_byteena;
    o_s_rden    <= i_rden and not is_flash;
    o_s_wren    <= i_wren and not is_flash;
    o_s_line    <= i_line;
    o_s_wdata_x <= i_wdata_x;
    o_s_advance <= i_advance and not is_flash;

    o_f_addr    <= i_addr;
    o_f_rden    <= i_rden and is_flash and not is_local;
    o_f_line    <= i_line;
    o_f_advance <= i_advance and is_flash and not is_local;

    ready_sel <= local_ready when is_local = '1' else
                 i_f_ready when is_flash = '1' else
                 i_s_ready;
    o_ready   <= ready_sel;
    o_rdata   <= (others => '0') when rd_local = '1' else
                 i_f_rdata when rd_flash = '1' else
                 i_s_rdata;
    o_rdata_x <= (others => '0') when rd_local = '1' else
                 i_f_rdata_x when rd_flash = '1' else
                 i_s_rdata_x;

    -- O dado lido segue o endereço atual.

    gen_live : if not hold_rdata generate
    begin
        rd_flash <= is_flash;
        rd_local <= is_local;
    end generate gen_live;

    -- O dado lido segue a região do último pedido concluído, guardada na borda em que o chip troca o dado.

    gen_hold : if hold_rdata generate
        -- O dado lido que o mestre vê vem da FLASH.
        signal held_flash : std_logic := '0';
        -- O dado lido que o mestre vê é zero (o último pedido concluído foi local).
        signal held_local : std_logic := '0';
        -- O pedido atual conclui neste ciclo: acesso pedido, consumido e pronto.
        signal completes  : std_logic;
    begin
        completes <= (i_rden or i_wren) and i_advance and ready_sel;
        rd_flash  <= held_flash;
        rd_local  <= held_local;

        p_hold_regs : process (i_clk) is
        begin

            if rising_edge(i_clk) then
                if i_rst = '1' then
                    held_flash <= '0';
                    held_local <= '0';
                elsif completes = '1' then
                    held_flash <= is_flash;
                    held_local <= is_local;
                end if;
            end if;

        end process p_hold_regs;

    end generate gen_hold;

    p_local_ready : process (i_clk) is
    begin

        if rising_edge(i_clk) then
            if i_rst = '1' then
                local_ready <= '0';
            elsif local_ready = '1' then
                if i_advance = '1' then
                    local_ready <= '0';
                end if;
            elsif is_local = '1' then
                local_ready <= '1';
            end if;
        end if;

    end process p_local_ready;

end architecture rtl;
