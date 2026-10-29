-- =============================================================================
-- Ponte entre a porta de dados externa do core e uma porta escravo AXI4
--
-- O core é o mestre.
--
-- Lado do core, o mesmo contrato da sdram_cpu_bridge: o acesso fica em
-- addr/wdata/byteena/rden/wren enquanto o estágio de memória está parado; ready
-- sobe quando o acesso termina e permanece em nível alto até mem_advance indicar
-- que o pipeline andou; rdata/rdata_x só mudam nessa mesma borda, porque o load
-- ainda no estágio de write-back lê o valor anterior até lá. err sobe junto com
-- ready quando o escravo respondeu SLVERR ou DECERR (o core ainda não tem como
-- usá-lo). Um acesso de linha (line = '1'; addr alinhado em 16 bytes) é uma
-- rajada de quatro beats, INCR, de 32 bits: a palavra 0 em wdata/byteena/rdata e
-- as palavras 1 a 3 em wdata_x/byteena_x/rdata_x (a palavra 1 nos bits mais
-- baixos), como na sdram_cpu_bridge. Sem line é um beat. Toda transação usa o ID
-- 0 (os sinais são omitidos), tamanho de 4 bytes, sem lock e sem atributos de
-- cache.
--
-- Lado AXI, uma transação por vez (sem transações pendentes, logo sem regras de
-- ordenação):
--
--   escrita  AW é oferecido até ser aceito e os beats de W seguem em ordem, cada
--            um retido até o seu ready; o acesso termina quando B chega. wstrb é
--            o habilita de bytes do beat.
--   leitura  AR é oferecido até ser aceito; o acesso termina quando o último beat
--            de R chega. Uma leitura sempre pede palavras inteiras; byteena não
--            é usado.
--
-- O endereço e os dados são copiados quando o acesso começa e ficam no barramento,
-- então permanecem estáveis enquanto um valid está alto, aconteça o que acontecer
-- no core. bready e rready só sobem depois de o pedido ser aceito, então uma
-- resposta que chega antes disso não é aceita. Uma leitura cujo último beat não
-- traz rlast é sinalizada em err.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity axi_master_bridge is
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
    -- Acesso de linha, quatro palavras seguidas ('1').
    i_line        : in  std_logic := '0';
    -- Palavras 1 a 3 do dado de escrita da linha.
    i_wdata_x     : in  std_logic_vector(95 downto 0) := (others => '0');
    -- Habilita de bytes das palavras 1 a 3 da linha.
    i_byteena_x   : in  std_logic_vector(11 downto 0) := (others => '0');
    -- Palavras 1 a 3 do dado lido da linha.
    o_rdata_x     : out std_logic_vector(95 downto 0);
    -- Resposta de erro do barramento ('1').
    o_err         : out std_logic;

    -- Porta mestre AXI4, canal de endereço de escrita: validade da transferência ('1' = válida).
    o_m_awvalid   : out std_logic;
    -- Porta mestre AXI4, canal de endereço de escrita: destino pronto para aceitar a transferência ('1').
    i_m_awready   : in  std_logic;
    -- Porta mestre AXI4, canal de endereço de escrita: endereço do primeiro beat.
    o_m_awaddr    : out std_logic_vector(31 downto 0);
    -- Porta mestre AXI4, canal de endereço de escrita: número de beats da rajada menos um.
    o_m_awlen     : out std_logic_vector(7 downto 0);
    -- Porta mestre AXI4, canal de endereço de escrita: log2 do número de bytes por beat.
    o_m_awsize    : out std_logic_vector(2 downto 0);
    -- Porta mestre AXI4, canal de endereço de escrita: tipo de rajada (1 = INCR).
    o_m_awburst   : out std_logic_vector(1 downto 0);
    -- Porta mestre AXI4, canal de endereço de escrita: atributos de proteção.
    o_m_awprot    : out std_logic_vector(2 downto 0);
    -- Porta mestre AXI4, canal de dados de escrita: validade da transferência ('1' = válida).
    o_m_wvalid    : out std_logic;
    -- Porta mestre AXI4, canal de dados de escrita: destino pronto para aceitar a transferência ('1').
    i_m_wready    : in  std_logic;
    -- Porta mestre AXI4, canal de dados de escrita: dados.
    o_m_wdata     : out std_logic_vector(31 downto 0);
    -- Porta mestre AXI4, canal de dados de escrita: habilita de bytes.
    o_m_wstrb     : out std_logic_vector(3 downto 0);
    -- Porta mestre AXI4, canal de dados de escrita: último beat da rajada ('1').
    o_m_wlast     : out std_logic;
    -- Porta mestre AXI4, canal de resposta de escrita: validade da transferência ('1' = válida).
    i_m_bvalid    : in  std_logic;
    -- Porta mestre AXI4, canal de resposta de escrita: destino pronto para aceitar a transferência ('1').
    o_m_bready    : out std_logic;
    -- Porta mestre AXI4, canal de resposta de escrita: resposta (0 = OKAY, 2 = SLVERR).
    i_m_bresp     : in  std_logic_vector(1 downto 0);
    -- Porta mestre AXI4, canal de endereço de leitura: validade da transferência ('1' = válida).
    o_m_arvalid   : out std_logic;
    -- Porta mestre AXI4, canal de endereço de leitura: destino pronto para aceitar a transferência ('1').
    i_m_arready   : in  std_logic;
    -- Porta mestre AXI4, canal de endereço de leitura: endereço do primeiro beat.
    o_m_araddr    : out std_logic_vector(31 downto 0);
    -- Porta mestre AXI4, canal de endereço de leitura: número de beats da rajada menos um.
    o_m_arlen     : out std_logic_vector(7 downto 0);
    -- Porta mestre AXI4, canal de endereço de leitura: log2 do número de bytes por beat.
    o_m_arsize    : out std_logic_vector(2 downto 0);
    -- Porta mestre AXI4, canal de endereço de leitura: tipo de rajada (1 = INCR).
    o_m_arburst   : out std_logic_vector(1 downto 0);
    -- Porta mestre AXI4, canal de endereço de leitura: atributos de proteção.
    o_m_arprot    : out std_logic_vector(2 downto 0);
    -- Porta mestre AXI4, canal de dados de leitura: validade da transferência ('1' = válida).
    i_m_rvalid    : in  std_logic;
    -- Porta mestre AXI4, canal de dados de leitura: destino pronto para aceitar a transferência ('1').
    o_m_rready    : out std_logic;
    -- Porta mestre AXI4, canal de dados de leitura: dados.
    i_m_rdata     : in  std_logic_vector(31 downto 0);
    -- Porta mestre AXI4, canal de dados de leitura: resposta (0 = OKAY, 2 = SLVERR).
    i_m_rresp     : in  std_logic_vector(1 downto 0);
    -- Porta mestre AXI4, canal de dados de leitura: último beat da rajada ('1').
    i_m_rlast     : in  std_logic
  );
end entity axi_master_bridge;

architecture rtl of axi_master_bridge is

  -- palavra k (1 a 3) das três palavras extras e seus quatro habilita de bytes
  function word_x (v : std_logic_vector(95 downto 0); k : natural) return std_logic_vector is
  begin
    if k = 0 then
      return x"00000000";
    end if;
    return v(32 * k - 1 downto 32 * (k - 1));
  end function;

  function be_x (v : std_logic_vector(11 downto 0); k : natural) return std_logic_vector is
  begin
    if k = 0 then
      return "0000";
    end if;
    return v(4 * k - 1 downto 4 * (k - 1));
  end function;

  -- Estados da ponte: livre, escrita, leitura e acesso concluído aguardando o avanço do pipeline.
  type state_t is (ST_IDLE, ST_WR, ST_RD, ST_DONE);
  -- Estado atual da ponte.
  signal st      : state_t := ST_IDLE;

  -- O endereço de escrita está sendo oferecido (AWVALID).
  signal awv     : std_logic := '0';
  -- Um beat de escrita está sendo oferecido (WVALID).
  signal wv      : std_logic := '0';
  -- O endereço de leitura está sendo oferecido (ARVALID).
  signal arv     : std_logic := '0';
  -- Beat em W, ou o próximo beat de R.
  signal beat    : natural range 0 to 3 := 0;
  -- Último beat da transação: 3 para uma linha, 0 para uma palavra.
  signal last_b  : natural range 0 to 3 := 0;
  -- Endereço do acesso, copiado ao iniciar.
  signal addr_l  : std_logic_vector(31 downto 0) := (others => '0');
  -- Dado de escrita da palavra 0, copiado ao iniciar.
  signal wdata_l : std_logic_vector(31 downto 0) := (others => '0');
  -- Habilita de bytes da palavra 0, copiado ao iniciar.
  signal strb_l  : std_logic_vector(3 downto 0) := (others => '0');
  -- Palavras 1 a 3 de escrita, copiadas ao iniciar.
  signal wdx_l   : std_logic_vector(95 downto 0) := (others => '0');
  -- Habilita de bytes das palavras 1 a 3, copiado ao iniciar.
  signal bex_l   : std_logic_vector(11 downto 0) := (others => '0');
  -- O acesso em andamento é uma escrita.
  signal we_l    : std_logic := '0';
  -- O escravo respondeu com erro, ou faltou rlast na leitura.
  signal err_l   : std_logic := '0';
  -- Palavra 0 lida, à espera do avanço do pipeline.
  signal pending   : std_logic_vector(31 downto 0) := (others => '0');
  -- Palavras 1 a 3 lidas, à espera do avanço do pipeline.
  signal pending_x : std_logic_vector(95 downto 0) := (others => '0');
  -- Palavra 0 entregue ao core.
  signal rdata_q   : std_logic_vector(31 downto 0) := (others => '0');
  -- Palavras 1 a 3 entregues ao core.
  signal rdx_q     : std_logic_vector(95 downto 0) := (others => '0');

begin

  o_m_awvalid <= awv;
  o_m_awaddr  <= addr_l;
  o_m_awlen   <= "00000011" when last_b = 3 else "00000000";
  o_m_awsize  <= "010";   -- 4 bytes
  o_m_awburst <= "01";    -- INCR
  o_m_awprot  <= "000";   -- sem privilégio, seguro, dados
  o_m_wvalid  <= wv;
  o_m_wdata   <= wdata_l when beat = 0 else word_x(wdx_l, beat);
  o_m_wstrb   <= strb_l  when beat = 0 else be_x(bex_l, beat);
  o_m_wlast   <= '1' when beat = last_b else '0';
  o_m_arvalid <= arv;
  o_m_araddr  <= addr_l;
  o_m_arlen   <= "00000011" when last_b = 3 else "00000000";
  o_m_arsize  <= "010";
  o_m_arburst <= "01";
  o_m_arprot  <= "000";

  -- uma resposta só é tomada depois de o pedido que ela responde ter sido aceito
  o_m_bready  <= '1' when st = ST_WR and awv = '0' and wv = '0' else '0';
  o_m_rready  <= '1' when st = ST_RD and arv = '0' else '0';

  o_ready     <= '1' when st = ST_DONE else '0';
  o_rdata     <= rdata_q;
  o_rdata_x   <= rdx_q;
  o_err       <= err_l when st = ST_DONE else '0';

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        st    <= ST_IDLE;
        awv   <= '0';
        wv    <= '0';
        arv   <= '0';
        we_l  <= '0';
        err_l <= '0';
        beat  <= 0;
      else
        case st is

          when ST_IDLE =>
            if (i_rden = '1' or i_wren = '1') then
              addr_l  <= i_addr(31 downto 2) & "00";   -- palavras inteiras; o habilita de bytes escolhe os bytes
              wdata_l <= i_wdata;
              strb_l  <= i_byteena;
              wdx_l   <= i_wdata_x;
              bex_l   <= i_byteena_x;
              we_l    <= i_wren;
              beat    <= 0;
              err_l   <= '0';
              if i_line = '1' then
                last_b <= 3;
              else
                last_b <= 0;
              end if;
              if i_wren = '1' then
                awv <= '1';
                wv  <= '1';
                st  <= ST_WR;
              else
                arv <= '1';
                st  <= ST_RD;
              end if;
            end if;

          when ST_WR =>
            if awv = '1' and i_m_awready = '1' then
              awv <= '0';
            end if;
            if wv = '1' and i_m_wready = '1' then
              if beat = last_b then
                wv   <= '0';
                beat <= 0;
              else
                beat <= beat + 1;
              end if;
            end if;
            if i_m_bvalid = '1' and awv = '0' and wv = '0' then
              err_l <= i_m_bresp(1);
              st    <= ST_DONE;
            end if;

          when ST_RD =>
            if arv = '1' and i_m_arready = '1' then
              arv <= '0';
            end if;
            if i_m_rvalid = '1' and arv = '0' then
              if beat = 0 then
                pending <= i_m_rdata;
              else
                pending_x(32 * beat - 1 downto 32 * (beat - 1)) <= i_m_rdata;   -- aqui os beats 1 a 3
              end if;
              if i_m_rresp(1) = '1' then
                err_l <= '1';
              end if;
              if (i_m_rlast = '1') /= (beat = last_b) then
                err_l <= '1';       -- a rajada tem comprimento diferente do pedido
              end if;
              if beat = last_b or i_m_rlast = '1' then
                st <= ST_DONE;
              else
                beat <= beat + 1;
              end if;
            end if;

          when ST_DONE =>
            if i_mem_advance = '1' then
              if we_l = '0' then
                rdata_q <= pending;
                rdx_q   <= pending_x;
              end if;
              st <= ST_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
