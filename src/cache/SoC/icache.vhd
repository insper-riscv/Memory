-- =============================================================================
-- Cache de instruções do core
--
-- Mapeamento direto, linhas de 16 bytes (quatro palavras), somente leitura. O tamanho é o genérico
-- size_bits, uma potência de dois: 32768 bits (4 KB, 256 linhas) por padrão e 4096 bits (4 kbit, 32 linhas).
-- Fica no caminho de busca dos endereços da SDRAM (0x40000000) e da FLASH
-- (0x20000000); a BOOT_MEMORY não passa por ela. A tag leva a região do endereço (dentro de [rom_base_kib, rom_end_kib)),
-- que distingue as duas regiões: sem ele, uma linha da FLASH e uma da SDRAM com os
-- mesmos bits de tag se confundiriam.
--
-- Lado do core: addr é o endereço de busca (o PC) e sel diz que é um endereço da
-- SDRAM. As RAMs têm leitura registrada, como as RAMs de bloco da FPGA, então a
-- instrução do endereço que estava em addr numa borda do clock está em data
-- depois dessa borda, e ready diz que é a certa: a linha é válida, a tag bate e
-- addr não mudou desde a borda. O core amostra ready e data na sua própria
-- borda, uma fração de clock depois desta; enquanto ready está baixo, ele
-- segura o endereço e a cache traz a linha. Nada aqui depende da fase do clock
-- do core além dessa ordem.
--
-- Dois clocks: a leitura das RAMs e os registradores de endereço ficam no clock
-- das memórias de instrução (i_clk); a máquina de estados, o vetor de validade e
-- o preenchimento ficam no clock do core (i_clk_cpu). O que cruza de um para o
-- outro é o endereço e a seleção (do core para as RAMs), os controles de escrita
-- das RAMs, que a máquina de estados mantém estáveis por um clock inteiro do core,
-- e o que as RAMs leram. Com os dois clocks iguais o comportamento é o de um
-- clock só.
--
-- Lado da memória: o mesmo contrato da dcache. Um pedido de linha (quatro
-- palavras, d_line alto, as três últimas em d_rdata_x) fica em d_addr e d_rden
-- até d_ready; d_advance o responde.
--
-- invalidate: um pulso derruba todas as linhas em um clock. Um preenchimento de
-- linha em andamento quando o pulso chega também é descartado (pode conter
-- código anterior aos stores que o programa terminou), então nada que a cache
-- guarda é mais velho que o invalidate.
--
-- i_inval_region: um pulso derruba as linhas da região de i_inval_first a i_inval_last (endereços de byte, o último
-- incluído), como o controlador de FLASH pede depois de apagar ou gravar. Cada linha da cache guarda a tag, não o endereço
-- completo, então a cache derruba por índice: toda linha cujo índice cai em algum endereço da região, mesmo a de outra
-- região com o mesmo índice (uma região de tantas linhas quantas a cache tem derruba tudo). Um preenchimento em andamento
-- cuja linha cai na região é descartado. O pedido é registrado e aplicado no ciclo seguinte; o bit de validade lido tem
-- mais um ciclo de atraso, então nenhuma linha da região acerta a partir do terceiro ciclo depois do pulso. Um pedido com
-- i_inval_last menor que i_inval_first não tem efeito.
--
-- Nada escreve na SDRAM por trás da cache exceto a porta de debug, que o faz com
-- o core parado e a cache invalidada (como depois do reset), e os próprios
-- stores do core, que a cache não observa: só um fence.i os torna visíveis à
-- busca.
--
-- Divisão do endereço (janela de 2**window_bits bytes por região, 64 MiB por padrão): região (1 = ROM, pelos genéricos rom_base_kib e rom_end_kib), bits window_bits-1:12
-- tag, 11:4 linha, 3:2 palavra (com 256 linhas; o índice ocupa log2 do número de linhas bits a partir do
-- bit 4 e a tag o que sobra até o bit window_bits-1). Os demais bits a partir de window_bits não são guardados; o
-- lado da memória acrescenta a base da região neles (base_flash ou base_sdram).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.utils_pkg.all;

entity icache is
  generic (
    -- Tamanho da cache em bits, uma potência de dois de pelo menos 256 (duas linhas de 128 bits): 32768 é 4 KB e 4096 é 4 kbit.
    size_bits  : positive := 32768;
    -- Largura do endereço que a janela da cache cobre, de 2**window_bits bytes (26 é 64 MiB, 27 é 128 MiB): a tag guarda os bits abaixo dela e a base da região, do lado da memória, completa os de cima.
    window_bits : natural range 26 to 29 := 26;
    -- Bits 31:26 dos endereços da SDRAM (0x40000000), acrescentados do lado da memória; só os bits de 31 até window_bits entram, os de baixo são da tag.
    base_sdram : std_logic_vector(5 downto 0) := "010000";
    -- Bits 31:26 dos endereços da FLASH (0x20000000), acrescentados do lado da memória.
    base_flash : std_logic_vector(5 downto 0) := "001000";
    -- Base, em KiB, da região da ROM; o que cai nela é tratado como FLASH (0x20000000 por padrão).
    rom_base_kib : natural := 524288;
    -- Fim exclusivo, em KiB, da região da ROM (0x40000000 por padrão).
    rom_end_kib  : natural := 1048576;
    -- Com valor não negativo, a seleção da cache sai do endereço registrado (selecionado a partir deste endereço, em KiB), e a porta i_sel é ignorada; -1 usa i_sel. Tira a decodificação do PC do caminho até a cache.
    sel_from_kib : integer := -1;
    -- Confere, a cada consulta, que o endereço registrado ainda é o de i_addr. Com os dois clocks defasados (a borda de i_clk sempre antes da próxima do core) o endereço não muda entre as duas bordas, e a conferência de 32 bits sai do caminho da tag ao PC (false).
    check_addr   : boolean := true
  );
  port (
    -- Clock das memórias de instrução: lê as RAMs e registra o endereço de busca.
    i_clk        : in  std_logic;
    -- Clock da máquina de estados, do vetor de validade e da escrita de preenchimento: o clock do core.
    -- As RAMs são lidas no clock das memórias de instrução (i_clk), adiantado em relação a este.
    i_clk_cpu    : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst        : in  std_logic;

    -- Endereço de busca (o PC).
    i_addr       : in  std_logic_vector(31 downto 0);
    -- O endereço de busca pertence à FLASH ou à SDRAM ('1').
    i_sel        : in  std_logic;
    -- A instrução em o_data é a do endereço atual ('1').
    o_ready      : out std_logic;
    -- Instrução buscada.
    o_data       : out std_logic_vector(31 downto 0);
    -- Pulso que derruba todas as linhas da cache.
    i_invalidate : in  std_logic := '0';
    -- Pulso de um ciclo no início de cada preenchimento de linha (uma falha da cache).
    o_miss       : out std_logic;
    -- Pulso que derruba as linhas da região de i_inval_first a i_inval_last.
    i_inval_region : in std_logic := '0';
    -- Primeiro endereço de byte da região a derrubar.
    i_inval_first  : in std_logic_vector(31 downto 0) := (others => '0');
    -- Último endereço de byte da região a derrubar (incluído).
    i_inval_last   : in std_logic_vector(31 downto 0) := (others => '0');

    -- Lado da memória: endereço do acesso.
    o_d_addr     : out std_logic_vector(31 downto 0);
    -- Lado da memória: pedido de leitura ('1').
    o_d_rden     : out std_logic;
    -- Lado da memória: o pipeline avançou, o acesso pode ser concluído.
    o_d_advance  : out std_logic;
    -- Lado da memória: acesso concluído, dado lido válido ('1').
    i_d_ready    : in  std_logic;
    -- Lado da memória: dado lido.
    i_d_rdata    : in  std_logic_vector(31 downto 0);
    -- Lado da memória: acesso de linha de quatro palavras ('1').
    o_d_line     : out std_logic;
    -- Lado da memória: palavras 1 a 3 do dado lido da linha.
    i_d_rdata_x  : in  std_logic_vector(95 downto 0) := (others => '0')
  );
end entity icache;

architecture rtl of icache is

  -- Estados da cache: livre e as etapas do preenchimento de linha.
  type state_t is (S_IDLE, S_FILL_REQ, S_FILL_WAIT, S_FILL_GET, S_SETTLE, S_SWEEP, S_RELEASE, S_SETTLE2, S_RELEASE2);
  -- Estado atual da cache.
  signal st : state_t := S_IDLE;

  -- Primeiro endereço de byte selecionado quando a seleção sai do endereço registrado (sel_from_kib não negativo).
  function sel_from_addr_of (kib : integer) return unsigned is
  begin
    if kib < 0 then
      return to_unsigned(0, 32);
    end if;
    return shift_left(to_unsigned(kib, 32), 10);
  end function sel_from_addr_of;

  -- Primeiro endereço de byte selecionado (sel_from_kib não negativo).
  constant SEL_FROM_ADDR : unsigned(31 downto 0) := sel_from_addr_of(sel_from_kib);

  -- Bits do índice da linha: o tamanho em bits dividido pelos 128 bits de uma linha, em logaritmo exato (falha se o tamanho não for uma potência de dois).
  function index_bits_of (bits : positive) return natural is
  begin
    assert bits >= 256 report "size_bits must hold at least two lines of 128 bits" severity failure;
    return log2_exact(bits) - 7;
  end function index_bits_of;

  -- Bits do índice da linha.
  constant INDEX_BITS : natural := index_bits_of(size_bits);
  -- Linhas da cache.
  constant LINES    : natural := 2 ** INDEX_BITS;
  -- Bits da tag: a região (ROM ou não) e os bits window_bits-1 até INDEX_BITS + 4.
  constant TAG_BITS : natural := window_bits - 3 - INDEX_BITS;
  -- Primeiro bit da tag no endereço, logo acima do índice e do deslocamento dentro da linha.
  constant TAG_LOW  : natural := INDEX_BITS + 4;

  -- Memória de dados: quatro palavras por linha.
  type data_t is array (0 to 4 * LINES - 1) of std_logic_vector(31 downto 0);
  -- Memória de tags: uma tag por linha (região e bits window_bits-1 até o fim do índice).
  type tag_t  is array (0 to LINES - 1) of std_logic_vector(TAG_BITS - 1 downto 0);
  -- Palavras das linhas.
  signal data_ram : data_t := (others => (others => '0'));
  -- Tag de cada linha.
  signal tag_ram  : tag_t  := (others => (others => '0'));
  -- Memória de validade: um bit por linha, em RAM como as de dados e de tags, lida no mesmo endereço (a leitura de um vetor de registradores era o pior caminho do PC até a cache).
  type valid_t is array (0 to LINES - 1) of std_logic;
  -- Bit de validade de cada linha.
  signal valid_ram : valid_t := (others => '0');
  -- Uma invalidação (pedido ou reset) está pendente ou em andamento: nenhuma consulta acerta e nenhum preenchimento começa até a varredura zerar as linhas.
  signal blocked  : std_logic := '1';
  -- Linha que a varredura de invalidação zera neste ciclo.
  signal sw_idx   : unsigned(INDEX_BITS - 1 downto 0) := (others => '0');
  -- Habilitação de escrita da memória de dados, registrada.
  signal w_ram_we   : std_logic := '0';
  -- Endereço de escrita da memória de dados, registrado.
  signal w_ram_wa   : std_logic_vector(INDEX_BITS + 1 downto 0) := (others => '0');
  -- Dado de escrita da memória de dados, registrado.
  signal w_data     : std_logic_vector(31 downto 0) := (others => '0');
  -- Habilitação de escrita da memória de tags, registrada.
  signal w_tag_we   : std_logic := '0';
  -- Índice de escrita da memória de tags, registrado.
  signal w_tag_idx  : std_logic_vector(INDEX_BITS - 1 downto 0) := (others => '0');
  -- Tag de escrita da memória de tags, registrada.
  signal w_tag      : std_logic_vector(TAG_BITS - 1 downto 0) := (others => '0');
  -- Habilitação de escrita da memória de validade, registrada.
  signal w_valid_we : std_logic := '0';
  -- Endereço de escrita da memória de validade, registrado.
  signal w_valid_wa : std_logic_vector(INDEX_BITS - 1 downto 0) := (others => '0');
  -- Dado de escrita da memória de validade, registrado.
  signal w_valid_wd : std_logic := '0';
  -- Habilita de escrita da memória de validade.
  signal valid_we : std_logic;
  -- Endereço de escrita da memória de validade.
  signal valid_wa : std_logic_vector(INDEX_BITS - 1 downto 0);
  -- Dado de escrita da memória de validade (1 ao fim de um preenchimento, 0 na varredura).
  signal valid_wd : std_logic;

  -- Palavra lida da memória de dados (leitura registrada).
  signal ram_rd   : std_logic_vector(31 downto 0) := (others => '0');
  -- Tag lida da memória de tags (leitura registrada).
  signal tag_rd   : std_logic_vector(TAG_BITS - 1 downto 0) := (others => '0');
  -- Validade da linha lida (registrada).
  signal valid_rd : std_logic := '0';
  -- Endereço que estava em addr na última borda.
  signal addr_q   : std_logic_vector(31 downto 0) := (others => '0');
  -- Valor de sel na última borda.
  signal sel_q    : std_logic := '0';
  -- Seleção efetiva do endereço registrado: sel_q, ou a decodificação do endereço registrado com sel_from_kib.
  signal sel_eff  : std_logic;
  -- Parte do acerto que não depende da leitura das RAMs: seleção, sem varredura em curso e endereço inalterado.
  signal early_ok : std_logic;

  -- A tag lida bate com a do endereço registrado.
  signal tag_match : std_logic;
  -- A instrução pedida está na cache.
  signal hit       : std_logic;

  -- Tag da linha em preenchimento.
  signal fill_tag : std_logic_vector(TAG_BITS - 1 downto 0);
  -- Índice da linha em preenchimento.
  signal fill_idx : std_logic_vector(INDEX_BITS - 1 downto 0);
  -- A consulta do ciclo anterior errou: registrada, tira a leitura da tag do caminho até a máquina de estados.
  signal miss_q   : std_logic := '0';
  -- Endereço da falha, copiado do endereço registrado sem lógica; a tag e o índice do preenchimento saem dele.
  signal miss_a   : std_logic_vector(31 downto 0) := (others => '0');
  -- O endereço registrado é o de i_addr (ou a conferência está desligada).
  signal addr_same : std_logic;
  -- Palavra da linha em preenchimento.
  signal cnt      : unsigned(1 downto 0) := (others => '0');
  -- Palavra da linha que acabou de chegar da memória.
  signal fill_w   : std_logic_vector(31 downto 0);
  -- Há um pedido de invalidação por região a aplicar neste ciclo.
  signal rq_v     : std_logic := '0';
  -- Índice da primeira linha do pedido de invalidação por região.
  signal rq_first : unsigned(INDEX_BITS - 1 downto 0) := (others => '0');
  -- Linhas do pedido menos uma, módulo o número de linhas.
  signal rq_off   : unsigned(INDEX_BITS - 1 downto 0) := (others => '0');
  -- O pedido cobre todas as linhas da cache.
  signal rq_all   : std_logic := '0';
  -- Há linhas a zerar à espera da varredura (um pedido que chegou com a máquina ocupada).
  signal pend       : std_logic := '1';
  -- Índice da primeira linha a zerar do pedido pendente.
  signal pend_first : unsigned(INDEX_BITS - 1 downto 0) := (others => '0');
  -- Linhas do pedido pendente menos uma.
  signal pend_off   : unsigned(INDEX_BITS - 1 downto 0) := (others => '1');
  -- Linhas que a varredura em andamento ainda zera depois da atual.
  signal sw_left    : unsigned(INDEX_BITS - 1 downto 0) := (others => '0');
  -- Habilita de escrita da memória de dados.
  signal ram_we : std_logic;
  -- Habilita de escrita da memória de tags.
  signal tag_we : std_logic;
  -- Endereço de escrita da memória de dados.
  signal ram_wa : std_logic_vector(INDEX_BITS + 1 downto 0);
  -- Pedido de leitura ao lado da memória (registrado).
  signal d_rden_i : std_logic := '0';
  -- Pedido de linha ao lado da memória (registrado).
  signal d_line_i : std_logic := '0';
  -- Endereço do pedido ao lado da memória (registrado).
  signal d_addr_i : std_logic_vector(31 downto 0) := (others => '0');

  -- A região da ROM: o endereço está em [rom_base_kib, rom_end_kib) KiB.
  function in_rom(addr : std_logic_vector(31 downto 0)) return std_logic is
  begin
    if unsigned(addr) >= shift_left(to_unsigned(rom_base_kib, 32), 10) and
       unsigned(addr) < shift_left(to_unsigned(rom_end_kib, 32), 10) then
      return '1';
    end if;
    return '0';
  end function in_rom;

begin

  tag_match <= '1' when tag_rd = (in_rom(addr_q) & addr_q(window_bits - 1 downto TAG_LOW)) else '0';
  sel_eff   <= sel_q when sel_from_kib < 0 else
               '1' when unsigned(addr_q) >= SEL_FROM_ADDR else '0';
  hit       <= sel_eff and valid_rd and tag_match and (not blocked);
  addr_same <= '1' when (not check_addr) or addr_q = i_addr else '0';
  early_ok  <= sel_eff and (not blocked) when addr_same = '1' else '0';
  o_ready   <= early_ok and valid_rd and tag_match;
  o_data      <= ram_rd;

  fill_w <= i_d_rdata when cnt = "00" else
            i_d_rdata_x(31 downto 0)  when cnt = "01" else
            i_d_rdata_x(63 downto 32) when cnt = "10" else
            i_d_rdata_x(95 downto 64);
  ram_wa <= fill_idx & std_logic_vector(cnt);
  ram_we <= '1' when st = S_FILL_GET else '0';
  tag_we <= '1' when st = S_FILL_GET and cnt = "11" else '0';
  valid_we <= '1' when st = S_SWEEP or (st = S_FILL_GET and cnt = "11") else '0';
  valid_wa <= std_logic_vector(sw_idx) when st = S_SWEEP else fill_idx;
  valid_wd <= '0' when st = S_SWEEP else '1';

  -- Os controles, o endereço e o dado das escritas saem de registradores do clock do core: o caminho até as RAMs (no clock de busca) deixa de passar pela lógica da máquina e pelo roteador da memória. A escrita acontece um ciclo depois do estado que a pede.
  process (i_clk_cpu)
  begin
    if rising_edge(i_clk_cpu) then
      if i_rst = '1' then
        w_ram_we   <= '0';
        w_tag_we   <= '0';
        w_valid_we <= '0';
      else
        w_ram_we   <= ram_we;
        w_tag_we   <= tag_we;
        w_valid_we <= valid_we;
      end if;
      w_ram_wa   <= ram_wa;
      w_data     <= fill_w;
      w_tag_idx  <= fill_idx;
      w_tag      <= fill_tag;
      w_valid_wa <= valid_wa;
      w_valid_wd <= valid_wd;
    end if;
  end process;

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      ram_rd   <= data_ram(to_integer(unsigned(i_addr(INDEX_BITS + 3 downto 2))));
      tag_rd   <= tag_ram(to_integer(unsigned(i_addr(INDEX_BITS + 3 downto 4))));
      valid_rd <= valid_ram(to_integer(unsigned(i_addr(INDEX_BITS + 3 downto 4))));
      addr_q   <= i_addr;
      sel_q    <= i_sel;
      if w_ram_we = '1' then
        data_ram(to_integer(unsigned(w_ram_wa))) <= w_data;
      end if;
      if w_tag_we = '1' then
        tag_ram(to_integer(unsigned(w_tag_idx))) <= w_tag;
      end if;
      if w_valid_we = '1' then
        valid_ram(to_integer(unsigned(w_valid_wa))) <= w_valid_wd;
      end if;
    end if;
  end process;

  o_miss      <= '1' when st = S_FILL_REQ else '0';

  o_d_addr    <= d_addr_i;
  o_d_rden    <= d_rden_i;
  o_d_line    <= d_line_i;
  o_d_advance <= i_d_ready;

  process (i_clk_cpu)
    -- Linhas da região pedida menos uma, em linhas de 16 bytes.
    variable span_m1 : unsigned(27 downto 0);
  begin
    if rising_edge(i_clk_cpu) then
      if i_rst = '1' then
        rq_v     <= '0';
        st       <= S_IDLE;
        sw_idx   <= (others => '0');
        blocked  <= '1';
        pend       <= '1';
        pend_first <= (others => '0');
        pend_off   <= (others => '1');
        d_rden_i <= '0';
        d_line_i <= '0';
        cnt      <= (others => '0');
        miss_q   <= '0';
      else
        rq_v <= '0';
        if st = S_IDLE and hit = '0' and sel_eff = '1' and addr_same = '1' and i_invalidate = '0' and blocked = '0' then
          miss_q <= '1';
        else
          miss_q <= '0';
        end if;
        miss_a <= addr_q;
        if i_inval_region = '1' and unsigned(i_inval_last(31 downto 4)) >= unsigned(i_inval_first(31 downto 4)) then
          span_m1 := unsigned(i_inval_last(31 downto 4)) - unsigned(i_inval_first(31 downto 4));
          rq_v     <= '1';
          rq_first <= unsigned(i_inval_first(INDEX_BITS + 3 downto 4));
          rq_off   <= span_m1(INDEX_BITS - 1 downto 0);
          if span_m1 >= LINES - 1 then
            rq_all <= '1';
          else
            rq_all <= '0';
          end if;
        end if;
        -- um pedido de invalidação bloqueia as consultas até a varredura zerar as linhas dele; um segundo pedido
        -- que encontra outro pendente vira o pedido de todas as linhas
        if i_invalidate = '1' or rq_v = '1' then
          blocked <= '1';
          if i_invalidate = '1' then
            pend       <= '1';
            pend_first <= (others => '0');
            pend_off   <= (others => '1');
          elsif pend = '1' then
            pend_first <= (others => '0');
            pend_off   <= (others => '1');
          else
            pend       <= '1';
            pend_first <= rq_first;
            if rq_all = '1' then
              pend_off <= (others => '1');
            else
              pend_off <= rq_off;
            end if;
          end if;
        end if;
        case st is

          when S_IDLE =>
            if blocked = '1' then
              if pend = '1' and i_invalidate = '0' and rq_v = '0' then
                sw_idx  <= pend_first;
                sw_left <= pend_off;
                pend    <= '0';
                st      <= S_SWEEP;
              end if;
            -- uma falha registrada no ciclo anterior (a decisão sai da leitura da tag em um registrador): traz a sua linha
            elsif miss_q = '1' and i_invalidate = '0' then
              fill_tag <= in_rom(miss_a) & miss_a(window_bits - 1 downto TAG_LOW);
              fill_idx <= miss_a(INDEX_BITS + 3 downto 4);
              st       <= S_FILL_REQ;
            end if;

          when S_FILL_REQ =>
            if fill_tag(TAG_BITS - 1) = '1' then
              d_addr_i <= base_flash(5 downto window_bits - 26) & fill_tag(TAG_BITS - 2 downto 0) & fill_idx & "0000";
            else
              d_addr_i <= base_sdram(5 downto window_bits - 26) & fill_tag(TAG_BITS - 2 downto 0) & fill_idx & "0000";
            end if;
            d_line_i <= '1';
            d_rden_i <= '1';
            st       <= S_FILL_WAIT;

          when S_FILL_WAIT =>
            if i_d_ready = '1' then
              d_rden_i <= '0';
              d_line_i <= '0';
              cnt      <= (others => '0');
              st       <= S_FILL_GET;
            end if;

          when S_FILL_GET =>
            if cnt = "11" then
              cnt <= (others => '0');
              st  <= S_SETTLE2;
            else
              cnt <= cnt + 1;
            end if;

          -- a leitura registrada precisa ver a tag e o bit de validade novos antes da próxima consulta
          when S_SETTLE =>
            st <= S_IDLE;

          -- as escritas das RAMs saem de registradores e acontecem um ciclo depois: mais um ciclo antes da leitura nova
          when S_SETTLE2 =>
            st <= S_SETTLE;

          -- varredura de invalidação: zera uma linha por ciclo
          when S_SWEEP =>
            if sw_left = 0 then
              st <= S_RELEASE;
            else
              sw_idx  <= sw_idx + 1;
              sw_left <= sw_left - 1;
            end if;

          -- a escrita da última linha só aparece na leitura registrada um ciclo depois: as consultas voltam a acertar daqui
          when S_RELEASE =>
            if pend = '1' or i_invalidate = '1' or rq_v = '1' then
              st <= S_IDLE;
            else
              st <= S_RELEASE2;
            end if;

          -- o último zero é escrito um ciclo depois do estado de varredura: as consultas só voltam a acertar depois dele
          when S_RELEASE2 =>
            if pend = '1' or i_invalidate = '1' or rq_v = '1' then
              st <= S_IDLE;
            else
              blocked <= '0';
              st      <= S_SETTLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
