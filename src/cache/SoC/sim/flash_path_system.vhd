-- =============================================================================
-- Caminho da FLASH de ponta a ponta, para o teste de conjunto
--
-- Liga o lado da busca (a cache de instruções, ou a ponte de busca no lugar
-- dela quando use_bridge pede), dois roteadores de região, o árbitro de FLASH e
-- o chip de FLASH a um armazenamento de leitura registrada cujo conteúdo é uma
-- função do endereço (o padrão de pattern_word, do sim_util_pkg).
-- O mestre B é uma porta direta que faz o papel do lado da memória da cache de
-- dados. Os lados da SDRAM dos dois roteadores ficam sem escravo: a saída
-- o_si_rden / o_sd_rden / o_sd_wren mostra se algum pedido chegou até lá.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sim_util_pkg.all;

entity flash_path_system is
    generic (
        -- Bordas até a primeira palavra do chip.
        first_latency : natural := 12;
        -- Bordas entre as palavras de uma linha do chip.
        next_latency  : natural := 3;
        -- Verdadeiro: a ponte de busca (ifetch_bridge) faz o lado da busca, no lugar da cache de
        -- instruções.
        use_bridge    : boolean := false;
        -- Só com use_bridge: a ponte pede a linha de quatro palavras (true) ou só a palavra (false).
        fetch_line    : boolean := true
    );
    port (
        -- Clock do sistema.
        i_clk : in    std_logic;
        -- Reset, ativo em '1'.
        i_rst : in    std_logic;

        -- Busca da cache de instruções ou da ponte: endereço do PC.
        i_addr       : in    std_logic_vector(31 downto 0);
        -- Busca da cache de instruções ou da ponte: o endereço pertence a uma região com cache (ou à
        -- FLASH ou à SDRAM, na ponte).
        i_sel        : in    std_logic;
        -- Busca da cache de instruções ou da ponte: pulso que derruba as linhas (na ponte, descarta o
        -- registrador de busca, o fence.i).
        i_invalidate : in    std_logic;
        -- Busca da cache de instruções ou da ponte: a instrução em o_data é a do endereço.
        o_ready      : out   std_logic;
        -- Busca da cache de instruções ou da ponte: instrução buscada.
        o_data       : out   std_logic_vector(31 downto 0);
        -- Busca da ponte: pulso de um ciclo depois do início de cada pedido à memória; sempre '0' com a
        -- cache de instruções.
        o_miss       : out   std_logic;

        -- Mestre B (papel da cache de dados): endereço do pedido.
        i_b_addr    : in    std_logic_vector(31 downto 0);
        -- Mestre B: pedido de leitura.
        i_b_rden    : in    std_logic;
        -- Mestre B: pedido de escrita.
        i_b_wren    : in    std_logic;
        -- Mestre B: pedido de linha.
        i_b_line    : in    std_logic;
        -- Mestre B: o pedido foi consumido neste ciclo.
        i_b_advance : in    std_logic;
        -- Mestre B: pedido concluído.
        o_b_ready   : out   std_logic;
        -- Mestre B: palavra lida.
        o_b_rdata   : out   std_logic_vector(31 downto 0);
        -- Mestre B: palavras 1 a 3 da linha lida.
        o_b_rdata_x : out   std_logic_vector(95 downto 0);

        -- Pedido de leitura que o roteador da cache de instruções mandou à SDRAM.
        o_si_rden   : out   std_logic;
        -- Pedido de leitura que o roteador do mestre B mandou à SDRAM.
        o_sd_rden   : out   std_logic;
        -- Pedido de escrita que o roteador do mestre B mandou à SDRAM.
        o_sd_wren   : out   std_logic;
        -- Quantos pedidos o chip de FLASH recebeu.
        o_chip_reqs : out   std_logic_vector(15 downto 0)
    );
end entity flash_path_system;

architecture rtl of flash_path_system is

    -- Endereço pedido pela cache de instruções ao roteador I.
    signal ic_addr    : std_logic_vector(31 downto 0);
    -- Palavra devolvida pelo roteador I à cache de instruções.
    signal ic_rdata   : std_logic_vector(31 downto 0);
    -- Pedido de leitura da cache de instruções ao roteador I.
    signal ic_rden    : std_logic;
    -- A cache de instruções pede a linha inteira.
    signal ic_line    : std_logic;
    -- A cache de instruções avança para a palavra seguinte da linha.
    signal ic_adv     : std_logic;
    -- O roteador I tem a palavra pronta para a cache de instruções.
    signal ic_ready   : std_logic;
    -- Palavras 1 a 3 da linha devolvidas à cache de instruções.
    signal ic_rdata_x : std_logic_vector(95 downto 0);

    -- Endereço que o roteador I manda ao árbitro (porta A).
    signal ra_addr    : std_logic_vector(31 downto 0);
    -- Palavra que o árbitro devolve ao roteador I.
    signal ra_rdata   : std_logic_vector(31 downto 0);
    -- Pedido de leitura do roteador I ao árbitro.
    signal ra_rden    : std_logic;
    -- O roteador I pede a linha inteira ao árbitro.
    signal ra_line    : std_logic;
    -- O roteador I avança para a palavra seguinte da linha.
    signal ra_adv     : std_logic;
    -- O árbitro tem a palavra pronta para o roteador I.
    signal ra_ready   : std_logic;
    -- Palavras 1 a 3 da linha que o árbitro devolve ao roteador I.
    signal ra_rdata_x : std_logic_vector(95 downto 0);

    -- Endereço que o roteador do mestre B manda ao árbitro (porta B).
    signal rb_addr    : std_logic_vector(31 downto 0);
    -- Palavra que o árbitro devolve ao roteador do mestre B.
    signal rb_rdata   : std_logic_vector(31 downto 0);
    -- Pedido de leitura do roteador do mestre B ao árbitro.
    signal rb_rden    : std_logic;
    -- O roteador do mestre B pede a linha inteira ao árbitro.
    signal rb_line    : std_logic;
    -- O roteador do mestre B avança para a palavra seguinte da linha.
    signal rb_adv     : std_logic;
    -- O árbitro tem a palavra pronta para o roteador do mestre B.
    signal rb_ready   : std_logic;
    -- Palavras 1 a 3 da linha que o árbitro devolve ao roteador do mestre B.
    signal rb_rdata_x : std_logic_vector(95 downto 0);

    -- Endereço que o árbitro manda ao chip.
    signal ch_addr    : std_logic_vector(31 downto 0);
    -- Palavra que o chip devolve ao árbitro.
    signal ch_rdata   : std_logic_vector(31 downto 0);
    -- Endereço de leitura do armazenamento do chip.
    signal mem_addr   : std_logic_vector(31 downto 0);
    -- Palavra lida do armazenamento do chip.
    signal mem_data   : std_logic_vector(31 downto 0);
    -- Pedido de leitura do árbitro ao chip.
    signal ch_rden    : std_logic;
    -- O árbitro pede a linha inteira ao chip.
    signal ch_line    : std_logic;
    -- O árbitro avança para a palavra seguinte da linha.
    signal ch_adv     : std_logic;
    -- O chip tem a palavra pronta para o árbitro.
    signal ch_ready   : std_logic;
    -- Palavras 1 a 3 da linha que o chip devolve ao árbitro.
    signal ch_rdata_x : std_logic_vector(95 downto 0);

    -- Endereço de leitura do roteador I para a SDRAM, sem escravo.
    signal si_addr    : std_logic_vector(31 downto 0);
    -- Endereço do roteador do mestre B para a SDRAM, sem escravo.
    signal sd_addr    : std_logic_vector(31 downto 0);
    -- Dado de escrita do roteador I para a SDRAM, sem escravo.
    signal si_wdata   : std_logic_vector(31 downto 0);
    -- Dado de escrita do roteador do mestre B para a SDRAM, sem escravo.
    signal sd_wdata   : std_logic_vector(31 downto 0);
    -- Máscara de bytes do roteador I para a SDRAM.
    signal si_be      : std_logic_vector(3 downto 0);
    -- Máscara de bytes do roteador do mestre B para a SDRAM.
    signal sd_be      : std_logic_vector(3 downto 0);
    -- Pedido de escrita do roteador I para a SDRAM.
    signal si_wren    : std_logic;
    -- O roteador I pede a linha inteira à SDRAM.
    signal si_line    : std_logic;
    -- O roteador I avança para a palavra seguinte da linha na SDRAM.
    signal si_adv     : std_logic;
    -- O roteador do mestre B pede a linha inteira à SDRAM.
    signal sd_line    : std_logic;
    -- O roteador do mestre B avança para a palavra seguinte da linha na SDRAM.
    signal sd_adv     : std_logic;
    -- Dado de escrita estendido (palavras 1 a 3) do roteador I para a SDRAM.
    signal si_wdata_x : std_logic_vector(95 downto 0);
    -- Dado de escrita estendido (palavras 1 a 3) do roteador do mestre B.
    signal sd_wdata_x : std_logic_vector(95 downto 0);

    -- Contagem de pedidos que chegam ao chip.
    signal reqs    : unsigned(15 downto 0) := (others => '0');
    -- O chip está livre e vê um pedido novo.
    signal ch_busy : std_logic             := '0';

begin

    -- Lado da busca com a cache de instruções.

    gen_icache : if not use_bridge generate

        u_icache : entity work.icache
            port map (
                i_clk        => i_clk,
                i_clk_cpu    => i_clk,
                i_rst        => i_rst,
                i_addr       => i_addr,
                i_sel        => i_sel,
                o_ready      => o_ready,
                o_data       => o_data,
                i_invalidate => i_invalidate,
                o_d_addr     => ic_addr,
                o_d_rden     => ic_rden,
                o_d_advance  => ic_adv,
                i_d_ready    => ic_ready,
                i_d_rdata    => ic_rdata,
                o_d_line     => ic_line,
                i_d_rdata_x  => ic_rdata_x
            );

        o_miss <= '0';
    end generate gen_icache;

    -- Lado da busca com a ponte de busca, sem cache.

    gen_bridge : if use_bridge generate

        u_bridge : entity work.ifetch_bridge
            generic map (
                fetch_line => fetch_line
            )
            port map (
                i_clk        => i_clk,
                i_rst        => i_rst,
                i_addr       => i_addr,
                i_sel        => i_sel,
                o_ready      => o_ready,
                o_data       => o_data,
                i_invalidate => i_invalidate,
                o_miss       => o_miss,
                o_d_addr     => ic_addr,
                o_d_rden     => ic_rden,
                o_d_advance  => ic_adv,
                i_d_ready    => ic_ready,
                i_d_rdata    => ic_rdata,
                o_d_line     => ic_line,
                i_d_rdata_x  => ic_rdata_x
            );

    end generate gen_bridge;

    u_router_i : entity work.mem_region_router
        port map (
            i_clk       => i_clk,
            i_rst       => i_rst,
            i_addr      => ic_addr,
            i_wdata     => (others => '0'),
            i_byteena   => (others => '0'),
            i_rden      => ic_rden,
            i_wren      => '0',
            i_line      => ic_line,
            i_advance   => ic_adv,
            o_ready     => ic_ready,
            o_rdata     => ic_rdata,
            o_rdata_x   => ic_rdata_x,
            o_s_addr    => si_addr,
            o_s_wdata   => si_wdata,
            o_s_byteena => si_be,
            o_s_rden    => o_si_rden,
            o_s_wren    => si_wren,
            o_s_line    => si_line,
            o_s_wdata_x => si_wdata_x,
            o_s_advance => si_adv,
            i_s_ready   => '0',
            i_s_rdata   => (others => '0'),
            o_f_addr    => ra_addr,
            o_f_rden    => ra_rden,
            o_f_line    => ra_line,
            o_f_advance => ra_adv,
            i_f_ready   => ra_ready,
            i_f_rdata   => ra_rdata,
            i_f_rdata_x => ra_rdata_x
        );

    u_router_b : entity work.mem_region_router
        port map (
            i_clk       => i_clk,
            i_rst       => i_rst,
            i_addr      => i_b_addr,
            i_wdata     => (others => '0'),
            i_byteena   => (others => '1'),
            i_rden      => i_b_rden,
            i_wren      => i_b_wren,
            i_line      => i_b_line,
            i_advance   => i_b_advance,
            o_ready     => o_b_ready,
            o_rdata     => o_b_rdata,
            o_rdata_x   => o_b_rdata_x,
            o_s_addr    => sd_addr,
            o_s_wdata   => sd_wdata,
            o_s_byteena => sd_be,
            o_s_rden    => o_sd_rden,
            o_s_wren    => o_sd_wren,
            o_s_line    => sd_line,
            o_s_wdata_x => sd_wdata_x,
            o_s_advance => sd_adv,
            i_s_ready   => '0',
            i_s_rdata   => (others => '0'),
            o_f_addr    => rb_addr,
            o_f_rden    => rb_rden,
            o_f_line    => rb_line,
            o_f_advance => rb_adv,
            i_f_ready   => rb_ready,
            i_f_rdata   => rb_rdata,
            i_f_rdata_x => rb_rdata_x
        );

    u_arbiter : entity work.flash_arbiter
        port map (
            i_clk       => i_clk,
            i_rst       => i_rst,
            i_a_addr    => ra_addr,
            i_a_rden    => ra_rden,
            i_a_line    => ra_line,
            i_a_advance => ra_adv,
            o_a_ready   => ra_ready,
            o_a_rdata   => ra_rdata,
            o_a_rdata_x => ra_rdata_x,
            i_b_addr    => rb_addr,
            i_b_rden    => rb_rden,
            i_b_line    => rb_line,
            i_b_advance => rb_adv,
            o_b_ready   => rb_ready,
            o_b_rdata   => rb_rdata,
            o_b_rdata_x => rb_rdata_x,
            o_addr      => ch_addr,
            o_rden      => ch_rden,
            o_line      => ch_line,
            o_advance   => ch_adv,
            i_ready     => ch_ready,
            i_rdata     => ch_rdata,
            i_rdata_x   => ch_rdata_x
        );

    u_chip : entity work.flash_chip
        generic map (
            first_latency => first_latency, next_latency => next_latency
        )
        port map (
            i_clk      => i_clk,
            i_rst      => i_rst,
            i_addr     => ch_addr,
            i_rden     => ch_rden,
            i_line     => ch_line,
            i_advance  => ch_adv,
            o_ready    => ch_ready,
            o_rdata    => ch_rdata,
            o_rdata_x  => ch_rdata_x,
            o_mem_addr => mem_addr,
            i_mem_data => mem_data
        );

    -- Armazenamento de leitura registrada: a palavra do endereço da borda anterior.
    p_read_storage : process (i_clk) is
    begin

        if rising_edge(i_clk) then
            mem_data <= pattern_word(mem_addr(31 downto 2) & "00");
        end if;

    end process p_read_storage;

    -- Conta os pedidos que o chip aceita (uma subida de rden com o chip livre).
    p_count_requests : process (i_clk) is
    begin

        if rising_edge(i_clk) then
            if i_rst = '1' then
                reqs    <= (others => '0');
                ch_busy <= '0';
            else
                if ch_busy = '0' and ch_rden = '1' then
                    reqs    <= reqs + 1;
                    ch_busy <= '1';
                elsif ch_busy = '1' and ch_adv = '1' and ch_ready = '1' then
                    ch_busy <= '0';
                end if;
            end if;
        end if;

    end process p_count_requests;

    o_chip_reqs <= std_logic_vector(reqs);

end architecture rtl;
