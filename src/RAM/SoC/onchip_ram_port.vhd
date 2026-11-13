-- =============================================================================
-- Adaptador da RAM interna ao contrato de linha da memória
--
-- Põe um bloco de RAM da FPGA (ram.vhd, ou o modelo ram_simulation) atrás do
-- mesmo contrato do lado da memória que a dcache e o mem_region_router esperam
-- do ram_chip, para uma RAM interna poder ficar atrás de cache. É sintetizável:
-- não tem memória própria, só uma máquina de estados e os registradores do
-- acesso; o armazenamento é o bloco ligado às portas o_mem_* e i_mem_q.
--
-- Contrato do lado do requisitante (igual ao do ram_chip e ao da
-- sdram_cpu_bridge): o acesso fica em addr, rden ou wren e line enquanto o
-- estágio que o pede está parado. ready sobe quando o acesso termina e
-- permanece em nível alto até mem_advance indicar que o pipeline andou. O dado
-- lido só muda nessa mesma borda, porque o load que ainda está no estágio de
-- write-back lê o valor anterior até lá. Um acesso de linha move as quatro
-- palavras que começam em addr alinhado em 16 bytes: a palavra 0 em wdata,
-- byteena e rdata, e as palavras 1 a 3 em wdata_x, byteena_x e rdata_x, a
-- palavra 1 nos bits mais baixos. A escrita atualiza só os bytes habilitados.
--
-- Latência constante: com E0 a borda em que o pedido é visto, o acesso de
-- palavra termina na borda E2 e o de linha na borda E5, e ready sobe logo
-- depois, igual para leitura e escrita. O bloco de RAM tem uma porta de
-- palavra com leitura registrada, então uma linha são quatro acessos seguidos
-- a ele, um por borda.
--
-- Latência emulada: o genérico latency, quando maior que zero, conta as mesmas
-- bordas do ram_chip (a máquina latency_counter é a mesma) e o acesso só termina
-- na maior entre essa contagem e a estrutural acima. Com latency de pelo menos 5
-- o acesso termina na borda E_latency, palavra ou linha, igual ao ram_chip de
-- mesma latência; abaixo disso vale o mínimo do bloco (uma linha não cabe em
-- menos de 5 bordas). Zero deixa só a latência estrutural.
--
-- Janela: o endereço usa os 26 bits baixos, e a janela do chip começa base_kib
-- KiB dentro dos 64 MB da região e tem size_bytes bytes. Fora dela a leitura
-- devolve zero e a escrita é descartada, como no ram_chip.
--
-- Porta de depuração por palavra: o_dbg_word_data é a palavra de índice
-- i_dbg_word_addr, contado do início da janela, lida pela mesma porta do bloco
-- nos ciclos em que nenhum acesso a usa (sem pedido, ou com o acesso concluído
-- esperando o avanço). Aparece 2 bordas depois da troca do índice quando a
-- porta está livre, e mantém o último valor lido enquanto não está. Fora da
-- janela vale zero. Um testbench lê por ela o tohost sem passar pelas caches.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.config_pkg.all;
use work.utils_pkg.all;
use work.ram_pkg.all;

entity onchip_ram_port is
    generic (
        -- Tamanho da janela da RAM em bytes, uma potência de dois de 16 bytes a 32 MB (1048576 é 1 MB).
        size_bytes : positive := 1048576;
        -- Onde a RAM começa dentro dos 64 MB da região, em KiB: o endereço da RAM é o da região menos
        -- esta base. Origem: o espaço de endereços da região da memória que o Memory enxerga (26 bits
        -- baixos), não o mapa do Core.
        base_kib   : natural  := 0;
        -- Bordas mínimas entre o pedido e a conclusão do acesso, como a latência do ram_chip (0 usa só a estrutural).
        latency    : natural  := 0
    );
    port (
        -- Clock do módulo e do bloco de RAM.
        i_clk : in    std_logic;
        -- Reset, ativo em '1'.
        i_rst : in    std_logic;

        -- Endereço de byte do acesso.
        i_addr        : in    addr_t;
        -- Dado de escrita (palavra 0 da linha).
        i_wdata       : in    word_t;
        -- Habilita de bytes da escrita, um bit por byte (palavra 0).
        i_byteena     : in    std_logic_vector(3 downto 0);
        -- Pedido de leitura ('1' = lê).
        i_rden        : in    std_logic;
        -- Pedido de escrita ('1' = escreve), que prevalece sobre a leitura se os dois vierem juntos.
        i_wren        : in    std_logic;
        -- O pipeline avançou neste ciclo, o acesso concluído pode terminar.
        i_mem_advance : in    std_logic;
        -- Acesso concluído, o dado lido é válido ('1').
        o_ready       : out   std_logic;
        -- Dado lido (palavra 0 da linha).
        o_rdata       : out   word_t;
        -- Acesso de linha, quatro palavras seguidas ('1').
        i_line        : in    std_logic                     := '0';
        -- Palavras 1 a 3 do dado de escrita da linha, a palavra 1 nos bits mais baixos.
        i_wdata_x     : in    std_logic_vector(95 downto 0) := (others => '0');
        -- Habilita de bytes das palavras 1 a 3 da linha, quatro bits por palavra.
        i_byteena_x   : in    std_logic_vector(11 downto 0) := (others => '0');
        -- Palavras 1 a 3 do dado lido da linha.
        o_rdata_x     : out   std_logic_vector(95 downto 0);

        -- Bloco de RAM: índice da palavra (endereço de byte sem os dois bits baixos).
        o_mem_addr    : out   std_logic_vector(log2_exact(size_bytes) - 3 downto 0);
        -- Bloco de RAM: dado de escrita.
        o_mem_wdata   : out   std_logic_vector(31 downto 0);
        -- Bloco de RAM: habilita de bytes da escrita, um bit por byte.
        o_mem_byteena : out   std_logic_vector(3 downto 0);
        -- Bloco de RAM: habilita de leitura ('1').
        o_mem_rden    : out   std_logic;
        -- Bloco de RAM: habilita de escrita ('1').
        o_mem_wren    : out   std_logic;
        -- Bloco de RAM: palavra lida, válida um ciclo depois do endereço.
        i_mem_q       : in    std_logic_vector(31 downto 0);

        -- Índice da palavra que a porta de depuração lê, a partir do início da janela.
        i_dbg_word_addr : in    std_logic_vector(23 downto 0) := (others => '0');
        -- Palavra da RAM no índice de i_dbg_word_addr.
        o_dbg_word_data : out   std_logic_vector(31 downto 0)
    );
end entity onchip_ram_port;

architecture rtl of onchip_ram_port is

    -- Bits de endereço da janela (falha se size_bytes não for uma potência de dois).
    constant WINDOW_BITS : natural := log2_exact(size_bytes);
    -- Bits do índice de palavra do bloco de RAM.
    constant WORD_BITS   : natural := WINDOW_BITS - 2;
    -- Base da janela dentro da região, em bytes.
    constant BASE_BYTES  : natural := base_kib * 1024;

    -- Estados do acesso: livre, falando com o bloco, esperando o resto da latência emulada, concluído à espera do
    -- avanço.
    type state_t is (S_IDLE, S_ACCESS, S_HOLD, S_DONE);

    -- Estado do acesso.
    signal st        : state_t                                  := S_IDLE;
    -- Passo do acesso: o passo k emite a palavra k, e o passo seguinte ao último só recolhe.
    signal step      : unsigned(2 downto 0)                     := (others => '0');
    -- O acesso é uma escrita.
    signal acc_we    : std_logic                                := '0';
    -- O acesso é de linha.
    signal acc_line  : std_logic                                := '0';
    -- O endereço do acesso está dentro da janela.
    signal acc_in    : std_logic                                := '0';
    -- Índice da primeira palavra do acesso (alinhado em 4 palavras numa linha).
    signal acc_word  : std_logic_vector(WORD_BITS - 1 downto 0) := (others => '0');
    -- Dado de escrita capturado (palavra 0).
    signal acc_wdata : word_t            := (others => '0');
    -- Habilita de bytes capturado (palavra 0).
    signal acc_be    : std_logic_vector(3 downto 0)             := (others => '0');
    -- Palavras 1 a 3 do dado de escrita capturado.
    signal acc_wdx   : std_logic_vector(95 downto 0)            := (others => '0');
    -- Habilita de bytes das palavras 1 a 3 capturado.
    signal acc_bex   : std_logic_vector(11 downto 0)            := (others => '0');
    -- Palavra 0 lida, à espera do avanço do pipeline.
    signal pend      : word_t            := (others => '0');
    -- Palavras 1 a 3 lidas, à espera do avanço do pipeline.
    signal pend_x    : std_logic_vector(95 downto 0)            := (others => '0');
    -- Palavra 0 entregue ao requisitante.
    signal rdata_q   : word_t            := (others => '0');
    -- Palavras 1 a 3 entregues ao requisitante.
    signal rdx_q     : std_logic_vector(95 downto 0)            := (others => '0');

    -- O acesso emite palavras ao bloco neste ciclo.
    signal issue     : std_logic;
    -- A porta do bloco está livre e a depuração emite a leitura dela neste ciclo.
    signal dbg_issue : std_logic;
    -- Uma leitura de depuração está em voo, a palavra chega no próximo ciclo.
    signal dbg_pend  : std_logic                     := '0';
    -- O índice da leitura em voo está fora da janela.
    signal dbg_out   : std_logic                     := '0';
    -- Palavra de depuração entregue.
    signal dbg_q     : std_logic_vector(31 downto 0) := (others => '0');
    -- Índice de palavra do acesso em curso, com o passo somado nos dois bits baixos.
    signal acc_index : std_logic_vector(WORD_BITS - 1 downto 0);
    -- Índice de palavra pedido à depuração.
    signal dbg_index : std_logic_vector(WORD_BITS - 1 downto 0);
    -- Último passo que emite uma palavra: 0 numa palavra, 3 numa linha.
    signal last_step : unsigned(2 downto 0);
    -- Início da contagem da latência emulada ('1' carrega).
    signal lat_load  : std_logic;
    -- Ainda falta mais de uma borda da latência emulada.
    signal lat_wait  : std_logic;

begin

    assert size_bytes >= 16 and size_bytes <= 33554432
        report "size_bytes must be a power of two from 16 bytes to 32 MB"
        severity failure;

    -- A contagem começa junto com o acesso e só existe quando a latência emulada é pedida.
    lat_load <= '1' when latency > 0 and st = S_IDLE and (i_rden = '1' or i_wren = '1') else '0';

    u_latency : entity work.latency_counter
        generic map (
            max_count => latency + 1
        )
        port map (
            i_clk   => i_clk,
            i_rst   => i_rst,
            i_load  => lat_load,
            i_count => latency,
            o_last  => open,
            o_wait  => lat_wait
        );

    last_step <= to_unsigned(3, 3) when acc_line = '1' else to_unsigned(0, 3);
    issue     <= '1' when st = S_ACCESS and step <= last_step else '0';
    dbg_issue <= '1' when (st = S_IDLE and i_rden = '0' and i_wren = '0') or st = S_DONE else '0';
    dbg_index <= i_dbg_word_addr(WORD_BITS - 1 downto 0);
    -- O passo entra nos dois bits baixos: eles valem zero no índice de uma linha, e o passo vale zero numa palavra.
    acc_index <= acc_word(WORD_BITS - 1 downto 2) & (acc_word(1 downto 0) or std_logic_vector(step(1 downto 0)));

    o_ready         <= '1' when st = S_DONE else '0';
    o_rdata         <= rdata_q;
    o_rdata_x       <= rdx_q;
    o_dbg_word_data <= dbg_q;

    o_mem_addr    <= dbg_index when dbg_issue = '1' else acc_index;
    o_mem_rden    <= dbg_issue or (issue and not acc_we and acc_in);
    o_mem_wren    <= issue and acc_we and acc_in;
    o_mem_byteena <= acc_be when step = 0 else
                     acc_bex(3 downto 0) when step = 1 else
                     acc_bex(7 downto 4) when step = 2 else
                     acc_bex(11 downto 8);
    o_mem_wdata   <= acc_wdata when step = 0 else
                     acc_wdx(31 downto 0) when step = 1 else
                     acc_wdx(63 downto 32) when step = 2 else
                     acc_wdx(95 downto 64);

    -- Máquina do acesso: captura o pedido, emite as palavras ao bloco, recolhe as lidas e espera o avanço.
    p_access_fsm : process (i_clk) is

        -- Endereço do pedido dentro da região, menos a base da janela.
        variable offset : unsigned(25 downto 0);
        -- O pedido cai dentro da janela.
        variable inside : boolean;

    begin

        if rising_edge(i_clk) then
            if i_rst = '1' then
                st <= S_IDLE;
            else

                case st is

                    when S_IDLE =>

                        if i_rden = '1' or i_wren = '1' then
                            inside := unsigned(i_addr(25 downto 0)) >= to_unsigned(BASE_BYTES, 26);
                            offset := window_offset(i_addr, base_kib);
                            if offset(25 downto WINDOW_BITS) /= 0 then
                                inside := false;
                            end if;
                            acc_word <= std_logic_vector(offset(WINDOW_BITS - 1 downto 2));
                            if i_line = '1' then
                                acc_word(1 downto 0) <= "00";
                            end if;
                            if inside then
                                acc_in <= '1';
                            else
                                acc_in <= '0';
                            end if;
                            acc_line  <= i_line;
                            acc_we    <= i_wren;
                            acc_wdata <= i_wdata;
                            acc_be    <= i_byteena;
                            acc_wdx   <= i_wdata_x;
                            acc_bex   <= i_byteena_x;
                            step      <= (others => '0');
                            st        <= S_ACCESS;
                        end if;

                    when S_ACCESS =>

                        -- A palavra emitida no passo k chega ao bloco no passo k + 1.
                        if acc_we = '0' and step > 0 then
                            if step = 1 then
                                pend <= i_mem_q and (31 downto 0 => acc_in);
                            elsif step = 2 then
                                pend_x(31 downto 0) <= i_mem_q and (31 downto 0 => acc_in);
                            elsif step = 3 then
                                pend_x(63 downto 32) <= i_mem_q and (31 downto 0 => acc_in);
                            else
                                pend_x(95 downto 64) <= i_mem_q and (31 downto 0 => acc_in);
                            end if;
                        end if;
                        if step > last_step then
                            if lat_wait = '1' then
                                st <= S_HOLD;
                            else
                                st <= S_DONE;
                            end if;
                        else
                            step <= step + 1;
                        end if;

                    when S_HOLD =>

                        -- Acesso feito no bloco, esperando o resto da latência emulada.
                        if lat_wait = '0' then
                            st <= S_DONE;
                        end if;

                    when S_DONE =>

                        if i_mem_advance = '1' then
                            if acc_we = '0' then
                                rdata_q <= pend;
                                rdx_q   <= pend_x;
                            end if;
                            st <= S_IDLE;
                        end if;

                end case;

            end if;
        end if;

    end process p_access_fsm;

    -- Porta de depuração: recolhe a palavra da leitura emitida no ciclo anterior.
    p_debug_port : process (i_clk) is
    begin

        if rising_edge(i_clk) then
            if i_rst = '1' then
                dbg_pend <= '0';
            else
                dbg_pend <= dbg_issue;
                if dbg_issue = '1' then
                    if i_dbg_word_addr(23 downto WORD_BITS) = (23 downto WORD_BITS => '0') then
                        dbg_out <= '0';
                    else
                        dbg_out <= '1';
                    end if;
                end if;
                if dbg_pend = '1' then
                    if dbg_out = '1' then
                        dbg_q <= (others => '0');
                    else
                        dbg_q <= i_mem_q;
                    end if;
                end if;
            end if;
        end if;

    end process p_debug_port;

end architecture rtl;
