-- ========================================================================
-- Ponte de busca de instrução sem cache
--
-- Entrega ao núcleo a instrução do endereço de busca lendo-a direto da
-- memória externa (o chip de FLASH, pelo roteador de região e pelo
-- árbitro), para a plataforma com ROM externa e sem cache de instruções.
-- Fala com o núcleo o mesmo contrato da icache (i_addr, i_sel, o_ready,
-- o_data, i_invalidate) e com a memória o mesmo contrato de linha dela
-- (o pedido fica em o_d_addr, o_d_rden e o_d_line até i_d_ready, que é
-- um nível até o_d_advance), então uma pode ser trocada pela outra sem
-- mexer em quem as liga.
--
-- Isto NÃO é uma cache. Não há RAM de dados, vetor de tags nem
-- reaproveitamento por índice: existe um único registrador de busca, com
-- a palavra pedida (ou, com fetch_line, a linha de quatro palavras que a
-- contém, para que o código sequencial pague a latência do chip uma vez
-- por quatro instruções) e o endereço a que ele pertence. O registrador
-- só atende o endereço de busca corrente, enquanto o núcleo o mantém
-- parado (espera de outro estágio) ou caminha dentro da mesma linha; o
-- primeiro endereço fora dele, inclusive um desvio, dispara um novo
-- pedido à memória. Nada é guardado para um uso futuro além disso.
--
-- Contrato do lado do núcleo: o_ready sobe quando o_data é a instrução
-- do endereço que está em i_addr agora, e cai sozinho assim que i_addr
-- muda para um endereço que o registrador não contém. O núcleo mantém o
-- PC enquanto o_ready está baixo, e o PC só avança com o_ready em '1'.
-- A icache lê as RAMs no clock adiantado das memórias de instrução; aqui
-- o registrador de busca fica no clock do núcleo, então o dado já está
-- estável quando o núcleo o amostra e nenhum clock adiantado é preciso.
--
-- Um pedido em andamento não pode ser abortado (o chip termina a espera
-- e só então aceita outro), então um desvio durante a espera paga o resto
-- dela e depois a latência inteira do endereço novo. A palavra que
-- chegou para o endereço antigo fica no registrador e é substituída.
--
-- i_invalidate (o fence.i) descarta o registrador, e um pedido em
-- andamento quando o pulso chega é concluído e descartado, de modo que
-- nada guardado é mais velho que a invalidação. O reset também o
-- descarta. Stores do núcleo não são observados: só o fence.i torna
-- código escrito visível à busca.
--
-- Endereço: o núcleo usa o PC; a região (1 = ROM, pelos genéricos
-- rom_base_kib e rom_end_kib) escolhe a base de 31:26 (base_flash ou
-- base_sdram) e os bits 25:0 do PC seguem, como na icache.
-- ========================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ifetch_bridge is
  generic (
    -- Pede à memória a linha de quatro palavras que contém o endereço (true) ou só a palavra dele (false).
    fetch_line   : boolean := true;
    -- Bits 31:26 dos endereços da SDRAM (0x40000000), acrescentados do lado da memória.
    base_sdram   : std_logic_vector(5 downto 0) := "010000";
    -- Bits 31:26 dos endereços da FLASH (0x20000000), acrescentados do lado da memória.
    base_flash   : std_logic_vector(5 downto 0) := "001000";
    -- Base, em KiB, da região da ROM; o que cai nela é tratado como FLASH (0x20000000 por padrão).
    rom_base_kib : natural := 524288;
    -- Fim exclusivo, em KiB, da região da ROM (0x40000000 por padrão).
    rom_end_kib  : natural := 1048576
  );
  port (
    -- Clock do núcleo: o do registrador de busca, da máquina de estados e do reset.
    i_clk        : in  std_logic;
    -- Reset, ativo em '1'; descarta o registrador de busca.
    i_rst        : in  std_logic;

    -- Endereço de busca (o PC).
    i_addr       : in  std_logic_vector(31 downto 0);
    -- O endereço de busca pertence à FLASH ou à SDRAM ('1').
    i_sel        : in  std_logic;
    -- A instrução em o_data é a do endereço atual ('1').
    o_ready      : out std_logic;
    -- Instrução buscada.
    o_data       : out std_logic_vector(31 downto 0);
    -- Pulso que descarta o registrador de busca (o fence.i).
    i_invalidate : in  std_logic := '0';
    -- Pulso de um ciclo depois do início de cada pedido à memória.
    o_miss       : out std_logic;

    -- Lado da memória: endereço do acesso.
    o_d_addr     : out std_logic_vector(31 downto 0);
    -- Lado da memória: pedido de leitura ('1').
    o_d_rden     : out std_logic;
    -- Lado da memória: o pipeline avançou, o acesso pode ser concluído.
    o_d_advance  : out std_logic;
    -- Lado da memória: acesso concluído, dado lido válido ('1').
    i_d_ready    : in  std_logic;
    -- Lado da memória: dado lido (a palavra 0).
    i_d_rdata    : in  std_logic_vector(31 downto 0);
    -- Lado da memória: acesso de linha de quatro palavras ('1').
    o_d_line     : out std_logic;
    -- Lado da memória: palavras 1 a 3 do dado lido da linha.
    i_d_rdata_x  : in  std_logic_vector(95 downto 0) := (others => '0')
  );
end entity ifetch_bridge;

architecture rtl of ifetch_bridge is

  -- Estados da ponte: livre e esperando a memória concluir o pedido.
  type state_t is (S_IDLE, S_WAIT);
  -- Estado atual da ponte.
  signal st : state_t := S_IDLE;

  -- Palavras do registrador de busca: quatro com fetch_line, uma sem.
  function words_of (line : boolean) return positive is
  begin
    if line then
      return 4;
    end if;
    return 1;
  end function words_of;

  -- Primeiro bit do endereço comparado: acima do deslocamento dentro do que o registrador guarda.
  function low_bit_of (line : boolean) return natural is
  begin
    if line then
      return 4;
    end if;
    return 2;
  end function low_bit_of;

  -- Palavras que o registrador de busca guarda.
  constant WORDS   : positive := words_of(fetch_line);
  -- Primeiro bit do endereço comparado com o do registrador.
  constant LOW_BIT : natural  := low_bit_of(fetch_line);

  -- Palavras do registrador de busca (a palavra 0 nos bits mais baixos).
  signal fetch_data : std_logic_vector(32 * WORDS - 1 downto 0) := (others => '0');
  -- Endereço do núcleo a que o registrador de busca pertence.
  signal fetch_addr : std_logic_vector(31 downto 0) := (others => '0');
  -- O registrador de busca guarda uma instrução válida.
  signal fetch_ok   : std_logic := '0';
  -- Endereço do núcleo do pedido em andamento.
  signal pend_addr  : std_logic_vector(31 downto 0) := (others => '0');
  -- Um invalidate chegou durante o pedido, a palavra será descartada.
  signal drop       : std_logic := '0';
  -- Pedido de leitura ao lado da memória (registrado).
  signal d_rden_i   : std_logic := '0';
  -- Pedido de linha ao lado da memória (registrado).
  signal d_line_i   : std_logic := '0';
  -- Endereço do pedido ao lado da memória (registrado).
  signal d_addr_i   : std_logic_vector(31 downto 0) := (others => '0');
  -- Pulso do início de um pedido (registrado).
  signal miss_i     : std_logic := '0';

  -- O endereço de busca é o do registrador de busca.
  signal match      : std_logic;

  -- A região da ROM: o endereço está em [rom_base_kib, rom_end_kib) KiB.
  function in_rom(addr : std_logic_vector(31 downto 0)) return std_logic is
  begin
    if unsigned(addr) >= shift_left(to_unsigned(rom_base_kib, 32), 10) and
       unsigned(addr) < shift_left(to_unsigned(rom_end_kib, 32), 10) then
      return '1';
    end if;
    return '0';
  end function in_rom;

  -- Endereço do pedido à memória: a base da região nos bits 31:26, os bits 25:0 do núcleo alinhados ao que se pede.
  function mem_addr_of(addr : std_logic_vector(31 downto 0)) return std_logic_vector is
    variable low : std_logic_vector(25 downto 0) := addr(25 downto 0);
  begin
    low(LOW_BIT - 1 downto 0) := (others => '0');
    if in_rom(addr) = '1' then
      return base_flash & low;
    end if;
    return base_sdram & low;
  end function mem_addr_of;

begin

  match   <= '1' when i_addr(31 downto LOW_BIT) = fetch_addr(31 downto LOW_BIT) else '0';
  o_ready <= fetch_ok and match and i_sel;

  g_line : if fetch_line generate
    o_data <= fetch_data(32 * to_integer(unsigned(i_addr(3 downto 2))) + 31 downto
                         32 * to_integer(unsigned(i_addr(3 downto 2))));
  end generate g_line;

  g_word : if not fetch_line generate
    o_data <= fetch_data;
  end generate g_word;

  o_miss      <= miss_i;
  o_d_addr    <= d_addr_i;
  o_d_rden    <= d_rden_i;
  o_d_line    <= d_line_i;
  o_d_advance <= i_d_ready;

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        st       <= S_IDLE;
        fetch_ok <= '0';
        drop     <= '0';
        d_rden_i <= '0';
        d_line_i <= '0';
        miss_i   <= '0';
      else
        miss_i <= '0';
        if i_invalidate = '1' then
          fetch_ok <= '0';
          if st /= S_IDLE then
            drop <= '1';
          end if;
        end if;
        case st is

          when S_IDLE =>
            drop <= '0';
            -- uma falta do endereço de busca corrente: pede à memória
            if i_sel = '1' and not (fetch_ok = '1' and match = '1') and i_invalidate = '0' then
              pend_addr <= i_addr;
              d_addr_i  <= mem_addr_of(i_addr);
              d_rden_i  <= '1';
              if fetch_line then
                d_line_i <= '1';
              end if;
              miss_i    <= '1';
              st        <= S_WAIT;
            end if;

          when S_WAIT =>
            if i_d_ready = '1' then
              d_rden_i <= '0';
              d_line_i <= '0';
              if drop = '0' and i_invalidate = '0' then
                if fetch_line then
                  fetch_data <= i_d_rdata_x & i_d_rdata;
                else
                  fetch_data <= i_d_rdata;
                end if;
                fetch_addr <= pend_addr;
                fetch_ok   <= '1';
              end if;
              drop <= '0';
              st   <= S_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
