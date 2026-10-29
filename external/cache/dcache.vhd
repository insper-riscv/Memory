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
-- Divisão do endereço do espaço da SDRAM (64 MB): bits 25:12 tag, 11:4 linha,
-- 3:2 palavra. Os bits acima de 25 não são guardados; o lado da memória
-- acrescenta base neles.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dcache is
  generic (
    -- Bits 31:26 dos endereços da SDRAM (0x40000000), acrescentados do lado da memória.
    base          : std_logic_vector(5 downto 0) := "010000";
    -- Verdadeiro: todo store vai também à memória e a falha de store não traz a linha (nenhuma linha fica suja).
    write_through : boolean := false
  );
  port (
    -- Clock do módulo.
    i_clk         : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst         : in  std_logic;

    -- Endereço do acesso.
    i_addr        : in  std_logic_vector(31 downto 0);
    -- Dado de escrita.
    i_wdata       : in  std_logic_vector(31 downto 0);
    -- Habilita de bytes da escrita, um bit por byte.
    i_byteena     : in  std_logic_vector(3 downto 0);
    -- Pedido de leitura ('1' = lê).
    i_rden        : in  std_logic;
    -- Pedido de escrita ('1' = escreve).
    i_wren        : in  std_logic;
    -- O pipeline avançou neste ciclo, o acesso em andamento pode ser concluído.
    i_mem_advance : in  std_logic;
    -- Acesso concluído, o dado lido é válido ('1').
    o_ready       : out std_logic;
    -- Dado lido.
    o_rdata       : out std_logic_vector(31 downto 0);

    -- Pede a escrita de todas as linhas sujas na memória ('1').
    i_flush       : in  std_logic;
    -- Invalida todas as linhas da cache ('1').
    i_invalidate  : in  std_logic := '0';
    -- A escrita das linhas sujas terminou ('1').
    o_flush_done  : out std_logic;
    -- O módulo está ocupado ('1').
    o_busy        : out std_logic;

    -- Lado da memória: endereço do acesso.
    o_d_addr      : out std_logic_vector(31 downto 0);
    -- Lado da memória: dado de escrita.
    o_d_wdata     : out std_logic_vector(31 downto 0);
    -- Lado da memória: habilita de bytes da escrita.
    o_d_byteena   : out std_logic_vector(3 downto 0);
    -- Lado da memória: pedido de leitura ('1').
    o_d_rden      : out std_logic;
    -- Lado da memória: pedido de escrita ('1').
    o_d_wren      : out std_logic;
    -- Lado da memória: o pipeline avançou, o acesso pode ser concluído.
    o_d_advance   : out std_logic;
    -- Lado da memória: acesso concluído, dado lido válido ('1').
    i_d_ready     : in  std_logic;
    -- Lado da memória: dado lido.
    i_d_rdata     : in  std_logic_vector(31 downto 0);
    -- Lado da memória: acesso de linha de quatro palavras ('1').
    o_d_line      : out std_logic;
    -- Lado da memória: palavras 1 a 3 do dado de escrita da linha.
    o_d_wdata_x   : out std_logic_vector(95 downto 0);
    -- Lado da memória: palavras 1 a 3 do dado lido da linha.
    i_d_rdata_x   : in  std_logic_vector(95 downto 0) := (others => '0')
  );
end entity dcache;

architecture rtl of dcache is

  -- Estados da cache: acesso, escrita de volta, preenchimento, flush e escrita direta.
  type state_t is (
    S_IDLE, S_LOOK, S_DONE,
    S_WB_RD, S_WB_CAP, S_WB_REQ, S_WB_WAIT,
    S_FILL_REQ, S_FILL_WAIT, S_FILL_GET,
    S_FL_TAG, S_FL_CHK, S_FL_NEXT,
    S_WT_REQ, S_WT_WAIT);
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
  -- Bit de linha suja: a linha difere da memória.
  signal dirty    : std_logic_vector(255 downto 0) := (others => '0');

  -- Endereço de leitura da memória de dados.
  signal ram_ra : std_logic_vector(9 downto 0);
  -- Endereço de escrita da memória de dados.
  signal ram_wa : std_logic_vector(9 downto 0);
  -- Palavra lida da memória de dados (leitura registrada).
  signal ram_rd : std_logic_vector(31 downto 0);
  -- Dado de escrita da memória de dados.
  signal ram_wd : std_logic_vector(31 downto 0);
  -- Habilita de bytes da escrita na memória de dados.
  signal ram_be         : std_logic_vector(3 downto 0);
  -- Habilita de escrita da memória de dados.
  signal ram_we         : std_logic;
  -- Endereço de leitura da memória de tags.
  signal tag_ra : std_logic_vector(7 downto 0);
  -- Endereço de escrita da memória de tags.
  signal tag_wa : std_logic_vector(7 downto 0);
  -- Tag lida da memória de tags (leitura registrada).
  signal tag_rd : std_logic_vector(13 downto 0);
  -- Tag a escrever.
  signal tag_wd : std_logic_vector(13 downto 0);
  -- Habilita de escrita da memória de tags.
  signal tag_we         : std_logic;

  -- Tag do endereço do acesso.
  signal req_tag  : std_logic_vector(13 downto 0);
  -- Índice da linha do endereço do acesso.
  signal req_idx  : std_logic_vector(7 downto 0);
  -- Linha em processamento.
  signal cur_idx  : std_logic_vector(7 downto 0);
  -- Palavra da linha em preenchimento.
  signal cnt      : unsigned(1 downto 0) := (others => '0');
  -- Um flush está em andamento.
  signal flushing : std_logic := '0';
  -- Há um pedido de flush pendente.
  signal flush_pend : std_logic := '0';
  -- Há um invalidate pendente.
  signal inv_pend : std_logic := '0';
  -- O invalidate está em execução junto com o flush.
  signal inv_run : std_logic := '0';
  -- Linha varrida pelo flush.
  signal f_idx    : unsigned(7 downto 0) := (others => '0');
  -- A instrução pedida está na cache.
  signal hit      : std_logic;

  -- Palavra lida da cache à espera do avanço do pipeline.
  signal pend     : std_logic_vector(31 downto 0) := (others => '0');
  -- Palavra entregue ao core.
  signal rdata_q  : std_logic_vector(31 downto 0) := (others => '0');
  -- Pedido de leitura ao lado da memória (registrado).
  signal d_rden_i : std_logic := '0';
  -- Pedido de escrita ao lado da memória (registrado).
  signal d_wren_i : std_logic := '0';
  -- Habilita de bytes do pedido ao lado da memória (registrado).
  signal d_be_i   : std_logic_vector(3 downto 0) := "1111";
  -- Pedido de linha ao lado da memória (registrado).
  signal d_line_i : std_logic := '0';
  -- Linha em escrita de volta à memória.
  signal wb_q     : std_logic_vector(127 downto 0) := (others => '0');
  -- Palavra da linha que acabou de chegar da memória.
  signal fill_w   : std_logic_vector(31 downto 0);
  -- Endereço do pedido ao lado da memória (registrado).
  signal d_addr_i : std_logic_vector(31 downto 0) := (others => '0');
  -- Dado do pedido ao lado da memória (registrado).
  signal d_wdata_i : std_logic_vector(31 downto 0) := (others => '0');
  -- Pulso de fim do flush (registrado).
  signal fd_i     : std_logic := '0';

begin

  req_tag <= i_addr(25 downto 12);
  req_idx <= i_addr(11 downto 4);
  cur_idx <= std_logic_vector(f_idx) when flushing = '1' else req_idx;
  hit     <= valid(to_integer(unsigned(cur_idx))) when tag_rd = req_tag else '0';

  -- endereços de leitura: a palavra do acesso enquanto é consultada, a palavra em movimento nos outros casos
  ram_ra <= i_addr(11 downto 2) when (st = S_IDLE or st = S_LOOK) else cur_idx & std_logic_vector(cnt);
  tag_ra <= cur_idx;

  -- porta de escrita: um acerto escreve a palavra, um preenchimento escreve a palavra que chegou
  ram_we <= '1' when (st = S_LOOK and hit = '1' and i_wren = '1') or st = S_FILL_GET else '0';
  ram_wa <= i_addr(11 downto 2) when st = S_LOOK else req_idx & std_logic_vector(cnt);
  fill_w <= i_d_rdata when cnt = "00" else
            i_d_rdata_x(31 downto 0)  when cnt = "01" else
            i_d_rdata_x(63 downto 32) when cnt = "10" else
            i_d_rdata_x(95 downto 64);
  ram_wd <= i_wdata when st = S_LOOK else fill_w;
  ram_be <= i_byteena when st = S_LOOK else "1111";
  tag_we <= '1' when st = S_FILL_GET and cnt = "11" else '0';
  tag_wa <= req_idx;
  tag_wd <= req_tag;

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      ram_rd <= data_ram(to_integer(unsigned(ram_ra)));
      if ram_we = '1' then
        for b in 0 to 3 loop
          if ram_be(b) = '1' then
            data_ram(to_integer(unsigned(ram_wa)))(8 * b + 7 downto 8 * b) <= ram_wd(8 * b + 7 downto 8 * b);
          end if;
        end loop;
      end if;
      tag_rd <= tag_ram(to_integer(unsigned(tag_ra)));
      if tag_we = '1' then
        tag_ram(to_integer(unsigned(tag_wa))) <= tag_wd;
      end if;
    end if;
  end process;

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
  o_d_wdata_x <= wb_q(127 downto 32);
  o_d_advance <= i_d_ready;

  process (i_clk)
    -- Índice de linha usado no processo.
    variable ci : integer range 0 to 255;
  begin
    if rising_edge(i_clk) then
      fd_i <= '0';
      if i_rst = '1' then
        st       <= S_IDLE;
        valid    <= (others => '0');
        dirty    <= (others => '0');
        flushing <= '0';
        flush_pend <= '0';
        inv_pend   <= '0';
        inv_run    <= '0';
        d_rden_i <= '0';
        d_wren_i <= '0';
        cnt      <= (others => '0');
      else
        ci := to_integer(unsigned(cur_idx));
        if i_flush = '1' then
          flush_pend <= '1';
          inv_pend   <= i_invalidate;
        end if;
        case st is

          when S_IDLE =>
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
            if write_through and i_wren = '1' then
              -- a RAM da cache recebe a palavra num acerto (ram_we); a memória a recebe nos dois casos
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
            d_addr_i  <= base & i_addr(25 downto 2) & "00";
            d_wdata_i <= i_wdata;
            d_be_i    <= i_byteena;
            d_wren_i  <= '1';
            st        <= S_WT_WAIT;

          when S_WT_WAIT =>
            if i_d_ready = '1' then
              d_wren_i <= '0';
              d_be_i   <= "1111";
              st       <= S_DONE;
            end if;

          -- escreve a linha suja de volta: lê as quatro palavras da RAM e faz um pedido de linha
          when S_WB_RD =>
            st <= S_WB_CAP;

          when S_WB_CAP =>
            wb_q(32 * to_integer(cnt) + 31 downto 32 * to_integer(cnt)) <= ram_rd;
            if cnt = "11" then
              st <= S_WB_REQ;
            else
              cnt <= cnt + 1;
              st  <= S_WB_RD;
            end if;

          when S_WB_REQ =>
            d_addr_i  <= base & tag_rd & cur_idx & "0000";
            d_wdata_i <= wb_q(31 downto 0);
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
            d_addr_i <= base & req_tag & req_idx & "0000";
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
              valid(ci) <= '1';
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
            if f_idx = 255 then
              flushing <= '0';
              fd_i     <= '1';
              if inv_run = '1' then
                valid <= (others => '0');
              end if;
              st       <= S_IDLE;
            else
              f_idx <= f_idx + 1;
              st    <= S_FL_TAG;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
