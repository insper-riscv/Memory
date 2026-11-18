-- =============================================================================
-- Cache de dados do core
--
-- 4 KB, mapeamento direto, linhas de 16 bytes (quatro palavras), write-back com
-- write-allocate. Fica no caminho de memória do ext_interconnect (os endereços da
-- SDRAM); os periféricos nunca chegam a ela.
--
-- Lado do core, o mesmo contrato da sdram_cpu_bridge: o acesso fica em
-- addr/wdata/byteena/rden/wren enquanto o estágio de memória está parado; ready
-- sobe quando o acesso termina e permanece em nível alto até mem_advance; rdata
-- só muda nessa borda. Um acerto leva dois clocks (as RAMs têm leitura
-- registrada, como as RAMs de bloco da FPGA); uma falha leva os quatro acessos
-- de palavra da linha, mais quatro antes se a linha a trocar estiver suja.
--
-- Lado da memória: uma palavra por vez em d_*, com o mesmo contrato (o pedido
-- fica até d_ready, e d_ready é consumido pela própria cache, porque o resto do
-- pipeline está parado). O AXI4-Lite não carrega rajada, então a linha se move
-- como quatro acessos de uma palavra; a porta é a que o axi_master_bridge
-- converte em AXI4-Lite.
--
-- flush: um pedido (um pulso basta) para escrever de volta toda linha suja (as
-- linhas continuam válidas e ficam limpas); com invalidate no mesmo clock, depois
-- derruba todas as linhas, como faz um programa antes de o hospedeiro carregar o
-- próximo por trás da cache. Começa assim que a cache fica livre, antes de
-- qualquer acesso que esteja esperando; busy fica alto do clock seguinte ao
-- pedido até flush_done pulsar. Um acesso que chega nesse meio tempo espera o
-- flush terminar. Nada mais escreve na SDRAM por trás da cache em operação
-- normal, então um programa que carrega código ou dados por outro mestre (a
-- porta de debug JTAG) o faz com a cache inválida, como fica depois do reset.
--
-- write_through: todo store também vai à memória antes de completar, e um store
-- que falha não traz a linha (write-around), então nenhuma linha fica suja e a
-- memória sempre guarda o que o core escreveu. Os loads continuam acertando na
-- cache. É o que uma porta de debug que lê a SDRAM por trás da cache precisa: o
-- hospedeiro vê cada store assim que ele completa, sem flush. As linhas da cache
-- ainda podem estar mais velhas que a memória quando o hospedeiro a escreve; um
-- invalidate (veja flush) antes de o hospedeiro carregar algo novo as derruba.
--
-- scratch_kib: uma memória interna de RAMs de bloco, dentro da janela da SDRAM, que a cache atende em dois
-- clocks (o tempo de um acerto) sem nunca acessar a memória: os endereços de
-- [scratch_base_kib, scratch_base_kib + scratch_kib) KiB.
-- Ela guarda só o que o programa escreve depois do reset (pilha e variáveis zeradas na partida); o que o hospedeiro
-- carrega na SDRAM nessa janela não aparece nela. Zero a desliga.
--
-- write_buffer: com write_through, uma fila de write_buffer palavras entre o core e a memória. Um store que
-- chega com a fila livre entra nela e completa sem esperar a memória; um bloco de escrita da própria cache esvazia a
-- fila na ordem, uma palavra por vez. Um pedido de leitura à memória (preenchimento de linha ou load sem cache) só sai
-- com a fila vazia e o bloco de escrita parado, então nenhum load passa à frente de um store e a memória sempre vê os
-- stores na ordem do programa. Com a fila cheia o store espera uma vaga. O flush só termina, e o o_busy só cai, com a
-- fila vazia, então um fence ou um hospedeiro que espere o fim do flush vê todos os stores na memória. Zero desliga a
-- fila e deixa o comportamento da escrita direta sem fila.
--
-- Divisão do endereço (janela de 2**window_bits bytes por região, 64 MiB por padrão): região (1 = FLASH, pelos genéricos
-- flash_base_kib e flash_end_kib), bits window_bits-1:12
-- tag, 11:4 linha, 3:2 palavra. Os demais bits a partir de window_bits não são guardados; o
-- lado da memória acrescenta a base da região neles (base_flash ou base_sdram).
--
-- i_inval_region: um pulso derruba as linhas limpas da região de i_inval_first a i_inval_last (endereços de byte, o
-- último
-- incluído), como o controlador de FLASH pede depois de apagar ou gravar. A cache derruba por índice (guarda a tag, não
-- o
-- endereço completo): toda linha limpa cujo índice cai em algum endereço da região, mesmo a de outra região com o mesmo
-- índice. Uma linha suja nunca é derrubada, porque só a SDRAM tem linhas sujas e a FLASH nunca é escrita pela cache. Um
-- preenchimento em andamento cuja linha cai na região não valida a linha, e o acesso que o pediu a traz de novo. O
-- pedido
-- é registrado e aplicado no ciclo seguinte, então nenhuma linha da região acerta a partir do segundo ciclo depois do
-- pulso.
-- Um pedido com i_inval_last menor que i_inval_first não tem efeito.
--
-- FLASH: os loads trazem e guardam a linha como na SDRAM. Um store à FLASH nunca
-- altera a cache, nem num acerto nem numa falha, e só é repassado à memória, onde o
-- roteador de região o conclui sem efeito: a FLASH ignora escritas, e uma linha
-- atualizada mostraria um dado que o chip não tem.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.config_pkg.all;
use work.cache_pkg.all;
use work.utils_pkg.all;

entity dcache is
    generic (
        -- Tamanho da cache em bits, uma potência de dois de pelo menos 256 (duas linhas de 128 bits): 32768 é 4 KB e
        -- 4096 é 4 kbit.
        size_bits     : positive                     := 32768;
        -- Largura do endereço que a janela da cache cobre, de 2**window_bits bytes (26 é 64 MiB, 27 é 128 MiB): a tag
        -- guarda os bits abaixo dela e a base da região, do lado da memória, completa os de cima.
        window_bits   : natural range 26 to 29       := 26;
        -- Bits 31:26 dos endereços da SDRAM (0x40000000), acrescentados do lado da memória; só os bits de 31 até
        -- window_bits entram, os de baixo são da tag.
        base_sdram    : std_logic_vector(5 downto 0) := "010000";
        -- Bits 31:26 dos endereços da FLASH (0x20000000), acrescentados do lado da memória.
        base_flash    : std_logic_vector(5 downto 0) := "001000";
        -- Base, em KiB, da região da FLASH; o que cai nela é tratado como FLASH (0x20000000 por padrão).
        -- Origem: o espaço de endereços da região da FLASH que as caches do Memory enxergam, não o mapa
        -- do Core, por isso o padrão difere dos defaults do Core.
        flash_base_kib  : natural                      := 524288;
        -- Fim exclusivo, em KiB, da região da FLASH (0x40000000 por padrão). Origem: o espaço de
        -- endereços da região da FLASH que as caches do Memory enxergam, não o mapa do Core, por isso o
        -- padrão difere dos defaults do Core.
        flash_end_kib   : natural                      := 1048576;
        -- Verdadeiro: todo store vai também à memória e a falha de store não traz a linha (nenhuma linha fica suja).
        write_through : boolean                      := false;
        -- Palavras da fila de escrita entre o core e a memória, de 0 a 16 (0 não tem fila). Exige write_through.
        write_buffer  : natural range 0 to 16        := 0;
        -- Tamanho em KiB da memória interna dentro da janela da SDRAM, uma potência de dois (0 não tem): um acesso
        -- a ela é atendido por RAMs de bloco da própria cache em dois clocks, como um acerto, e nunca vai à memória.
        scratch_kib   : natural range 0 to 256       := 0;
        -- Base em KiB da memória interna, um múltiplo do tamanho dela.
        scratch_base_kib : natural                   := 0
    );
    port (
        -- Clock do módulo.
        i_clk : in    std_logic;
        -- Reset, ativo em '1'.
        i_rst : in    std_logic;

        -- Endereço do acesso.
        i_addr        : in    addr_t;
        -- Dado de escrita.
        i_wdata       : in    word_t;
        -- Habilita de bytes da escrita, um bit por byte.
        i_byteena     : in    std_logic_vector(XLEN / 8 - 1 downto 0);
        -- Pedido de leitura ('1' = lê).
        i_rden        : in    std_logic;
        -- Pedido de escrita ('1' = escreve).
        i_wren        : in    std_logic;
        -- O pipeline avançou neste ciclo, o acesso em andamento pode ser concluído.
        i_mem_advance : in    std_logic;
        -- Acesso concluído, o dado lido é válido ('1').
        o_ready       : out   std_logic;
        -- Dado lido.
        o_rdata       : out   word_t;

        -- Pede a escrita de todas as linhas sujas na memória ('1').
        i_flush        : in    std_logic;
        -- Invalida todas as linhas da cache ('1').
        i_invalidate   : in    std_logic                     := '0';
        -- Pulso de um ciclo no início de cada preenchimento de linha (uma falha de leitura da cache).
        o_miss         : out   std_logic;
        -- Pulso que derruba as linhas limpas da região de i_inval_first a i_inval_last.
        i_inval_region : in    std_logic                     := '0';
        -- Primeiro endereço de byte da região a derrubar.
        i_inval_first  : in    addr_t := (others => '0');
        -- Último endereço de byte da região a derrubar (incluído).
        i_inval_last   : in    addr_t := (others => '0');
        -- O acesso em andamento não passa pela cache ('1'): um load vai à memória como palavra, sem consultar nem
        -- trazer linha, e um store só é repassado, sem atualizar a cache. Vale para as palavras que o hospedeiro
        -- escreve por trás da cache (por exemplo o fromhost), que a cache não poderia manter atualizadas.
        i_bypass       : in    std_logic                     := '0';
        -- A escrita das linhas sujas terminou ('1').
        o_flush_done   : out   std_logic;
        -- O módulo está ocupado ('1').
        o_busy         : out   std_logic;

        -- Lado da memória: endereço do acesso.
        o_d_addr    : out   addr_t;
        -- Lado da memória: dado de escrita.
        o_d_wdata   : out   word_t;
        -- Lado da memória: habilita de bytes da escrita.
        o_d_byteena : out   std_logic_vector(XLEN / 8 - 1 downto 0);
        -- Lado da memória: pedido de leitura ('1').
        o_d_rden    : out   std_logic;
        -- Lado da memória: pedido de escrita ('1').
        o_d_wren    : out   std_logic;
        -- Lado da memória: o pipeline avançou, o acesso pode ser concluído.
        o_d_advance : out   std_logic;
        -- Lado da memória: acesso concluído, dado lido válido ('1').
        i_d_ready   : in    std_logic;
        -- Lado da memória: dado lido.
        i_d_rdata   : in    word_t;
        -- Lado da memória: acesso de linha de quatro palavras ('1').
        o_d_line    : out   std_logic;
        -- Lado da memória: palavras 1 a 3 do dado de escrita da linha.
        o_d_wdata_x : out   std_logic_vector(3 * XLEN - 1 downto 0);
        -- Lado da memória: palavras 1 a 3 do dado lido da linha.
        i_d_rdata_x : in    std_logic_vector(3 * XLEN - 1 downto 0) := (others => '0')
    );
end entity dcache;

architecture rtl of dcache is

    -- Estados da cache: acesso, escrita de volta, preenchimento, flush e escrita direta.
    type state_t is (
        S_IDLE, S_LOOK, S_DONE,
        S_WB_RD, S_WB_CAP, S_WB_REQ, S_WB_WAIT,
        S_FILL_REQ, S_FILL_WAIT, S_FILL_GET,
        S_FL_TAG, S_FL_CHK, S_FL_NEXT,
        S_WT_REQ, S_WT_WAIT,
        S_BY_REQ, S_BY_WAIT, S_BY_GET
    );

    -- Estado atual da cache.
    signal st : state_t := S_IDLE;

    -- Estados do bloco que esvazia a fila de escrita: parado, esperando a memória aceitar a palavra.
    type drain_t is (DR_IDLE, DR_WAIT);

    -- Estado do bloco que esvazia a fila de escrita.
    signal dr : drain_t := DR_IDLE;

    -- Palavras da memória interna (duas só quando não há, sem uso).
    constant SCR_WORDS : positive := pick(scratch_kib > 0, scratch_kib * 256, 2);
    -- Bits do endereço de palavra da memória interna.
    constant SCR_BITS  : natural  := log2_exact(SCR_WORDS);

    -- Uma memória interna de uma faixa de byte.
    type scr_lane_t is array(0 to SCR_WORDS - 1) of std_logic_vector(7 downto 0);

    -- Posições da fila de escrita (uma só quando não há fila, sem uso).
    constant WB_DEPTH : positive := pick(write_buffer > 0, write_buffer, 1);

    -- Uma fila de palavras de endereço.
    type wb_addr_t is array(0 to WB_DEPTH - 1) of addr_t;
    -- Uma fila de palavras de dado.
    type wb_word_t is array(0 to WB_DEPTH - 1) of word_t;
    -- Uma fila de habilita de bytes.
    type wb_be_t is array(0 to WB_DEPTH - 1) of std_logic_vector(XLEN / 8 - 1 downto 0);

    -- Endereços de memória dos stores na fila.
    signal wb_a   : wb_addr_t := (others => (others => '0'));
    -- Dados dos stores na fila.
    signal wb_d   : wb_word_t := (others => (others => '0'));
    -- Habilita de bytes dos stores na fila.
    signal wb_b   : wb_be_t   := (others => (others => '0'));
    -- Posição do store mais antigo da fila.
    signal wb_rd  : natural range 0 to WB_DEPTH - 1 := 0;
    -- Posição livre onde entra o próximo store.
    signal wb_wr  : natural range 0 to WB_DEPTH - 1 := 0;
    -- Stores na fila.
    signal wb_cnt : natural range 0 to WB_DEPTH     := 0;
    -- O acesso em curso cai na memória interna.
    signal is_scr   : std_logic;
    -- Palavra lida da memória interna (leitura registrada).
    signal scr_rd   : word_t;
    -- Escrita registrada na memória interna: vale no ciclo seguinte ao S_LOOK.
    signal scr_wq   : std_logic                               := '0';
    -- Endereço de palavra da escrita registrada na memória interna.
    signal scr_wa_q : std_logic_vector(SCR_BITS - 1 downto 0) := (others => '0');
    -- Endereço de memória da palavra do store em curso.
    signal wt_addr : addr_t;
    -- A fila está vazia e o bloco de escrita parado: um pedido de leitura à memória pode sair.
    signal wb_idle : std_logic;

    -- Bits do índice da linha.
    constant INDEX_BITS : natural := index_bits_of(size_bits);
    -- Linhas da cache.
    constant LINES      : natural := 2 ** INDEX_BITS;
    -- Bits da tag: a região (FLASH ou não) e os bits window_bits-1 até INDEX_BITS + 4.
    constant TAG_BITS   : natural := window_bits - 3 - INDEX_BITS;
    -- Primeiro bit da tag no endereço, logo acima do índice e do deslocamento dentro da linha.
    constant TAG_LOW    : natural := INDEX_BITS + 4;

    -- Memória de dados: quatro palavras por linha, um byte por faixa.
    type lane_t is array(0 to 4 * LINES - 1) of std_logic_vector(7 downto 0);

    -- Memória de tags: uma tag por linha.
    type tag_t is array(0 to LINES - 1) of std_logic_vector(TAG_BITS - 1 downto 0);

    -- Palavras das 256 linhas.
    -- Tag de cada linha.
    signal tag_ram : tag_t                                := (others => (others => '0'));
    -- Bit de validade de cada linha.
    signal valid   : std_logic_vector(LINES - 1 downto 0) := (others => '0');
    -- Bit de linha suja: a linha difere da memória.
    signal dirty   : std_logic_vector(LINES - 1 downto 0) := (others => '0');

    -- Endereço de leitura da memória de dados.
    signal ram_ra : std_logic_vector(INDEX_BITS + 1 downto 0);
    -- Endereço de escrita da memória de dados.
    signal ram_wa : std_logic_vector(INDEX_BITS + 1 downto 0);
    -- Palavra lida da memória de dados (leitura registrada).
    signal ram_rd : word_t;
    -- Dado de escrita da memória de dados.
    signal ram_wd : word_t;
    -- Habilita de bytes da escrita na memória de dados.
    signal ram_be : std_logic_vector(XLEN / 8 - 1 downto 0);
    -- Habilita de escrita da memória de dados.
    signal ram_we : std_logic;
    -- Endereço de leitura da memória de tags.
    signal tag_ra : std_logic_vector(INDEX_BITS - 1 downto 0);
    -- Endereço de escrita da memória de tags.
    signal tag_wa : std_logic_vector(INDEX_BITS - 1 downto 0);
    -- Tag lida da memória de tags (leitura registrada).
    signal tag_rd : std_logic_vector(TAG_BITS - 1 downto 0);
    -- Tag a escrever.
    signal tag_wd : std_logic_vector(TAG_BITS - 1 downto 0);
    -- Escrita de um acerto de store na memória de dados, registrada: vale no ciclo seguinte ao S_LOOK.
    signal wr_q   : std_logic                         := '0';
    -- Endereço da palavra da escrita registrada.
    signal wr_a_q : std_logic_vector(INDEX_BITS + 1 downto 0) := (others => '0');
    -- Dado da escrita registrada.
    signal wr_d_q : word_t                            := (others => '0');
    -- Habilita de bytes da escrita registrada.
    signal wr_b_q : std_logic_vector(XLEN / 8 - 1 downto 0) := (others => '0');
    -- Habilita de escrita da memória de tags.
    signal tag_we : std_logic;

    -- Tag do endereço do acesso.
    signal req_tag    : std_logic_vector(TAG_BITS - 1 downto 0);
    -- O endereço do pedido está na região da FLASH.
    signal is_rom     : std_logic;
    -- Índice da linha do endereço do acesso.
    signal req_idx    : std_logic_vector(INDEX_BITS - 1 downto 0);
    -- Linha em processamento.
    signal cur_idx    : std_logic_vector(INDEX_BITS - 1 downto 0);
    -- Palavra da linha em preenchimento.
    signal cnt        : unsigned(1 downto 0)              := (others => '0');
    -- Um flush está em andamento.
    signal flushing   : std_logic                         := '0';
    -- Há um pedido de flush pendente.
    signal flush_pend : std_logic                         := '0';
    -- Há um invalidate pendente.
    signal inv_pend   : std_logic                         := '0';
    -- O invalidate está em execução junto com o flush.
    signal inv_run    : std_logic                         := '0';
    -- Linha varrida pelo flush.
    signal f_idx      : unsigned(INDEX_BITS - 1 downto 0) := (others => '0');
    -- A instrução pedida está na cache.
    signal hit        : std_logic;

    -- Palavra lida da cache à espera do avanço do pipeline.
    signal pend      : word_t     := (others => '0');
    -- Palavra entregue ao core.
    signal rdata_q   : word_t     := (others => '0');
    -- Pedido de leitura ao lado da memória (registrado).
    signal d_rden_i  : std_logic                         := '0';
    -- Pedido de escrita ao lado da memória (registrado).
    signal d_wren_i  : std_logic                         := '0';
    -- Habilita de bytes do pedido ao lado da memória (registrado).
    signal d_be_i    : std_logic_vector(XLEN / 8 - 1 downto 0)      := (others => '1');
    -- Pedido de linha ao lado da memória (registrado).
    signal d_line_i  : std_logic                         := '0';
    -- Linha em escrita de volta à memória.
    signal wb_q      : std_logic_vector(4 * XLEN - 1 downto 0)    := (others => '0');
    -- Palavra da linha que acabou de chegar da memória.
    signal fill_w    : word_t;
    -- Endereço do pedido ao lado da memória (registrado).
    signal d_addr_i  : addr_t     := (others => '0');
    -- Dado do pedido ao lado da memória (registrado).
    signal d_wdata_i : word_t     := (others => '0');
    -- Pulso de fim do flush (registrado).
    signal fd_i      : std_logic                         := '0';
    -- Há um pedido de invalidação por região a aplicar neste ciclo.
    signal rq_v      : std_logic                         := '0';
    -- Índice da primeira linha do pedido de invalidação por região.
    signal rq_first  : unsigned(INDEX_BITS - 1 downto 0) := (others => '0');
    -- Linhas do pedido menos uma, módulo o número de linhas.
    signal rq_off    : unsigned(INDEX_BITS - 1 downto 0) := (others => '0');
    -- O pedido cobre todas as linhas da cache.
    signal rq_all    : std_logic                         := '0';
    -- O preenchimento em andamento cai numa região invalidada e não pode validar a linha.
    signal stale     : std_logic                         := '0';

    -- Uma linha de índice i pertence à região de invalidação que começa na linha first e tem off + 1 linhas (módulo o
    -- número de linhas), ou à região inteira (all_lines).

    function in_region (i : natural; first : unsigned; off : unsigned; all_lines : std_logic) return boolean is
    begin

        return all_lines = '1' or (to_unsigned(i, first'length) - first) <= off;

    end function in_region;

begin

    -- A palavra do núcleo tem XLEN bits, mas a linha de 4 palavras, o mapa de bits do endereço e a largura física do
    -- dispositivo deste bloco supõem a palavra de 32 bits e só elaboram com XLEN = 32.
    assert XLEN = 32
        report "este bloco só elabora com XLEN = 32"
        severity failure;

    assert write_buffer = 0 or write_through
        report "write_buffer exige write_through"
        severity failure;

    assert scratch_kib = 0
        or (is_power_of_two(scratch_kib) and scratch_base_kib mod pick(scratch_kib > 0, scratch_kib, 1) = 0)
        report "scratch_kib deve ser uma potência de dois e scratch_base_kib um múltiplo dele"
        severity failure;

    -- a memória interna é uma janela alinhada ao próprio tamanho: o acesso cai nela se os bits acima do endereço de
    -- palavra coincidem com os da base
    gen_scr_sel : if scratch_kib > 0 generate
        is_scr <= '1' when unsigned(i_addr(ADDR_BITS - 1 downto SCR_BITS + 2)) =
                  to_unsigned(scratch_base_kib / scratch_kib, ADDR_BITS - SCR_BITS - 2) else '0';
    end generate gen_scr_sel;

    gen_no_scr_sel : if scratch_kib = 0 generate
        is_scr <= '0';
    end generate gen_no_scr_sel;

    is_rom <= in_window(i_addr, flash_base_kib, flash_end_kib);

    -- endereço de memória da palavra do store: a base da região completa os bits acima da janela da cache
    wt_addr <= base_flash(5 downto window_bits - 26) & i_addr(window_bits - 1 downto 2) & "00" when is_rom = '1' else
               base_sdram(5 downto window_bits - 26) & i_addr(window_bits - 1 downto 2) & "00";

    -- sem fila, um pedido de leitura sempre pode sair; com fila, só com ela vazia e o bloco de escrita parado
    wb_idle <= '1' when write_buffer = 0 or (wb_cnt = 0 and dr = DR_IDLE) else '0';

    req_tag <= is_rom & i_addr(window_bits - 1 downto TAG_LOW);
    req_idx <= i_addr(INDEX_BITS + 3 downto 4);
    cur_idx <= std_logic_vector(f_idx) when flushing = '1' else req_idx;
    hit     <= valid(to_integer(unsigned(cur_idx))) when tag_rd = req_tag else '0';

    -- endereços de leitura: a palavra do acesso enquanto é consultada, a palavra em movimento nos outros casos
    ram_ra <= i_addr(INDEX_BITS + 3 downto 2) when (st = S_IDLE or st = S_LOOK) else cur_idx & std_logic_vector(cnt);
    tag_ra <= cur_idx;

    -- porta de escrita: o acerto de um store escreve a palavra no ciclo seguinte ao S_LOOK, a partir do que ficou registrado
    -- (wr_q), e um preenchimento escreve a palavra que chegou; assim o acerto, que depende da tag lida, só alimenta
    -- registradores, e não a habilitação de escrita das RAMs
    ram_we <= '1' when wr_q = '1' or st = S_FILL_GET else '0';
    ram_wa <= wr_a_q when wr_q = '1' else req_idx & std_logic_vector(cnt);
    fill_w <= i_d_rdata when cnt = "00" else
              i_d_rdata_x(XLEN - 1 downto 0) when cnt = "01" else
              i_d_rdata_x(2 * XLEN - 1 downto XLEN) when cnt = "10" else
              i_d_rdata_x(3 * XLEN - 1 downto 2 * XLEN);
    ram_wd <= wr_d_q when wr_q = '1' else fill_w;
    ram_be <= wr_b_q when wr_q = '1' else (others => '1');
    tag_we <= '1' when st = S_FILL_GET and cnt = "11" else '0';
    tag_wa <= req_idx;
    tag_wd <= req_tag;

    -- registra o acerto do store e o que ele escreve, no último ciclo do S_LOOK
    p_write_hit : process (i_clk) is
    begin

        if rising_edge(i_clk) then
            wr_a_q <= i_addr(INDEX_BITS + 3 downto 2);
            wr_d_q <= i_wdata;
            wr_b_q <= i_byteena;
            scr_wa_q <= i_addr(SCR_BITS + 1 downto 2);
            if i_rst = '1' then
                wr_q   <= '0';
                scr_wq <= '0';
            else
                scr_wq <= is_scr and to_sl(st = S_LOOK) and i_wren;
                if st = S_LOOK and hit = '1' and i_wren = '1' and is_rom = '0' and i_bypass = '0' and is_scr = '0' then
                    wr_q <= '1';
                else
                    wr_q <= '0';
                end if;
            end if;
        end if;

    end process p_write_hit;

    p_tag_ram : process (i_clk) is
    begin

        if rising_edge(i_clk) then
            tag_rd <= tag_ram(to_integer(unsigned(tag_ra)));
            if tag_we = '1' then
                tag_ram(to_integer(unsigned(tag_wa))) <= tag_wd;
            end if;
        end if;

    end process p_tag_ram;

    -- Uma RAM por byte do dado, cada uma com a sua habilitação de escrita: é o que a síntese reconhece como bloco de
    -- RAM (uma RAM de 32 bits escrita byte a byte num laço viraria um vetor de registradores).

    gen_lane : for b in 0 to XLEN / 8 - 1 generate
        -- Os bytes de uma posição da RAM de dados, a faixa b da palavra.
        signal lane : lane_t := (others => (others => '0'));
    begin

        p_lane_ram : process (i_clk) is
        begin

            if rising_edge(i_clk) then
                ram_rd(8 * b + 7 downto 8 * b) <= lane(to_integer(unsigned(ram_ra)));
                if ram_we = '1' and ram_be(b) = '1' then
                    lane(to_integer(unsigned(ram_wa))) <= ram_wd(8 * b + 7 downto 8 * b);
                end if;
            end if;

        end process p_lane_ram;

    end generate gen_lane;

    -- A memória interna: uma RAM de bloco por byte, lida sempre no endereço do acesso e escrita um clock depois do
    -- S_LOOK.
    gen_scr : if scratch_kib > 0 generate

        gen_scr_lane : for b in 0 to XLEN / 8 - 1 generate
            -- Os bytes de uma posição da memória interna, a faixa b da palavra.
            signal scr_lane : scr_lane_t := (others => (others => '0'));
        begin

            p_scr_ram : process (i_clk) is
            begin

                if rising_edge(i_clk) then
                    scr_rd(8 * b + 7 downto 8 * b) <= scr_lane(to_integer(unsigned(i_addr(SCR_BITS + 1 downto 2))));
                    if scr_wq = '1' and wr_b_q(b) = '1' then
                        scr_lane(to_integer(unsigned(scr_wa_q))) <= wr_d_q(8 * b + 7 downto 8 * b);
                    end if;
                end if;

            end process p_scr_ram;

        end generate gen_scr_lane;

    end generate gen_scr;

    gen_no_scr : if scratch_kib = 0 generate
        scr_rd <= (others => '0');
    end generate gen_no_scr;

    o_miss       <= '1' when st = S_FILL_REQ else '0';
    o_ready      <= '1' when st = S_DONE else '0';
    o_rdata      <= rdata_q;
    o_busy       <= flush_pend or flushing;

    o_flush_done <= fd_i;

    o_d_addr    <= d_addr_i;
    o_d_wdata   <= d_wdata_i;
    o_d_byteena <= d_be_i;
    o_d_rden    <= d_rden_i;
    o_d_wren    <= d_wren_i;
    o_d_line    <= d_line_i;
    o_d_wdata_x <= wb_q(4 * XLEN - 1 downto XLEN);
    o_d_advance <= i_d_ready;

    p_cache_fsm : process (i_clk) is

        -- Índice de linha usado no processo.
        variable ci      : integer range 0 to LINES - 1;
        -- Linhas da região pedida menos uma, em linhas de 16 bytes.
        variable span_m1 : unsigned(27 downto 0);
        -- Um store entra na fila neste ciclo.
        variable push_v  : boolean;
        -- Um store sai da fila neste ciclo.
        variable pop_v   : boolean;

    begin

        if rising_edge(i_clk) then
            fd_i   <= '0';
            push_v := false;
            pop_v  := false;
            if i_rst = '1' then
                dr         <= DR_IDLE;
                wb_cnt     <= 0;
                wb_rd      <= 0;
                wb_wr      <= 0;
                rq_v       <= '0';
                stale      <= '0';
                st         <= S_IDLE;
                valid      <= (others => '0');
                dirty      <= (others => '0');
                flushing   <= '0';
                flush_pend <= '0';
                inv_pend   <= '0';
                inv_run    <= '0';
                d_rden_i   <= '0';
                d_wren_i   <= '0';
                cnt        <= (others => '0');
            else
                ci   := to_integer(unsigned(cur_idx));
                rq_v <= '0';
                if i_inval_region = '1'
                   and unsigned(i_inval_last(31 downto 4)) >= unsigned(i_inval_first(31 downto 4)) then
                    span_m1  := unsigned(i_inval_last(31 downto 4)) - unsigned(i_inval_first(31 downto 4));
                    rq_v     <= '1';
                    rq_first <= unsigned(i_inval_first(INDEX_BITS + 3 downto 4));
                    rq_off   <= span_m1(INDEX_BITS - 1 downto 0);
                    if span_m1 >= LINES - 1 then
                        rq_all <= '1';
                    else
                        rq_all <= '0';
                    end if;
                end if;
                if i_flush = '1' then
                    flush_pend <= '1';
                    inv_pend   <= i_invalidate;
                end if;

                case st is

                    when S_IDLE =>

                        stale <= '0';
                        if flush_pend = '1' then
                            flush_pend <= '0';
                            inv_run    <= inv_pend;
                            flushing   <= '1';
                            f_idx      <= (others => '0');
                            st         <= S_FL_TAG;
                        elsif i_rden = '1' or i_wren = '1' then
                            st <= S_LOOK;
                        end if;

                    when S_LOOK =>

                        if is_scr = '1' then
                            -- memória interna: a leitura entrega a palavra, a escrita já ficou registrada em scr_wq
                            if i_wren = '0' then
                                pend <= scr_rd;
                            end if;
                            st <= S_DONE;
                        elsif i_bypass = '1' and i_wren = '0' then
                            -- load sem cache: uma palavra da memória
                            st <= S_BY_REQ;
                        elsif (write_through or is_rom = '1' or i_bypass = '1') and i_wren = '1' then
                            -- a RAM da cache recebe a palavra num acerto (ram_we); a memória a recebe nos dois casos.
                            -- Um store à FLASH nunca atualiza a cache, porque a FLASH ignora o store: só passa adiante
                            st <= S_WT_REQ;
                        elsif hit = '1' then
                            if i_wren = '1' then
                                dirty(ci) <= '1';
                            else
                                pend <= ram_rd;
                            end if;
                            st <= S_DONE;
                        else
                            cnt <= (others => '0');
                            if valid(ci) = '1' and dirty(ci) = '1' then
                                st <= S_WB_RD;
                            else
                                st <= S_FILL_REQ;
                            end if;
                        end if;

                    when S_DONE =>

                        if i_mem_advance = '1' then
                            if i_wren = '0' then
                                rdata_q <= pend;
                            end if;
                            st <= S_IDLE;
                        end if;

                    -- escrita direta: a palavra do store vai à memória
                    when S_WT_REQ =>

                        if write_buffer > 0 then
                            -- com fila, o store entra nela e completa; sem vaga espera aqui
                            if wb_cnt < WB_DEPTH then
                                wb_a(wb_wr) <= wt_addr;
                                wb_d(wb_wr) <= i_wdata;
                                wb_b(wb_wr) <= i_byteena;
                                push_v := true;
                                st     <= S_DONE;
                            end if;
                        else
                            d_addr_i  <= wt_addr;
                            d_wdata_i <= i_wdata;
                            d_be_i    <= i_byteena;
                            d_wren_i  <= '1';
                            st        <= S_WT_WAIT;
                        end if;

                    when S_WT_WAIT =>

                        if i_d_ready = '1' then
                            d_wren_i <= '0';
                            d_be_i   <= (others => '1');
                            st       <= S_DONE;
                        end if;

                    -- load sem cache: o pedido de uma palavra e a espera da resposta
                    when S_BY_REQ =>

                        -- com fila, a leitura espera os stores anteriores chegarem à memória
                        if wb_idle = '1' then
                            if is_rom = '1' then
                            d_addr_i <= base_flash(5 downto window_bits - 26) & i_addr(window_bits - 1 downto 2) & "00";
                        else
                            d_addr_i <= base_sdram(5 downto window_bits - 26) & i_addr(window_bits - 1 downto 2) & "00";
                        end if;
                            d_rden_i <= '1';
                            st       <= S_BY_WAIT;
                        end if;

                    when S_BY_WAIT =>

                        if i_d_ready = '1' then
                            d_rden_i <= '0';
                            st       <= S_BY_GET;
                        end if;

                    -- o dado lido só muda na borda em que a memória avança, então é lido um clock depois do ready
                    when S_BY_GET =>

                        pend <= i_d_rdata;
                        st   <= S_DONE;

                    -- escreve a linha suja de volta: lê as quatro palavras da RAM e faz um pedido de linha
                    when S_WB_RD =>

                        st <= S_WB_CAP;

                    when S_WB_CAP =>

                        wb_q(XLEN * to_integer(cnt) + XLEN - 1 downto XLEN * to_integer(cnt)) <= ram_rd;
                        if cnt = "11" then
                            st <= S_WB_REQ;
                        else
                            cnt <= cnt + 1;
                            st  <= S_WB_RD;
                        end if;

                    when S_WB_REQ =>

                        if tag_rd(TAG_BITS - 1) = '1' then
                            d_addr_i <= base_flash(5 downto window_bits - 26) & tag_rd(TAG_BITS - 2 downto 0)
                                        & cur_idx & "0000";
                        else
                            d_addr_i <= base_sdram(5 downto window_bits - 26) & tag_rd(TAG_BITS - 2 downto 0)
                                        & cur_idx & "0000";
                        end if;
                        d_wdata_i <= wb_q(XLEN - 1 downto 0);
                        d_line_i  <= '1';
                        d_wren_i  <= '1';
                        st        <= S_WB_WAIT;

                    when S_WB_WAIT =>

                        if i_d_ready = '1' then
                            d_wren_i  <= '0';
                            d_line_i  <= '0';
                            cnt       <= (others => '0');
                            dirty(ci) <= '0';
                            if flushing = '1' then
                                st <= S_FL_NEXT;
                            else
                                st <= S_FILL_REQ;
                            end if;
                        end if;

                    -- traz a linha: um pedido de linha e depois as palavras para a RAM
                    when S_FILL_REQ =>

                        -- com fila, o preenchimento espera os stores anteriores chegarem à memória
                        if wb_idle = '1' then
                            if req_tag(TAG_BITS - 1) = '1' then
                            d_addr_i <= base_flash(5 downto window_bits - 26) & req_tag(TAG_BITS - 2 downto 0)
                                        & req_idx & "0000";
                        else
                            d_addr_i <= base_sdram(5 downto window_bits - 26) & req_tag(TAG_BITS - 2 downto 0)
                                        & req_idx & "0000";
                        end if;
                            d_line_i <= '1';
                            d_rden_i <= '1';
                            st       <= S_FILL_WAIT;
                        end if;

                    when S_FILL_WAIT =>

                        if i_d_ready = '1' then
                            d_rden_i <= '0';
                            d_line_i <= '0';
                            cnt      <= (others => '0');
                            st       <= S_FILL_GET;
                        end if;

                    when S_FILL_GET =>

                        if cnt = "11" then
                            valid(ci) <= not stale;
                            dirty(ci) <= '0';
                            cnt       <= (others => '0');
                            st        <= S_IDLE;
                        else
                            cnt <= cnt + 1;
                        end if;

                    -- flush: as linhas uma a uma
                    when S_FL_TAG =>

                        st <= S_FL_CHK;

                    when S_FL_CHK =>

                        if valid(ci) = '1' and dirty(ci) = '1' then
                            cnt <= (others => '0');
                            st  <= S_WB_RD;
                        else
                            st <= S_FL_NEXT;
                        end if;

                    when S_FL_NEXT =>

                        if f_idx = LINES - 1 then
                            -- o flush só termina com a fila de escrita vazia
                            if wb_idle = '1' then
                                flushing <= '0';
                                fd_i     <= '1';
                                if inv_run = '1' then
                                    valid <= (others => '0');
                                end if;
                                st <= S_IDLE;
                            end if;
                        else
                            f_idx <= f_idx + 1;
                            st    <= S_FL_TAG;
                        end if;

                end case;

                -- esvazia a fila de escrita: uma palavra por vez, na ordem, quando a cache não pede à memória
                case dr is

                    when DR_IDLE =>

                        if wb_cnt > 0 then
                            d_addr_i  <= wb_a(wb_rd);
                            d_wdata_i <= wb_d(wb_rd);
                            d_be_i    <= wb_b(wb_rd);
                            d_wren_i  <= '1';
                            dr        <= DR_WAIT;
                        end if;

                    when DR_WAIT =>

                        if i_d_ready = '1' then
                            d_wren_i <= '0';
                            d_be_i   <= (others => '1');
                            pop_v    := true;
                            dr       <= DR_IDLE;
                        end if;

                end case;

                if push_v then
                    wb_wr <= (wb_wr + 1) mod WB_DEPTH;
                end if;
                if pop_v then
                    wb_rd <= (wb_rd + 1) mod WB_DEPTH;
                end if;
                if push_v and not pop_v then
                    wb_cnt <= wb_cnt + 1;
                elsif pop_v and not push_v then
                    wb_cnt <= wb_cnt - 1;
                end if;

                -- invalidação por região: derruba as linhas limpas do índice e marca o preenchimento que cai nela
                if rq_v = '1' then

                    for i in 0 to LINES - 1 loop

                        if in_region(i, rq_first, rq_off, rq_all) and dirty(i) = '0' then
                            valid(i) <= '0';
                        end if;

                    end loop;

                    if (st = S_FILL_REQ or st = S_FILL_WAIT or st = S_FILL_GET)
                       and in_region(to_integer(unsigned(req_idx)), rq_first, rq_off, rq_all) then
                        stale <= '1';
                    end if;
                end if;
            end if;
        end if;

    end process p_cache_fsm;

end architecture rtl;
