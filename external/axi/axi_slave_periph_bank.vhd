-- =============================================================================
-- Escravo AXI4 na frente da janela de periféricos do ext_interconnect
--
-- Oito periféricos, cada um com uma janela de 256 palavras, selecionados pelos
-- bits 30:28 do endereço, a palavra dentro dele pelos bits 9:2. O lado do
-- periférico é o que o ext_interconnect dá: p_we ou p_re do periférico
-- selecionado é um pulso de um clock por acesso, com p_addr, p_wdata e p_byteena
-- ao lado, e o dado lido do periférico (p_rdata, 32 bits por slot, o slot i nos
-- bits 32 i + 31 a 32 i) é lido no clock desse pulso. Uma leitura de uma janela
-- que ninguém responde devolve 0 e uma escrita não tem efeito; ambas completam
-- como qualquer outra, com OKAY.
--
-- Periféricos não são memória: só um único beat de 4 bytes (len 0, size de 4
-- bytes, INCR, alinhado) é atendido. Qualquer outra transação é respondida com
-- SLVERR depois de todos os seus beats serem consumidos (escrita) ou dados como
-- zeros (leitura), e nenhum periférico é tocado. Os IDs não são carregados
-- (largura 0). Como no axi_slave_word_bridge: AW primeiro e depois os beats de W,
-- uma leitura cede a uma escrita oferecida, uma transação por vez, e a resposta
-- espera bready ou rready.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_slave_periph_bank is
  port (
    -- Clock do módulo.
    i_clk         : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst         : in  std_logic;

    -- Porta escravo AXI4, canal de endereço de escrita: validade da transferência ('1' = válida).
    i_s_awvalid   : in  std_logic;
    -- Porta escravo AXI4, canal de endereço de escrita: destino pronto para aceitar a transferência ('1').
    o_s_awready   : out std_logic;
    -- Porta escravo AXI4, canal de endereço de escrita: endereço do primeiro beat.
    i_s_awaddr    : in  std_logic_vector(31 downto 0);
    -- Porta escravo AXI4, canal de endereço de escrita: número de beats da rajada menos um.
    i_s_awlen     : in  std_logic_vector(7 downto 0);
    -- Porta escravo AXI4, canal de endereço de escrita: log2 do número de bytes por beat.
    i_s_awsize    : in  std_logic_vector(2 downto 0);
    -- Porta escravo AXI4, canal de endereço de escrita: tipo de rajada (1 = INCR).
    i_s_awburst   : in  std_logic_vector(1 downto 0);
    -- Porta escravo AXI4, canal de dados de escrita: validade da transferência ('1' = válida).
    i_s_wvalid    : in  std_logic;
    -- Porta escravo AXI4, canal de dados de escrita: destino pronto para aceitar a transferência ('1').
    o_s_wready    : out std_logic;
    -- Porta escravo AXI4, canal de dados de escrita: dados.
    i_s_wdata     : in  std_logic_vector(31 downto 0);
    -- Porta escravo AXI4, canal de dados de escrita: habilita de bytes.
    i_s_wstrb     : in  std_logic_vector(3 downto 0);
    -- Porta escravo AXI4, canal de dados de escrita: último beat da rajada ('1').
    i_s_wlast     : in  std_logic;
    -- Porta escravo AXI4, canal de resposta de escrita: validade da transferência ('1' = válida).
    o_s_bvalid    : out std_logic;
    -- Porta escravo AXI4, canal de resposta de escrita: destino pronto para aceitar a transferência ('1').
    i_s_bready    : in  std_logic;
    -- Porta escravo AXI4, canal de resposta de escrita: resposta (0 = OKAY, 2 = SLVERR).
    o_s_bresp     : out std_logic_vector(1 downto 0);
    -- Porta escravo AXI4, canal de endereço de leitura: validade da transferência ('1' = válida).
    i_s_arvalid   : in  std_logic;
    -- Porta escravo AXI4, canal de endereço de leitura: destino pronto para aceitar a transferência ('1').
    o_s_arready   : out std_logic;
    -- Porta escravo AXI4, canal de endereço de leitura: endereço do primeiro beat.
    i_s_araddr    : in  std_logic_vector(31 downto 0);
    -- Porta escravo AXI4, canal de endereço de leitura: número de beats da rajada menos um.
    i_s_arlen     : in  std_logic_vector(7 downto 0);
    -- Porta escravo AXI4, canal de endereço de leitura: log2 do número de bytes por beat.
    i_s_arsize    : in  std_logic_vector(2 downto 0);
    -- Porta escravo AXI4, canal de endereço de leitura: tipo de rajada (1 = INCR).
    i_s_arburst   : in  std_logic_vector(1 downto 0);
    -- Porta escravo AXI4, canal de dados de leitura: validade da transferência ('1' = válida).
    o_s_rvalid    : out std_logic;
    -- Porta escravo AXI4, canal de dados de leitura: destino pronto para aceitar a transferência ('1').
    i_s_rready    : in  std_logic;
    -- Porta escravo AXI4, canal de dados de leitura: dados.
    o_s_rdata     : out std_logic_vector(31 downto 0);
    -- Porta escravo AXI4, canal de dados de leitura: resposta (0 = OKAY, 2 = SLVERR).
    o_s_rresp     : out std_logic_vector(1 downto 0);
    -- Porta escravo AXI4, canal de dados de leitura: último beat da rajada ('1').
    o_s_rlast     : out std_logic;

    -- Janela de periféricos: deslocamento de palavra dentro do periférico.
    o_p_addr      : out std_logic_vector(7 downto 0);
    -- Janela de periféricos: dado de escrita.
    o_p_wdata     : out std_logic_vector(31 downto 0);
    -- Janela de periféricos: habilita de bytes da escrita.
    o_p_byteena   : out std_logic_vector(3 downto 0);
    -- Janela de periféricos: pulso de escrita, um bit por periférico (one-hot com o id).
    o_p_we        : out std_logic_vector(7 downto 0);
    -- Janela de periféricos: pulso de leitura, um bit por periférico (one-hot com o id).
    o_p_re        : out std_logic_vector(7 downto 0);
    -- Janela de periféricos: dados lidos, 32 bits por periférico.
    i_p_rdata     : in  std_logic_vector(8 * 32 - 1 downto 0)
  );
end entity axi_slave_periph_bank;

architecture rtl of axi_slave_periph_bank is

  -- Estados do banco: livre, beat de escrita, pulso no periférico, resposta e descarte da leitura.
  type state_t is (ST_IDLE, ST_WBEAT, ST_PULSE, ST_RESP, ST_RDROP);
  -- Estado atual do banco.
  signal st      : state_t := ST_IDLE;

  -- A transação em andamento é uma escrita.
  signal we_l    : std_logic := '0';
  -- A transação não é um único beat de 4 bytes.
  signal bad_l   : std_logic := '0';
  -- Endereço da transação.
  signal addr_l  : std_logic_vector(31 downto 0) := (others => '0');
  -- Dado de escrita.
  signal wdata_l : std_logic_vector(31 downto 0) := (others => '0');
  -- Habilita de bytes da escrita.
  signal strb_l  : std_logic_vector(3 downto 0) := (others => '0');
  -- Dado lido do periférico, à espera de ser entregue.
  signal rd_q    : std_logic_vector(31 downto 0) := (others => '0');
  -- Beats ainda por consumir ou dar, menos um.
  signal left_l  : unsigned(7 downto 0) := (others => '0');

  -- Periférico selecionado, bits 30:28 do endereço.
  signal id : integer range 0 to 7;

  function is_bad (a : std_logic_vector(31 downto 0); len : std_logic_vector(7 downto 0);
                   size : std_logic_vector(2 downto 0); burst : std_logic_vector(1 downto 0)) return std_logic is
  begin
    if len /= "00000000" or size /= "010" or burst /= "01" or a(1 downto 0) /= "00" then
      return '1';
    end if;
    return '0';
  end function;

begin

  o_s_awready <= '1' when st = ST_IDLE else '0';
  o_s_arready <= '1' when st = ST_IDLE and i_s_awvalid = '0' else '0';
  o_s_wready  <= '1' when st = ST_WBEAT else '0';

  id        <= to_integer(unsigned(addr_l(30 downto 28)));
  o_p_addr    <= addr_l(9 downto 2);
  o_p_wdata   <= wdata_l;
  o_p_byteena <= strb_l;

  process (st, id, we_l)
  begin
    o_p_we <= (others => '0');
    o_p_re <= (others => '0');
    if st = ST_PULSE then
      o_p_we(id) <= we_l;
      o_p_re(id) <= not we_l;
    end if;
  end process;

  o_s_bvalid <= '1' when st = ST_RESP and we_l = '1' else '0';
  o_s_bresp  <= "10" when bad_l = '1' else "00";
  o_s_rvalid <= '1' when (st = ST_RESP and we_l = '0') or st = ST_RDROP else '0';
  o_s_rresp  <= "10" when bad_l = '1' else "00";
  o_s_rdata  <= rd_q when bad_l = '0' else x"00000000";
  o_s_rlast  <= '1' when (st = ST_RESP and we_l = '0') or (st = ST_RDROP and left_l = 0) else '0';

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        st    <= ST_IDLE;
        we_l  <= '0';
        bad_l <= '0';
        rd_q  <= (others => '0');
      else
        case st is

          when ST_IDLE =>
            if i_s_awvalid = '1' then
              addr_l <= i_s_awaddr;
              we_l   <= '1';
              bad_l  <= is_bad(i_s_awaddr, i_s_awlen, i_s_awsize, i_s_awburst);
              st     <= ST_WBEAT;
            elsif i_s_arvalid = '1' then
              addr_l <= i_s_araddr;
              we_l   <= '0';
              left_l <= unsigned(i_s_arlen);
              bad_l  <= is_bad(i_s_araddr, i_s_arlen, i_s_arsize, i_s_arburst);
              if is_bad(i_s_araddr, i_s_arlen, i_s_arsize, i_s_arburst) = '1' then
                st <= ST_RDROP;
              else
                strb_l <= "1111";
                st     <= ST_PULSE;
              end if;
            end if;

          when ST_WBEAT =>
            if i_s_wvalid = '1' then
              if bad_l = '1' then
                if i_s_wlast = '1' then
                  st <= ST_RESP;
                end if;
              else
                wdata_l <= i_s_wdata;
                strb_l  <= i_s_wstrb;
                st      <= ST_PULSE;
              end if;
            end if;

          when ST_PULSE =>
            rd_q <= i_p_rdata(32 * id + 31 downto 32 * id);
            st   <= ST_RESP;

          when ST_RESP =>
            if (we_l = '1' and i_s_bready = '1') or (we_l = '0' and i_s_rready = '1') then
              st <= ST_IDLE;
            end if;

          when ST_RDROP =>
            if i_s_rready = '1' then
              if left_l = 0 then
                st <= ST_IDLE;
              else
                left_l <= left_l - 1;
              end if;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
