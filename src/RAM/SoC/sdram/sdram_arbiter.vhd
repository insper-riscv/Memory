-- =============================================================================
-- Árbitro de três mestres para o controlador SDRAM
--
-- Três mestres compartilham a interface de pedido do sdram_ctrl: a ponte de dados
-- do core (A), o mestre de debug (B) e a ponte de instruções do core (I). Um
-- pedido é a inversão de req_tog com a palavra em we/addr/wdata/be, respondida
-- pela inversão de ack_tog. O bloco atende um pedido por vez e, com vários
-- mestres esperando, revezam-se: o mestre atendido por último vai para o fim da
-- ordem A, I, B, de modo que nenhum espera mais de um acesso de cada um dos
-- outros.
--
-- Os mestres A e I podem pedir uma linha (quatro palavras) com line e as demais
-- palavras em wdata_x, be_x e rdata_x; o mestre B move uma palavra por vez. Os
-- mestres A e I vêm do clock do core, então seus toggles são sincronizados aqui
-- e seus barramentos ficam estáveis da inversão até a resposta. O mestre B está
-- neste clock. O mestre I é opcional: sem conexão, nunca pede.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity sdram_arbiter is
  port (
    -- Clock do módulo.
    i_clk       : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst       : in  std_logic;

    -- Porta do mestre A (ponte de dados do core): alternância que pede um acesso, cada inversão é um pedido novo.
    i_a_req_tog : in  std_logic;
    -- Porta do mestre A (ponte de dados do core): alternância que confirma o acesso, igual a req_tog quando o pedido foi atendido.
    o_a_ack_tog : out std_logic;
    -- Porta do mestre A (ponte de dados do core): escrita ('1') ou leitura ('0').
    i_a_we      : in  std_logic;
    -- Porta do mestre A (ponte de dados do core): endereço de palavra.
    i_a_addr    : in  std_logic_vector(23 downto 0);
    -- Porta do mestre A (ponte de dados do core): dado de escrita.
    i_a_wdata   : in  std_logic_vector(31 downto 0);
    -- Porta do mestre A (ponte de dados do core): habilita de bytes da escrita.
    i_a_be      : in  std_logic_vector(3 downto 0);
    -- Porta do mestre A (ponte de dados do core): dado lido.
    o_a_rdata   : out std_logic_vector(31 downto 0);
    -- Porta do mestre A (ponte de dados do core): acesso de linha de quatro palavras ('1').
    i_a_line    : in  std_logic := '0';
    -- Porta do mestre A (ponte de dados do core): palavras 1 a 3 do dado de escrita da linha.
    i_a_wdata_x : in  std_logic_vector(95 downto 0) := (others => '0');
    -- Porta do mestre A (ponte de dados do core): habilita de bytes das palavras 1 a 3.
    i_a_be_x    : in  std_logic_vector(11 downto 0) := (others => '0');
    -- Porta do mestre A (ponte de dados do core): palavras 1 a 3 do dado lido da linha.
    o_a_rdata_x : out std_logic_vector(95 downto 0);

    -- Porta do mestre I (ponte de instruções do core): alternância que pede um acesso, cada inversão é um pedido novo.
    i_ins_req_tog : in  std_logic := '0';
    -- Porta do mestre I (ponte de instruções do core): alternância que confirma o acesso, igual a req_tog quando o pedido foi atendido.
    o_ins_ack_tog : out std_logic;
    -- Porta do mestre I (ponte de instruções do core): escrita ('1') ou leitura ('0').
    i_ins_we      : in  std_logic := '0';
    -- Porta do mestre I (ponte de instruções do core): endereço de palavra.
    i_ins_addr    : in  std_logic_vector(23 downto 0) := (others => '0');
    -- Porta do mestre I (ponte de instruções do core): dado de escrita.
    i_ins_wdata   : in  std_logic_vector(31 downto 0) := (others => '0');
    -- Porta do mestre I (ponte de instruções do core): habilita de bytes da escrita.
    i_ins_be      : in  std_logic_vector(3 downto 0) := (others => '0');
    -- Porta do mestre I (ponte de instruções do core): dado lido.
    o_ins_rdata   : out std_logic_vector(31 downto 0);
    -- Porta do mestre I (ponte de instruções do core): acesso de linha de quatro palavras ('1').
    i_ins_line    : in  std_logic := '0';
    -- Porta do mestre I (ponte de instruções do core): palavras 1 a 3 do dado de escrita da linha.
    i_ins_wdata_x : in  std_logic_vector(95 downto 0) := (others => '0');
    -- Porta do mestre I (ponte de instruções do core): habilita de bytes das palavras 1 a 3.
    i_ins_be_x    : in  std_logic_vector(11 downto 0) := (others => '0');
    -- Porta do mestre I (ponte de instruções do core): palavras 1 a 3 do dado lido da linha.
    o_ins_rdata_x : out std_logic_vector(95 downto 0);

    -- Porta do mestre B (porta de debug): alternância que pede um acesso, cada inversão é um pedido novo.
    i_b_req_tog : in  std_logic;
    -- Porta do mestre B (porta de debug): alternância que confirma o acesso, igual a req_tog quando o pedido foi atendido.
    o_b_ack_tog : out std_logic;
    -- Porta do mestre B (porta de debug): escrita ('1') ou leitura ('0').
    i_b_we      : in  std_logic;
    -- Porta do mestre B (porta de debug): endereço de palavra.
    i_b_addr    : in  std_logic_vector(23 downto 0);
    -- Porta do mestre B (porta de debug): dado de escrita.
    i_b_wdata   : in  std_logic_vector(31 downto 0);
    -- Porta do mestre B (porta de debug): habilita de bytes da escrita.
    i_b_be      : in  std_logic_vector(3 downto 0);
    -- Porta do mestre B (porta de debug): dado lido.
    o_b_rdata   : out std_logic_vector(31 downto 0);

    -- Porta do controlador SDRAM: alternância que pede um acesso, cada inversão é um pedido novo.
    o_c_req_tog : out std_logic;
    -- Porta do controlador SDRAM: alternância que confirma o acesso, igual a req_tog quando o pedido foi atendido.
    i_c_ack_tog : in  std_logic;
    -- Porta do controlador SDRAM: escrita ('1') ou leitura ('0').
    o_c_we      : out std_logic;
    -- Porta do controlador SDRAM: endereço de palavra.
    o_c_addr    : out std_logic_vector(23 downto 0);
    -- Porta do controlador SDRAM: dado de escrita.
    o_c_wdata   : out std_logic_vector(31 downto 0);
    -- Porta do controlador SDRAM: habilita de bytes da escrita.
    o_c_be      : out std_logic_vector(3 downto 0);
    -- Porta do controlador SDRAM: dado lido.
    i_c_rdata   : in  std_logic_vector(31 downto 0);
    -- Porta do controlador SDRAM: acesso de linha de quatro palavras ('1').
    o_c_line    : out std_logic;
    -- Porta do controlador SDRAM: palavras 1 a 3 do dado de escrita da linha.
    o_c_wdata_x : out std_logic_vector(95 downto 0);
    -- Porta do controlador SDRAM: habilita de bytes das palavras 1 a 3.
    o_c_be_x    : out std_logic_vector(11 downto 0);
    -- Porta do controlador SDRAM: palavras 1 a 3 do dado lido da linha.
    i_c_rdata_x : in  std_logic_vector(95 downto 0)
  );
end entity sdram_arbiter;

architecture rtl of sdram_arbiter is

  -- Estados do árbitro.
  type state_t is (ST_IDLE, ST_BUSY);
  -- Estado do árbitro: livre para escolher um mestre ou aguardando o controlador.
  signal st        : state_t := ST_IDLE;
  -- Sincronizador de dois estágios do toggle de pedido do mestre A.
  signal a_s       : std_logic_vector(1 downto 0) := "00";
  -- Sincronizador de dois estágios do toggle de pedido do mestre I.
  signal ins_s       : std_logic_vector(1 downto 0) := "00";
  -- Toggle de confirmação do mestre A (registrado).
  signal a_ack_i   : std_logic := '0';
  -- Toggle de confirmação do mestre B (registrado).
  signal b_ack_i   : std_logic := '0';
  -- Toggle de confirmação do mestre I (registrado).
  signal ins_ack_i   : std_logic := '0';
  -- Toggle de pedido ao controlador (registrado).
  signal c_req_i   : std_logic := '0';
  -- O mestre em atendimento é o B.
  signal grant_b   : std_logic := '0';
  -- O mestre em atendimento é o I (com grant_b em '0': o A).
  signal grant_i   : std_logic := '0';
  -- O último mestre atendido foi o B.
  signal last_b    : std_logic := '0';
  -- O último mestre atendido foi o I (com last_b em '0': o A).
  signal last_i    : std_logic := '0';
  -- Valor do toggle de pedido do mestre A guardado ao aceitar o pedido.
  signal a_tog_l   : std_logic := '0';
  -- Valor do toggle de pedido do mestre I guardado ao aceitar o pedido.
  signal ins_tog_l   : std_logic := '0';
  -- O mestre A tem um pedido pendente.
  signal a_pend    : std_logic;
  -- O mestre B tem um pedido pendente.
  signal b_pend    : std_logic;
  -- O mestre I tem um pedido pendente.
  signal ins_pend    : std_logic;
  -- Dado lido entregue ao mestre I (registrado).
  signal ins_rdata_i : std_logic_vector(31 downto 0) := (others => '0');
  -- Palavras 1 a 3 lidas entregues ao mestre I (registradas).
  signal ins_rdx_i   : std_logic_vector(95 downto 0) := (others => '0');
  -- Dado lido entregue ao mestre A (registrado).
  signal a_rdata_i : std_logic_vector(31 downto 0) := (others => '0');
  -- Dado lido entregue ao mestre B (registrado).
  signal b_rdata_i : std_logic_vector(31 downto 0) := (others => '0');
  -- Palavras 1 a 3 lidas entregues ao mestre A (registradas).
  signal a_rdx_i   : std_logic_vector(95 downto 0) := (others => '0');

begin

  o_a_ack_tog <= a_ack_i;
  o_b_ack_tog <= b_ack_i;
  o_a_rdata   <= a_rdata_i;
  o_a_rdata_x <= a_rdx_i;
  o_b_rdata   <= b_rdata_i;
  o_ins_ack_tog <= ins_ack_i;
  o_ins_rdata   <= ins_rdata_i;
  o_ins_rdata_x <= ins_rdx_i;
  o_c_req_tog <= c_req_i;

  a_pend <= '1' when a_s(1) /= a_ack_i else '0';
  b_pend <= '1' when i_b_req_tog /= b_ack_i else '0';
  ins_pend <= '1' when ins_s(1) /= ins_ack_i else '0';

  process (i_clk)
    -- Mestre escolhido: 0 = A, 1 = B, 2 = I, 3 = nenhum.
    variable pick : integer range 0 to 3;
  begin
    if rising_edge(i_clk) then
      a_s <= a_s(0) & i_a_req_tog;
      ins_s <= ins_s(0) & i_ins_req_tog;

      if i_rst = '1' then
        st      <= ST_IDLE;
        a_s     <= "00";
        ins_s     <= "00";
        a_ack_i <= '0';
        b_ack_i <= '0';
        ins_ack_i <= '0';
        c_req_i <= '0';
        last_b  <= '0';
        last_i  <= '0';
      else
        case st is

          when ST_IDLE =>
            -- quem é o próximo: a ordem depois do mestre atendido por último
            -- último A: I, B, A    último I: B, A, I    último B: A, I, B
            pick := 3;
            if last_b = '1' then
              if a_pend = '1' then pick := 0; elsif ins_pend = '1' then pick := 2; elsif b_pend = '1' then pick := 1; end if;
            elsif last_i = '1' then
              if b_pend = '1' then pick := 1; elsif a_pend = '1' then pick := 0; elsif ins_pend = '1' then pick := 2; end if;
            else
              if ins_pend = '1' then pick := 2; elsif b_pend = '1' then pick := 1; elsif a_pend = '1' then pick := 0; end if;
            end if;
            if pick = 0 then
              o_c_we      <= i_a_we;
              o_c_addr    <= i_a_addr;
              o_c_wdata   <= i_a_wdata;
              o_c_be      <= i_a_be;
              o_c_line    <= i_a_line;
              o_c_wdata_x <= i_a_wdata_x;
              o_c_be_x    <= i_a_be_x;
              a_tog_l   <= a_s(1);
              grant_b   <= '0';
              grant_i   <= '0';
              c_req_i   <= not c_req_i;
              st        <= ST_BUSY;
            elsif pick = 2 then
              o_c_we      <= i_ins_we;
              o_c_addr    <= i_ins_addr;
              o_c_wdata   <= i_ins_wdata;
              o_c_be      <= i_ins_be;
              o_c_line    <= i_ins_line;
              o_c_wdata_x <= i_ins_wdata_x;
              o_c_be_x    <= i_ins_be_x;
              ins_tog_l   <= ins_s(1);
              grant_b   <= '0';
              grant_i   <= '1';
              c_req_i   <= not c_req_i;
              st        <= ST_BUSY;
            elsif pick = 1 then
              o_c_we      <= i_b_we;
              o_c_addr    <= i_b_addr;
              o_c_wdata   <= i_b_wdata;
              o_c_be      <= i_b_be;
              o_c_line    <= '0';
              o_c_wdata_x <= (others => '0');
              o_c_be_x    <= (others => '0');
              grant_b   <= '1';
              grant_i   <= '0';
              c_req_i   <= not c_req_i;
              st        <= ST_BUSY;
            end if;

          when ST_BUSY =>
            if i_c_ack_tog = c_req_i then
              if grant_b = '1' then
                b_rdata_i <= i_c_rdata;
                b_ack_i   <= i_b_req_tog;
              elsif grant_i = '1' then
                ins_rdata_i <= i_c_rdata;
                ins_rdx_i   <= i_c_rdata_x;
                ins_ack_i   <= ins_tog_l;
              else
                a_rdata_i <= i_c_rdata;
                a_rdx_i   <= i_c_rdata_x;
                a_ack_i   <= a_tog_l;
              end if;
              last_b <= grant_b;
              last_i <= grant_i;
              st     <= ST_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
