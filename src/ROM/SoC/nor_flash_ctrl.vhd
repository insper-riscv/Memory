-- =============================================================================
-- Controlador de FLASH NOR paralela de 8 bits (leitura assíncrona e em página)
--
-- Atende o SoC com o contrato do flash_chip (pedido de palavra ou de linha de
-- quatro palavras, handshake o_ready/i_advance) e comanda os pinos de um chip NOR
-- de barramento de 8 bits, como o S29GL064N da DE2-115 (23 bits de endereço, modo
-- byte). Além da leitura, implementa a face de comandos K4 do flash_cmd_port
-- (habilitar escrita, apagar setor, gravar página, proteger e desproteger) com os
-- ciclos de escrita reais do chip: sequência de desbloqueio, comando e dado, e a
-- espera do fim da operação pelo pino RY.
--
-- Leitura. Uma palavra de 32 bits são quatro leituras de byte na mesma página de
-- 16 bytes do chip, e uma linha são dezesseis. O endereço sai de um registrador
-- junto com CE# e OE#. A primeira leitura espera n_first ciclos, o teto do tempo
-- de acesso aleatório sobre o período do clock, e cada leitura seguinte da mesma
-- página espera n_next ciclos, o teto do tempo de acesso de página. O dado é
-- capturado no fim de cada espera, no mesmo clock em que o endereço seguinte
-- sai. Com t_acc 90 ns e t_pacc 25 ns, a 50 MHz valem 5 e 2 ciclos, e uma linha
-- leva 5 + 15 x 2 = 35 ciclos.
--
-- Escrita. Cada ciclo de escrita tem três fases: a preparação de um ciclo, com o
-- endereço e o dado já nos pinos; WE# baixo por n_wl ciclos, o teto do maior entre
-- t_wp, t_ah e t_ds; e WE# alto por n_wh ciclos, o bastante para t_wph e para o
-- ciclo completo t_wc. Apagar um setor são seis ciclos, e gravar um byte são
-- quatro. Terminada a sequência o controlador espera n_busy ciclos, que cobrem
-- t_busy (o chip só baixa RY# depois), e então espera RY# subir.
--
-- Gravação de página. Cada palavra do buffer de página (o_buf_idx e i_buf_data,
-- com leitura registrada) vira até quatro gravações de byte, na ordem dos
-- endereços. Um byte 0xFF não muda o chip, porque o chip só leva bits de 1 para 0,
-- e é pulado.
--
-- Comandos K4. Os códigos e as regras são os do flash_cmd_port: um apagar ou
-- gravar sem o latch armado é ignorado; com ele armado, um endereço fora da janela
-- ou num setor protegido é recusado; ao fim de uma operação aceita o latch cai e
-- sai o pulso de invalidação com a região alterada. Um comando só é aceito com o
-- controlador livre (o_cmd_busy baixo), e uma leitura pedida durante uma operação
-- espera o fim dela, porque o chip em operação não serve o arranjo.
--
-- Tempos. O período do clock, a margem de pino e os tempos do chip são generics
-- (padrões em chip_timing_pkg, marcados "inferido" na ficha da DE2-115), e o
-- número de ciclos de cada espera sai deles na elaboração. Todas as esperas são
-- contadas pela latency_counter, a máquina de latência única do repositório.
--
-- Reset. i_rst baixa RESET# do chip por t_rp e só aceita pedidos t_rh depois de
-- ele subir. Janela: o chip ocupa size_bytes bytes, uma potência de dois. Uma
-- leitura cujos bits 25 até o fim do tamanho não são todos zero está fora da janela
-- e devolve zero sem tocar no chip.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.config_pkg.all;
use work.utils_pkg.all;
use work.chip_timing_pkg.all;

entity nor_flash_ctrl is
    generic (
        -- Período do clock i_clk, em ns.
        clk_period_ns : positive                      := 20;
        -- Margem somada a cada tempo do chip para o atraso de pino e de placa, em ns.
        margin_ns     : natural                       := 0;
        -- Tamanho do chip em bytes, uma potência de dois de 8 KB a 8 MB.
        size_bytes    : positive                      := 8388608;
        -- Tamanho do setor de apagar e de proteger, em bytes, potência de dois.
        sector_bytes  : positive                      := 65536;
        -- Tamanho da página de gravar, em bytes, potência de dois de 8 bytes até sector_bytes.
        page_bytes    : positive                      := 256;
        -- Endereço do início do chip no mapa do SoC, somado ao deslocamento na região de invalidação.
        base_addr     : addr_t := std_logic_vector(FLASH_BASE(ADDR_BITS - 1 downto 0));
        -- Acesso aleatório (endereço e CE# até o dado), em ns.
        t_acc_ns      : natural                       := NOR_T_ACC_NS;
        -- Acesso dentro da página, em ns.
        t_pacc_ns     : natural                       := NOR_T_PACC_NS;
        -- Ciclo de escrita, em ns.
        t_wc_ns       : natural                       := NOR_T_WC_NS;
        -- Largura do pulso de WE#, em ns.
        t_wp_ns       : natural                       := NOR_T_WP_NS;
        -- Largura de WE# em nível alto, em ns.
        t_wph_ns      : natural                       := NOR_T_WPH_NS;
        -- Dado estável antes da subida de WE#, em ns.
        t_ds_ns       : natural                       := NOR_T_DS_NS;
        -- Endereço estável depois da descida de WE#, em ns.
        t_ah_ns       : natural                       := NOR_T_AH_NS;
        -- Da subida de WE# à descida de RY#, em ns.
        t_busy_ns     : natural                       := NOR_T_BUSY_NS;
        -- Largura do pulso de RESET#, em ns.
        t_rp_ns       : natural                       := NOR_T_RP_NS;
        -- Da subida de RESET# ao primeiro acesso, em ns.
        t_rh_ns       : natural                       := NOR_T_RH_NS
    );
    port (
        -- Clock do módulo.
        i_clk : in    std_logic;
        -- Reset síncrono, ativo em '1'.
        i_rst : in    std_logic;

        -- Leitura: endereço do pedido.
        i_addr    : in    addr_t;
        -- Leitura: pedido de leitura ('1' = lê).
        i_rden    : in    std_logic;
        -- Leitura: pedido de linha de quatro palavras ('1') ou de uma palavra ('0').
        i_line    : in    std_logic;
        -- Leitura: o pedido foi consumido neste ciclo, o controlador pode aceitar outro.
        i_advance : in    std_logic;
        -- Leitura: pedido concluído, o dado lido é válido ('1').
        o_ready   : out   std_logic;
        -- Leitura: o controlador está esperando o chip por um pedido ('1' em cada ciclo de espera).
        o_busy    : out   std_logic;
        -- Leitura: palavra pedida (a palavra 0 da linha).
        o_rdata   : out   word_t;
        -- Leitura: palavras 1 a 3 da linha, a palavra 1 nos bits mais baixos.
        o_rdata_x : out   std_logic_vector(3 * XLEN - 1 downto 0);

        -- Comandos K4: pulso de um ciclo que entrega um comando.
        i_cmd_valid   : in    std_logic;
        -- Comandos K4: código do comando (1 habilitar escrita, 2 apagar, 3 gravar, 4 proteger, 5 desproteger).
        i_cmd_op      : in    std_logic_vector(2 downto 0);
        -- Comandos K4: endereço de byte do comando.
        i_cmd_addr    : in    addr_t;
        -- Comandos K4: o controlador não aceita comando (leitura, operação ou reset em andamento).
        o_cmd_busy    : out   std_logic;
        -- Comandos K4: o latch de escrita está armado.
        o_wel         : out   std_logic;
        -- Comandos K4: o último apagar ou gravar com o latch armado foi recusado.
        o_refused     : out   std_logic;
        -- Comandos K4: índice da palavra do buffer de página lida pela gravação, registrado.
        o_buf_idx     : out   std_logic_vector(log2_exact(page_bytes) - 3 downto 0);
        -- Comandos K4: palavra do buffer de página, com leitura registrada.
        -- Largura física do dispositivo ou do protocolo (32 bits), não do núcleo.
        i_buf_data    : in    std_logic_vector(31 downto 0);
        -- Comandos K4: pulso de um ciclo no fim de um apagar ou gravar aceito.
        o_inval_valid : out   std_logic;
        -- Comandos K4: primeiro endereço de byte da região alterada, no mapa do SoC.
        o_inval_first : out   addr_t;
        -- Comandos K4: último endereço de byte da região alterada.
        o_inval_last  : out   addr_t;

        -- Chip: endereço de byte (FL_ADDR[22:0]).
        o_fl_addr  : out   std_logic_vector(22 downto 0);
        -- Chip: dado a escrever (FL_DQ[7:0]).
        o_fl_dq    : out   std_logic_vector(7 downto 0);
        -- Chip: o controlador dirige FL_DQ ('1'); o topo faz o tristate.
        o_fl_dq_oe : out   std_logic;
        -- Chip: dado lido (FL_DQ[7:0]).
        i_fl_dq    : in    std_logic_vector(7 downto 0);
        -- Chip: chip habilitado, ativo em '0'.
        o_fl_ce_n  : out   std_logic;
        -- Chip: saída habilitada, ativo em '0'.
        o_fl_oe_n  : out   std_logic;
        -- Chip: escrita habilitada, ativo em '0'.
        o_fl_we_n  : out   std_logic;
        -- Chip: reset, ativo em '0'.
        o_fl_rst_n : out   std_logic;
        -- Chip: proteção de hardware dos setores externos, ativo em '0'; o controlador a mantém em '1'.
        o_fl_wp_n  : out   std_logic;
        -- Chip: pronto ('1') ou ocupado ('0'), assíncrono ao clock.
        i_fl_ry    : in    std_logic
    );
end entity nor_flash_ctrl;

architecture rtl of nor_flash_ctrl is

    -- Código do comando habilitar escrita.
    constant CMD_WREN    : std_logic_vector(2 downto 0) := "001";
    -- Código do comando apagar setor.
    constant CMD_ERASE   : std_logic_vector(2 downto 0) := "010";
    -- Código do comando gravar página.
    constant CMD_PROGRAM : std_logic_vector(2 downto 0) := "011";
    -- Código do comando proteger setor.
    constant CMD_PROTECT : std_logic_vector(2 downto 0) := "100";
    -- Código do comando desproteger setor.
    constant CMD_UNPROT  : std_logic_vector(2 downto 0) := "101";

    -- Bits de endereço da janela do chip (falha se size_bytes não for uma potência de dois).
    constant WINDOW_BITS : natural := log2_exact(size_bytes);
    -- Bits de endereço dentro de um setor.
    constant SECTOR_BITS : natural := log2_exact(sector_bytes);
    -- Bits de endereço dentro de uma página.
    constant PAGE_BITS   : natural := log2_exact(page_bytes);
    -- Quantidade de setores do chip.
    constant SECTORS     : natural := size_bytes / sector_bytes;
    -- Palavras de uma página.
    constant PAGE_WORDS  : natural := page_bytes / 4;

    -- Ciclos até o dado do primeiro byte de um pedido.
    constant N_FIRST : positive := cycles_of(t_acc_ns, clk_period_ns, margin_ns);
    -- Ciclos até o dado de um byte seguinte da mesma página.
    constant N_NEXT  : positive := cycles_of(t_pacc_ns, clk_period_ns, margin_ns);
    -- Ciclos de WE# em nível baixo: o maior entre t_wp, t_ah e t_ds.
    constant N_WL    : positive :=
        cycles_of(max_natural(t_wp_ns, max_natural(t_ah_ns, t_ds_ns)), clk_period_ns, margin_ns);
    -- Ciclos de WE# em nível alto: cobrem t_wph e completam t_wc.
    constant N_WH    : positive := max_natural(cycles_of(t_wph_ns, clk_period_ns, margin_ns),
            max_natural(cycles_of(t_wc_ns, clk_period_ns, margin_ns), N_WL + 2) - N_WL - 1);
    -- Ciclos de espera antes de olhar RY: cobrem t_busy e mais um ciclo para a sincronização.
    constant N_BUSY  : positive := cycles_of(t_busy_ns, clk_period_ns, margin_ns) + 3;
    -- Ciclos de RESET# em nível baixo.
    constant N_RP    : positive := cycles_of(t_rp_ns, clk_period_ns, margin_ns);
    -- Ciclos de espera depois da subida de RESET#.
    constant N_RH    : positive := cycles_of(t_rh_ns, clk_period_ns, margin_ns);
    -- Maior valor de contagem.
    constant CNT_MAX : natural  := max_natural(N_RP, max_natural(N_RH, max_natural(N_BUSY, max_natural(N_FIRST,
                        max_natural(N_NEXT, max_natural(N_WL, N_WH))))));

    -- Estados: início do reset do chip, RESET# baixo, espera depois de RESET#, livre, leitura, leitura concluída, busca
    -- da palavra do buffer, escolha do byte a gravar, passagem ao byte ou à palavra seguinte, preparação de um ciclo de
    -- escrita, WE# baixo, WE# alto, espera de t_busy, espera de RY e fim da operação.
    type state_t is (
        S_RST_ARM, S_RST_LOW, S_RST_HIGH, S_IDLE, S_RD, S_RD_DONE, S_FETCH, S_PBYTE, S_NEXT, S_WSETUP, S_WLOW,
        S_WHIGH, S_BUSY, S_POLL, S_FIN
    );

    -- Estado atual.
    signal st        : state_t                                := S_RST_ARM;
    -- Pedido de uma contagem de latência ('1' carrega).
    signal lat_load  : std_logic;
    -- Ciclos da contagem pedida.
    signal lat_count : natural range 0 to CNT_MAX;
    -- A contagem de latência termina nesta borda.
    signal lat_last  : std_logic;
    -- Começa uma leitura de chip nesta borda: o controlador está livre, sem comando, e o pedido está na janela.
    signal rd_start  : std_logic;
    -- O pedido de leitura em i_addr está fora da janela do chip.
    signal rd_outw   : std_logic;
    -- Último passo da sequência de comando do chip está em WE# alto (a seguir vem a espera de t_busy).
    signal seq_end   : std_logic;
    -- Byte da leitura em andamento (0 a 15).
    signal byte_n    : natural range 0 to 15                  := 0;
    -- Último byte do pedido (3 para uma palavra, 15 para uma linha).
    signal last_b    : natural range 0 to 15                  := 0;
    -- A leitura em andamento está fora da janela do chip.
    signal out_win   : std_logic                              := '0';
    -- Bytes lidos: a palavra 0 nos bits 31 a 0 e as palavras 1 a 3 acima.
    signal line_q    : std_logic_vector(4 * XLEN - 1 downto 0)         := (others => '0');
    -- Endereço de byte entregue ao chip (registrado).
    signal addr_q    : unsigned(WINDOW_BITS - 1 downto 0)     := (others => '0');
    -- Dado entregue ao chip (registrado).
    signal dq_q      : std_logic_vector(7 downto 0)           := (others => '0');
    -- O controlador dirige o barramento de dados (registrado).
    signal dq_oe_q   : std_logic                              := '0';
    -- CE# registrado.
    signal ce_n_q    : std_logic                              := '1';
    -- OE# registrado.
    signal oe_n_q    : std_logic                              := '1';
    -- WE# registrado.
    signal we_n_q    : std_logic                              := '1';
    -- RESET# registrado.
    signal rst_n_q   : std_logic                              := '0';
    -- RY sincronizado com o clock.
    signal ry_s      : std_logic_vector(0 downto 0);
    -- Latch de escrita.
    signal wel       : std_logic                              := '0';
    -- Última operação recusada.
    signal refused   : std_logic                              := '0';
    -- Proteção de cada setor.
    signal prot      : std_logic_vector(SECTORS - 1 downto 0) := (others => '0');
    -- A operação em andamento é um apagar ('1') ou uma gravação ('0').
    signal is_erase  : std_logic                              := '0';
    -- Passo da sequência de comando do chip em andamento.
    signal step      : natural range 0 to 5                   := 0;
    -- Deslocamento do início da região (setor ou página) em andamento dentro do chip.
    signal base_off  : unsigned(WINDOW_BITS - 1 downto 0)     := (others => '0');
    -- Índice da palavra em andamento dentro da página.
    signal word_n    : natural range 0 to PAGE_WORDS - 1      := 0;
    -- Byte em andamento dentro da palavra.
    signal byte_k    : natural range 0 to 3                   := 0;
    -- Fase da busca da palavra do buffer.
    signal fetch_n   : natural range 0 to 1                   := 0;
    -- Palavra do buffer em gravação.
    -- Largura física do dispositivo ou do protocolo (32 bits), não do núcleo.
    signal word_q    : std_logic_vector(31 downto 0)          := (others => '0');
    -- Índice da palavra do buffer de página (registrado).
    signal buf_idx   : unsigned(PAGE_BITS - 3 downto 0)       := (others => '0');
    -- Pulso de invalidação registrado.
    signal inval_q   : std_logic                              := '0';
    -- Primeiro endereço da região invalidada (registrado).
    signal first_q   : unsigned(ADDR_BITS - 1 downto 0)                  := (others => '0');
    -- Último endereço da região invalidada (registrado).
    signal last_q    : unsigned(ADDR_BITS - 1 downto 0)                  := (others => '0');

    -- Devolve o endereço e o dado do passo da sequência de comando do chip. Os endereços de desbloqueio são os de
    -- modo byte (0xAAA e 0x555).

    procedure seq_cycle (
        step_i   : in  natural;
        erase    : in  std_logic;
        sector   : in  unsigned;
        byte_adr : in  unsigned;
        byte_dat : in  std_logic_vector(7 downto 0);
        addr_o   : out unsigned;
        data_o   : out std_logic_vector(7 downto 0)
    ) is

        -- Endereço de desbloqueio AAA, com a largura da janela.
        constant UNLOCK_A : unsigned(addr_o'range) := to_unsigned(16#AAA#, addr_o'length);
        -- Endereço de desbloqueio 555, com a largura da janela.
        constant UNLOCK_B : unsigned(addr_o'range) := to_unsigned(16#555#, addr_o'length);

    begin

        addr_o := UNLOCK_A;
        data_o := x"AA";

        case step_i is

            when 1 =>

                addr_o := UNLOCK_B;
                data_o := x"55";

            when 2 =>

                if erase = '1' then
                    data_o := x"80";
                else
                    data_o := x"A0";
                end if;

            when 3 =>

                if erase = '1' then
                    data_o := x"AA";
                else
                    addr_o := byte_adr;
                    data_o := byte_dat;
                end if;

            when 4 =>

                addr_o := UNLOCK_B;
                data_o := x"55";

            when 5 =>

                addr_o := sector;
                data_o := x"30";

            when others =>

                null;

        end case;

    end procedure seq_cycle;

begin

    -- A palavra do núcleo tem XLEN bits, mas a linha de 4 palavras, o mapa de bits do endereço e a largura física do
    -- dispositivo deste bloco supõem a palavra de 32 bits e só elaboram com XLEN = 32.
    assert XLEN = 32
        report "este bloco só elabora com XLEN = 32"
        severity failure;

    assert size_bytes >= 8192 and size_bytes <= 2 ** 23
        report "size_bytes must be between 8 KB and 8 MB"
        severity failure;
    assert size_bytes > sector_bytes
        report "size_bytes must be greater than sector_bytes"
        severity failure;
    assert page_bytes >= 8 and page_bytes <= sector_bytes
        report "page_bytes must be between 8 bytes and sector_bytes"
        severity failure;

    -- Sincroniza o pino de pronto, que muda sem relação de fase com o clock.
    u_ry : entity work.synchronizer
        generic map (
            stages => 2, data_width => 1
        )
        port map (
            i_clk  => i_clk,
            i_rst  => '0',
            i_d(0) => i_fl_ry,
            o_d    => ry_s
        );

    o_ready       <= '1' when st = S_RD_DONE else '0';
    o_busy        <= '1' when st = S_RD else '0';
    o_rdata       <= line_q(XLEN - 1 downto 0);
    o_rdata_x     <= line_q(4 * XLEN - 1 downto XLEN);
    o_cmd_busy    <= '0' when st = S_IDLE else '1';
    o_wel         <= wel;
    o_refused     <= refused;
    o_buf_idx     <= std_logic_vector(buf_idx);
    o_inval_valid <= inval_q;
    o_inval_first <= std_logic_vector(first_q);
    o_inval_last  <= std_logic_vector(last_q);
    o_fl_addr     <= std_logic_vector(resize(addr_q, 23));
    o_fl_dq       <= dq_q;
    o_fl_dq_oe    <= dq_oe_q;
    o_fl_ce_n     <= ce_n_q;
    o_fl_oe_n     <= oe_n_q;
    o_fl_we_n     <= we_n_q;
    o_fl_rst_n    <= rst_n_q;
    o_fl_wp_n     <= '1';

    -- Um pedido de leitura está fora da janela quando os bits 25 até o fim do tamanho não são todos zero.
    rd_outw  <= '1' when unsigned(i_addr(25 downto WINDOW_BITS)) /= 0 else '0';
    -- Uma leitura de chip começa com o controlador livre, sem comando no ciclo e com o pedido na janela.
    rd_start <= '1' when st = S_IDLE and i_cmd_valid = '0' and i_rden = '1' and rd_outw = '0' else '0';
    -- O último passo da sequência de comando termina nesta borda quando WE# alto acaba no passo final.
    seq_end  <= '1' when (is_erase = '1' and step = 5) or (is_erase = '0' and step = 3) else '0';

    -- A máquina de contagem de latência única conta todas as esperas; cada estado que espera carrega a sua.
    lat_load  <= '1' when st = S_RST_ARM
                          or rd_start = '1'
                          or st = S_WSETUP
                          or (st = S_RST_LOW and lat_last = '1')
                          or (st = S_RD and lat_last = '1' and byte_n /= last_b)
                          or (st = S_WLOW and lat_last = '1')
                          or (st = S_WHIGH and lat_last = '1' and seq_end = '1') else
                 '0';
    lat_count <= N_RP when st = S_RST_ARM else
                 N_RH when st = S_RST_LOW else
                 N_FIRST when st = S_IDLE else
                 N_NEXT when st = S_RD else
                 N_WL when st = S_WSETUP else
                 N_WH when st = S_WLOW else
                 N_BUSY;

    u_latency : entity work.latency_counter
        generic map (
            max_count => CNT_MAX
        )
        port map (
            i_clk   => i_clk,
            i_rst   => i_rst,
            i_load  => lat_load,
            i_count => lat_count,
            o_last  => lat_last,
            o_wait  => open
        );

    p_ctrl_fsm : process (i_clk) is

        -- Deslocamento do endereço do comando dentro do chip.
        variable off      : unsigned(WINDOW_BITS - 1 downto 0);
        -- Setor do endereço do comando.
        variable sec      : natural range 0 to SECTORS - 1;
        -- O endereço do comando está fora da janela do chip.
        variable cmd_out  : boolean;
        -- Início do setor do endereço do comando, dentro do chip.
        variable sec_off  : unsigned(WINDOW_BITS - 1 downto 0);
        -- Início da página do endereço do comando, dentro do chip.
        variable pg_off   : unsigned(WINDOW_BITS - 1 downto 0);
        -- Endereço de byte do pedido de leitura, alinhado a palavra ou a linha.
        variable rd_addr  : unsigned(ADDR_BITS - 1 downto 0);
        -- Endereço do passo de escrita.
        variable w_addr   : unsigned(WINDOW_BITS - 1 downto 0);
        -- Dado do passo de escrita.
        variable w_data   : std_logic_vector(7 downto 0);
        -- Endereço de byte em gravação, dentro do chip.
        variable byte_adr : unsigned(WINDOW_BITS - 1 downto 0);
        -- Dado do byte em gravação.
        variable byte_dat : std_logic_vector(7 downto 0);
        -- Primeiro endereço da região invalidada, no mapa do SoC.
        variable first_a  : unsigned(ADDR_BITS - 1 downto 0);
        -- Bytes da região invalidada.
        variable region   : natural;

    begin

        if rising_edge(i_clk) then
            inval_q <= '0';
            if i_rst = '1' then
                st      <= S_RST_ARM;
                rst_n_q <= '0';
                ce_n_q  <= '1';
                oe_n_q  <= '1';
                we_n_q  <= '1';
                dq_oe_q <= '0';
                wel     <= '0';
                refused <= '0';
                prot    <= (others => '0');
            else

                case st is

                    when S_RST_ARM =>

                        st <= S_RST_LOW;

                    when S_RST_LOW =>

                        if lat_last = '1' then
                            rst_n_q <= '1';
                            st      <= S_RST_HIGH;
                        end if;

                    when S_RST_HIGH =>

                        if lat_last = '1' then
                            st <= S_IDLE;
                        end if;

                    when S_IDLE =>

                        off     := unsigned(i_cmd_addr(WINDOW_BITS - 1 downto 0));
                        sec     := to_integer(off(WINDOW_BITS - 1 downto SECTOR_BITS));
                        cmd_out := unsigned(i_cmd_addr(25 downto WINDOW_BITS)) /= 0;
                        sec_off := off(WINDOW_BITS - 1 downto SECTOR_BITS) & (SECTOR_BITS - 1 downto 0 => '0');
                        pg_off  := off(WINDOW_BITS - 1 downto PAGE_BITS) & (PAGE_BITS - 1 downto 0 => '0');
                        if i_cmd_valid = '1' then
                            if i_cmd_op = CMD_WREN then
                                wel     <= '1';
                                refused <= '0';
                            elsif i_cmd_op = CMD_PROTECT and not cmd_out then
                                prot(sec) <= '1';
                            elsif i_cmd_op = CMD_UNPROT and not cmd_out then
                                prot(sec) <= '0';
                            elsif (i_cmd_op = CMD_ERASE or i_cmd_op = CMD_PROGRAM) and wel = '1' then
                                if cmd_out or prot(sec) = '1' then
                                    refused <= '1';
                                    wel     <= '0';
                                else
                                    step <= 0;
                                    if i_cmd_op = CMD_ERASE then
                                        is_erase <= '1';
                                        base_off <= sec_off;
                                        -- Primeiro ciclo da sequência de apagar.
                                        seq_cycle(0, '1', sec_off, off, x"FF", w_addr, w_data);
                                        addr_q   <= w_addr;
                                        dq_q     <= w_data;
                                        dq_oe_q  <= '1';
                                        ce_n_q   <= '0';
                                        oe_n_q   <= '1';
                                        we_n_q   <= '1';
                                        st       <= S_WSETUP;
                                    else
                                        is_erase <= '0';
                                        base_off <= pg_off;
                                        buf_idx  <= (others => '0');
                                        word_n   <= 0;
                                        byte_k   <= 0;
                                        fetch_n  <= 0;
                                        st       <= S_FETCH;
                                    end if;
                                end if;
                            end if;
                        elsif i_rden = '1' then
                            if i_line = '1' then
                                rd_addr := unsigned(i_addr(31 downto 4)) & "0000";
                                last_b  <= 15;
                            else
                                rd_addr := unsigned(i_addr(31 downto 2)) & "00";
                                last_b  <= 3;
                            end if;
                            byte_n <= 0;
                            if rd_outw = '1' then
                                if i_line = '1' then
                                    line_q <= (others => '0');
                                else
                                    line_q(XLEN - 1 downto 0) <= (others => '0');
                                end if;
                                st <= S_RD_DONE;
                            else
                                addr_q  <= rd_addr(WINDOW_BITS - 1 downto 0);
                                ce_n_q  <= '0';
                                oe_n_q  <= '0';
                                dq_oe_q <= '0';
                                st      <= S_RD;
                            end if;
                        end if;

                    when S_RD =>

                        if lat_last = '1' then

                            for i in 0 to 15 loop

                                if byte_n = i then
                                    line_q(8 * i + 7 downto 8 * i) <= i_fl_dq;
                                end if;

                            end loop;

                            if byte_n = last_b then
                                ce_n_q <= '1';
                                oe_n_q <= '1';
                                st     <= S_RD_DONE;
                            else
                                byte_n <= byte_n + 1;
                                addr_q <= addr_q + 1;
                            end if;
                        end if;

                    when S_RD_DONE =>

                        if i_advance = '1' then
                            st <= S_IDLE;
                        end if;

                    when S_FETCH =>

                        if fetch_n = 0 then
                            fetch_n <= 1;
                        else
                            word_q  <= i_buf_data;
                            fetch_n <= 0;
                            byte_k  <= 0;
                            st      <= S_PBYTE;
                        end if;

                    when S_PBYTE =>

                        byte_adr := base_off + to_unsigned(4 * word_n + byte_k, WINDOW_BITS);
                        byte_dat := word_q(8 * byte_k + 7 downto 8 * byte_k);
                        if byte_dat = x"FF" then
                            -- Um byte em 0xFF não muda o chip: passa ao seguinte.
                            st <= S_NEXT;
                        else
                            step    <= 0;
                            seq_cycle(0, '0', base_off, byte_adr, byte_dat, w_addr, w_data);
                            addr_q  <= w_addr;
                            dq_q    <= w_data;
                            dq_oe_q <= '1';
                            ce_n_q  <= '0';
                            oe_n_q  <= '1';
                            we_n_q  <= '1';
                            st      <= S_WSETUP;
                        end if;

                    when S_WSETUP =>

                        we_n_q <= '0';
                        st     <= S_WLOW;

                    when S_WLOW =>

                        if lat_last = '1' then
                            we_n_q <= '1';
                            st     <= S_WHIGH;
                        end if;

                    when S_WHIGH =>

                        if lat_last = '1' and seq_end = '1' then
                            ce_n_q  <= '1';
                            dq_oe_q <= '0';
                            st      <= S_BUSY;
                        elsif lat_last = '1' then
                            byte_adr := base_off + to_unsigned(4 * word_n + byte_k, WINDOW_BITS);
                            byte_dat := word_q(8 * byte_k + 7 downto 8 * byte_k);
                            seq_cycle(step + 1, is_erase, base_off, byte_adr, byte_dat, w_addr, w_data);
                            step     <= step + 1;
                            addr_q   <= w_addr;
                            dq_q     <= w_data;
                            st       <= S_WSETUP;
                        end if;

                    when S_BUSY =>

                        if lat_last = '1' then
                            st <= S_POLL;
                        end if;

                    when S_POLL =>

                        if ry_s(0) = '1' then
                            if is_erase = '1' then
                                st <= S_FIN;
                            else
                                st <= S_NEXT;
                            end if;
                        end if;

                    when S_NEXT =>

                        if byte_k /= 3 then
                            byte_k <= byte_k + 1;
                            st     <= S_PBYTE;
                        elsif word_n = PAGE_WORDS - 1 then
                            st <= S_FIN;
                        else
                            word_n  <= word_n + 1;
                            buf_idx <= buf_idx + 1;
                            byte_k  <= 0;
                            st      <= S_FETCH;
                        end if;

                    when S_FIN =>

                        first_a := unsigned(base_addr) + resize(base_off, ADDR_BITS);
                        if is_erase = '1' then
                            region := sector_bytes;
                        else
                            region := page_bytes;
                        end if;
                        first_q <= first_a;
                        last_q  <= first_a + to_unsigned(region - 1, ADDR_BITS);
                        inval_q <= '1';
                        wel     <= '0';
                        st      <= S_IDLE;

                end case;

            end if;
        end if;

    end process p_ctrl_fsm;

end architecture rtl;
