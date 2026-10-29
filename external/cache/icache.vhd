-- =============================================================================
-- Cache de instruções do core
--
-- 4 KB, mapeamento direto, linhas de 16 bytes (quatro palavras), somente leitura.
-- Fica no caminho de busca dos endereços da SDRAM; a BOOT_ROM e a FLASH não
-- passam por ela.
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
-- Lado da memória: o mesmo contrato da dcache. Um pedido de linha (quatro
-- palavras, d_line alto, as três últimas em d_rdata_x) fica em d_addr e d_rden
-- até d_ready; d_advance o responde.
--
-- invalidate: um pulso derruba todas as linhas em um clock. Um preenchimento de
-- linha em andamento quando o pulso chega também é descartado (pode conter
-- código anterior aos stores que o programa terminou), então nada que a cache
-- guarda é mais velho que o invalidate.
--
-- Nada escreve na SDRAM por trás da cache exceto a porta de debug, que o faz com
-- o core parado e a cache invalidada (como depois do reset), e os próprios
-- stores do core, que a cache não observa: só um fence.i os torna visíveis à
-- busca.
--
-- Divisão do endereço do espaço da SDRAM (64 MB): bits 25:12 tag, 11:4 linha,
-- 3:2 palavra. Os bits acima de 25 não são guardados; o lado da memória
-- acrescenta base neles.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity icache is
  generic (
    -- Bits 31:26 dos endereços da SDRAM (0x40000000), acrescentados do lado da memória.
    base : std_logic_vector(5 downto 0) := "010000"
  );
  port (
    -- Clock do módulo.
    i_clk        : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst        : in  std_logic;

    -- Endereço de busca (o PC).
    i_addr       : in  std_logic_vector(31 downto 0);
    -- O endereço de busca pertence à SDRAM ('1').
    i_sel        : in  std_logic;
    -- A instrução em o_data é a do endereço atual ('1').
    o_ready      : out std_logic;
    -- Instrução buscada.
    o_data       : out std_logic_vector(31 downto 0);
    -- Pulso que derruba todas as linhas da cache.
    i_invalidate : in  std_logic := '0';

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
  type state_t is (S_IDLE, S_FILL_REQ, S_FILL_WAIT, S_FILL_GET, S_SETTLE);
  -- Estado atual da cache.
  signal st : state_t := S_IDLE;

  -- Memória de dados: 1024 palavras, quatro por linha.
  type data_t is array (0 to 1023) of std_logic_vector(31 downto 0);
  -- Memória de tags: uma tag de 14 bits por linha.
  type tag_t  is array (0 to 255) of std_logic_vector(13 downto 0);
  -- Palavras das 256 linhas.
  signal data_ram : data_t := (others => (others => '0'));
  -- Tag de cada linha.
  signal tag_ram  : tag_t  := (others => (others => '0'));
  -- Bit de validade de cada linha.
  signal valid    : std_logic_vector(255 downto 0) := (others => '0');

  -- Palavra lida da memória de dados (leitura registrada).
  signal ram_rd   : std_logic_vector(31 downto 0) := (others => '0');
  -- Tag lida da memória de tags (leitura registrada).
  signal tag_rd   : std_logic_vector(13 downto 0) := (others => '0');
  -- Validade da linha lida (registrada).
  signal valid_rd : std_logic := '0';
  -- Endereço que estava em addr na última borda.
  signal addr_q   : std_logic_vector(31 downto 0) := (others => '0');
  -- Valor de sel na última borda.
  signal sel_q    : std_logic := '0';

  -- A tag lida bate com a do endereço registrado.
  signal tag_match : std_logic;
  -- A instrução pedida está na cache.
  signal hit       : std_logic;

  -- Tag da linha em preenchimento.
  signal fill_tag : std_logic_vector(13 downto 0);
  -- Índice da linha em preenchimento.
  signal fill_idx : std_logic_vector(7 downto 0);
  -- Palavra da linha em preenchimento.
  signal cnt      : unsigned(1 downto 0) := (others => '0');
  -- Um invalidate chegou durante o preenchimento, a linha será descartada.
  signal drop     : std_logic := '0';
  -- Palavra da linha que acabou de chegar da memória.
  signal fill_w   : std_logic_vector(31 downto 0);
  -- Habilita de escrita da memória de dados.
  signal ram_we : std_logic;
  -- Habilita de escrita da memória de tags.
  signal tag_we : std_logic;
  -- Endereço de escrita da memória de dados.
  signal ram_wa : std_logic_vector(9 downto 0);
  -- Pedido de leitura ao lado da memória (registrado).
  signal d_rden_i : std_logic := '0';
  -- Pedido de linha ao lado da memória (registrado).
  signal d_line_i : std_logic := '0';
  -- Endereço do pedido ao lado da memória (registrado).
  signal d_addr_i : std_logic_vector(31 downto 0) := (others => '0');

begin

  tag_match <= '1' when tag_rd = addr_q(25 downto 12) else '0';
  hit       <= sel_q and valid_rd and tag_match;
  o_ready     <= hit when addr_q = i_addr else '0';
  o_data      <= ram_rd;

  fill_w <= i_d_rdata when cnt = "00" else
            i_d_rdata_x(31 downto 0)  when cnt = "01" else
            i_d_rdata_x(63 downto 32) when cnt = "10" else
            i_d_rdata_x(95 downto 64);
  ram_wa <= fill_idx & std_logic_vector(cnt);
  ram_we <= '1' when st = S_FILL_GET else '0';
  tag_we <= '1' when st = S_FILL_GET and cnt = "11" else '0';

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      ram_rd   <= data_ram(to_integer(unsigned(i_addr(11 downto 2))));
      tag_rd   <= tag_ram(to_integer(unsigned(i_addr(11 downto 4))));
      valid_rd <= valid(to_integer(unsigned(i_addr(11 downto 4))));
      addr_q   <= i_addr;
      sel_q    <= i_sel;
      if ram_we = '1' then
        data_ram(to_integer(unsigned(ram_wa))) <= fill_w;
      end if;
      if tag_we = '1' then
        tag_ram(to_integer(unsigned(fill_idx))) <= fill_tag;
      end if;
    end if;
  end process;

  o_d_addr    <= d_addr_i;
  o_d_rden    <= d_rden_i;
  o_d_line    <= d_line_i;
  o_d_advance <= i_d_ready;

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        st       <= S_IDLE;
        valid    <= (others => '0');
        drop     <= '0';
        d_rden_i <= '0';
        d_line_i <= '0';
        cnt      <= (others => '0');
      else
        if i_invalidate = '1' then
          valid <= (others => '0');
          if st /= S_IDLE then
            drop <= '1';
          end if;
        end if;
        case st is

          when S_IDLE =>
            drop <= '0';
            -- uma falha do endereço que ainda está em addr: traz a sua linha
            if sel_q = '1' and hit = '0' and addr_q = i_addr and i_invalidate = '0' then
              fill_tag <= addr_q(25 downto 12);
              fill_idx <= addr_q(11 downto 4);
              st       <= S_FILL_REQ;
            end if;

          when S_FILL_REQ =>
            d_addr_i <= base & fill_tag & fill_idx & "0000";
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
              if drop = '0' and i_invalidate = '0' then
                valid(to_integer(unsigned(fill_idx))) <= '1';
              end if;
              cnt <= (others => '0');
              st  <= S_SETTLE;
            else
              cnt <= cnt + 1;
            end if;

          -- a leitura registrada precisa ver a tag e o bit de validade novos antes da próxima consulta
          when S_SETTLE =>
            st <= S_IDLE;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
