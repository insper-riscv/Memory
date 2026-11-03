-- =============================================================================
-- Escravo AXI4 na frente de uma memória com o contrato de palavra do core
--
-- A memória segue o contrato da sdram_cpu_bridge (ou de qualquer memória com as
-- mesmas regras de ready e mem_advance), com a extensão de linha desse contrato.
--
-- Rajadas atendidas (INCR, beats de 4 bytes, alinhadas em 4 bytes, uma transação
-- por vez):
--
--   rajada de quatro beats alinhada em 16 bytes  um acesso de linha da memória (o caminho rápido)
--   qualquer outro comprimento                   um acesso de palavra por beat, em ordem
--
-- Qualquer outra coisa (tamanho diferente de 4 bytes, tipo de rajada diferente de
-- INCR, endereço não alinhado em 4 bytes) é respondida com SLVERR depois de todos
-- os seus beats serem consumidos, e nada chega à memória. Os IDs não são
-- carregados (largura 0).
--
-- AW é aceito primeiro e os beats de W seguem; uma leitura espera enquanto uma
-- escrita está em andamento, e uma escrita oferecida ao mesmo tempo passa na
-- frente. O acesso fica na porta de palavra até ready; mem_advance é um pulso
-- então, porque nada mais está parado. A resposta espera bready e os beats de R
-- esperam rready; nenhum pedido é aceito antes de a resposta inteira ser
-- tomada.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_slave_word_bridge is
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

    -- Endereço do acesso.
    o_addr        : out std_logic_vector(31 downto 0);
    -- Dado de escrita.
    o_wdata       : out std_logic_vector(31 downto 0);
    -- Habilita de bytes da escrita, um bit por byte.
    o_byteena     : out std_logic_vector(3 downto 0);
    -- Pedido de leitura ('1' = lê).
    o_rden        : out std_logic;
    -- Pedido de escrita ('1' = escreve).
    o_wren        : out std_logic;
    -- O pipeline avançou neste ciclo, o acesso em andamento pode ser concluído.
    o_mem_advance : out std_logic;
    -- Acesso concluído, o dado lido é válido ('1').
    i_ready       : in  std_logic;
    -- Dado lido.
    i_rdata       : in  std_logic_vector(31 downto 0);
    -- Acesso de linha, quatro palavras seguidas ('1').
    o_line        : out std_logic;
    -- Palavras 1 a 3 do dado de escrita da linha.
    o_wdata_x     : out std_logic_vector(95 downto 0);
    -- Habilita de bytes das palavras 1 a 3 da linha.
    o_byteena_x   : out std_logic_vector(11 downto 0);
    -- Palavras 1 a 3 do dado lido da linha.
    i_rdata_x     : in  std_logic_vector(95 downto 0)
  );
end entity axi_slave_word_bridge;

architecture rtl of axi_slave_word_bridge is

  -- Estados da ponte: livre, beat de escrita, acesso à memória, avanço, beat de leitura e resposta de escrita.
  type state_t is (ST_IDLE, ST_WBEAT, ST_ACC, ST_ADV, ST_RBEAT, ST_BRESP);
  -- Estado atual da ponte.
  signal st      : state_t := ST_IDLE;

  -- A transação em andamento é uma escrita.
  signal we_l    : std_logic := '0';
  -- A rajada não é uma que esta ponte atende.
  signal bad_l   : std_logic := '0';
  -- A transação é um acesso de linha.
  signal fast_l  : std_logic := '0';
  -- Endereço da transação.
  signal addr_l  : std_logic_vector(31 downto 0) := (others => '0');
  -- Beats ainda por mover, menos um.
  signal left_l  : unsigned(7 downto 0) := (others => '0');
  -- Palavra da linha sendo guardada ou enviada.
  signal k       : natural range 0 to 3 := 0;
  -- Dado de escrita da palavra 0.
  signal wdata_l : std_logic_vector(31 downto 0) := (others => '0');
  -- Habilita de bytes da palavra 0.
  signal strb_l  : std_logic_vector(3 downto 0) := (others => '0');
  -- Palavras 1 a 3 de escrita da linha.
  signal wdx_l   : std_logic_vector(95 downto 0) := (others => '0');
  -- Habilita de bytes das palavras 1 a 3.
  signal bex_l   : std_logic_vector(11 downto 0) := (others => '0');
  -- A transação será respondida com SLVERR.
  signal err_l   : std_logic := '0';

  -- A ponte aceita o endereço de escrita neste ciclo.
  signal awr : std_logic;
  -- A ponte aceita o endereço de leitura neste ciclo.
  signal arr : std_logic;

  function is_bad (a : std_logic_vector(31 downto 0); size : std_logic_vector(2 downto 0);
                   burst : std_logic_vector(1 downto 0)) return std_logic is
  begin
    if size /= "010" or burst /= "01" or a(1 downto 0) /= "00" then
      return '1';
    end if;
    return '0';
  end function;

  function is_line (a : std_logic_vector(31 downto 0); len : std_logic_vector(7 downto 0)) return std_logic is
  begin
    if len = "00000011" and a(3 downto 0) = "0000" then
      return '1';
    end if;
    return '0';
  end function;

begin

  awr <= '1' when st = ST_IDLE else '0';
  arr <= '1' when st = ST_IDLE and i_s_awvalid = '0' else '0';
  o_s_awready <= awr;
  o_s_arready <= arr;
  o_s_wready  <= '1' when st = ST_WBEAT else '0';

  o_addr        <= addr_l;
  o_wdata       <= wdata_l;
  o_byteena     <= strb_l;
  o_wdata_x     <= wdx_l;
  o_byteena_x   <= bex_l;
  o_line        <= fast_l;
  o_rden        <= '1' when (st = ST_ACC or st = ST_ADV) and we_l = '0' else '0';
  o_wren        <= '1' when (st = ST_ACC or st = ST_ADV) and we_l = '1' else '0';
  o_mem_advance <= '1' when st = ST_ADV else '0';

  o_s_bvalid <= '1' when st = ST_BRESP else '0';
  o_s_bresp  <= "10" when err_l = '1' else "00";

  o_s_rvalid <= '1' when st = ST_RBEAT else '0';
  o_s_rresp  <= "10" when bad_l = '1' else "00";
  o_s_rlast  <= '1' when st = ST_RBEAT and ((fast_l = '1' and k = 3) or (fast_l = '0' and left_l = 0)) else '0';
  -- o dado lido da memória só muda no seu próprio mem_advance, então fica válido enquanto um beat espera
  o_s_rdata  <= x"00000000" when bad_l = '1' else
              i_rdata when (fast_l = '0' or k = 0) else
              i_rdata_x(31 downto 0)  when k = 1 else
              i_rdata_x(63 downto 32) when k = 2 else
              i_rdata_x(95 downto 64);

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        st    <= ST_IDLE;
        we_l  <= '0';
        bad_l <= '0';
        fast_l <= '0';
        err_l <= '0';
        k     <= 0;
      else
        case st is

          when ST_IDLE =>
            if i_s_awvalid = '1' then
              addr_l <= i_s_awaddr;
              left_l <= unsigned(i_s_awlen);
              we_l   <= '1';
              bad_l  <= is_bad(i_s_awaddr, i_s_awsize, i_s_awburst);
              if is_bad(i_s_awaddr, i_s_awsize, i_s_awburst) = '0' and is_line(i_s_awaddr, i_s_awlen) = '1' then
                fast_l <= '1';
              else
                fast_l <= '0';
              end if;
              err_l  <= is_bad(i_s_awaddr, i_s_awsize, i_s_awburst);
              k      <= 0;
              st     <= ST_WBEAT;
            elsif i_s_arvalid = '1' then
              addr_l <= i_s_araddr;
              left_l <= unsigned(i_s_arlen);
              we_l   <= '0';
              bad_l  <= is_bad(i_s_araddr, i_s_arsize, i_s_arburst);
              if is_bad(i_s_araddr, i_s_arsize, i_s_arburst) = '0' and is_line(i_s_araddr, i_s_arlen) = '1' then
                fast_l <= '1';
              else
                fast_l <= '0';
              end if;
              k      <= 0;
              if is_bad(i_s_araddr, i_s_arsize, i_s_arburst) = '1' then
                st <= ST_RBEAT;          -- os beats de erro não precisam de acesso
              else
                st <= ST_ACC;
              end if;
            end if;

          when ST_WBEAT =>
            if i_s_wvalid = '1' then
              if bad_l = '1' then
                -- consome os beats; nada chega à memória
                if i_s_wlast = '1' then
                  st <= ST_BRESP;
                end if;
              elsif fast_l = '1' then
                if k = 0 then
                  wdata_l <= i_s_wdata;
                  strb_l  <= i_s_wstrb;
                elsif k = 1 then
                  wdx_l(31 downto 0)  <= i_s_wdata;
                  bex_l(3 downto 0)   <= i_s_wstrb;
                elsif k = 2 then
                  wdx_l(63 downto 32) <= i_s_wdata;
                  bex_l(7 downto 4)   <= i_s_wstrb;
                else
                  wdx_l(95 downto 64) <= i_s_wdata;
                  bex_l(11 downto 8)  <= i_s_wstrb;
                end if;
                if k = 3 then
                  k  <= 0;
                  st <= ST_ACC;
                else
                  k <= k + 1;
                end if;
              else
                wdata_l <= i_s_wdata;
                strb_l  <= i_s_wstrb;
                st      <= ST_ACC;
              end if;
            end if;

          when ST_ACC =>
            if i_ready = '1' then
              st <= ST_ADV;
            end if;

          when ST_ADV =>
            if we_l = '1' then
              if fast_l = '1' or left_l = 0 then
                st <= ST_BRESP;
              else
                left_l <= left_l - 1;
                addr_l <= std_logic_vector(unsigned(addr_l) + 4);
                st     <= ST_WBEAT;
              end if;
            else
              st <= ST_RBEAT;
            end if;

          when ST_RBEAT =>
            if i_s_rready = '1' then
              if (fast_l = '1' and k = 3) or (fast_l = '0' and left_l = 0) then
                st <= ST_IDLE;
                k  <= 0;
              elsif fast_l = '1' then
                k <= k + 1;
              else
                left_l <= left_l - 1;
                addr_l <= std_logic_vector(unsigned(addr_l) + 4);
                if bad_l = '0' then
                  st <= ST_ACC;
                end if;                    -- um beat de erro: o seguinte é oferecido no próximo clock
              end if;
            end if;

          when ST_BRESP =>
            if i_s_bready = '1' then
              st <= ST_IDLE;
              k  <= 0;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
