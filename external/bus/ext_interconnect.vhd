-- =============================================================================
-- Decodificador atrás da porta de dados externa do core
--
-- Todo acesso em 0x40000000 ou acima chega aqui; ele o envia a um entre dois
-- tipos de escravo e devolve ao core o ready e o dado desse escravo:
--
--   bit 31 = 0   uma memória com ready próprio (a ponte da SDRAM): a porta passa
--                direto, com os pulsos de leitura e escrita retidos enquanto outro
--                escravo está selecionado
--   bit 31 = 1   uma janela de periféricos: os bits 30:28 são o id do periférico
--                e os bits 9:2 o deslocamento de palavra dentro dele
--
-- Um acesso a periférico leva um ciclo do core: um único pulso de we ou re
-- (mesmo enquanto o core espera outra coisa), com ready em nível até mem_advance,
-- como o contrato do core pede. Uma leitura de uma janela que ninguém responde
-- devolve 0 e uma escrita não tem efeito; ambas completam como qualquer outra. O
-- dado lido de um load fica em rdata até o próximo load completar, e a escolha de
-- qual escravo o forneceu é registrada quando o load completa, de modo que um
-- load ainda no último estágio vê o seu próprio dado enquanto o acesso seguinte
-- já está na porta. O periférico i responde no slot i: p_we e p_re são one-hot
-- com o id e p_rdata guarda 32 bits por slot, o slot i nos bits 32 i + 31 a 32 i.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ext_interconnect is
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

    -- Lado da memória com ready próprio: endereço do acesso.
    o_m_addr      : out std_logic_vector(31 downto 0);
    -- Lado da memória com ready próprio: dado de escrita.
    o_m_wdata     : out std_logic_vector(31 downto 0);
    -- Lado da memória com ready próprio: habilita de bytes da escrita.
    o_m_byteena   : out std_logic_vector(3 downto 0);
    -- Lado da memória com ready próprio: pedido de leitura, retido enquanto outro escravo está selecionado.
    o_m_rden      : out std_logic;
    -- Lado da memória com ready próprio: pedido de escrita, retido enquanto outro escravo está selecionado.
    o_m_wren      : out std_logic;
    -- Lado da memória com ready próprio: acesso concluído ('1').
    i_m_ready     : in  std_logic;
    -- Lado da memória com ready próprio: dado lido.
    i_m_rdata     : in  std_logic_vector(31 downto 0);

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
    -- Janela de periféricos: dados lidos, 32 bits por periférico (o do id i nos bits 32 i + 31 a 32 i).
    i_p_rdata     : in  std_logic_vector(8 * 32 - 1 downto 0)
  );
end entity ext_interconnect;

architecture rtl of ext_interconnect is

  -- Estados do decodificador: livre e acesso a periférico concluído aguardando o avanço do pipeline.
  type state_t is (ST_IDLE, ST_DONE);
  -- Estado atual do decodificador.
  signal st        : state_t := ST_IDLE;
  -- O endereço do acesso pertence à janela de periféricos.
  signal is_periph : std_logic;
  -- Há um acesso em andamento.
  signal active    : std_logic;
  -- Identificador do periférico, bits 30:28 do endereço.
  signal id        : integer range 0 to 7;
  -- '1': o último load veio de um periférico.
  signal sel_wb    : std_logic := '0';
  -- Dado lido do periférico, registrado.
  signal p_rdata_q : std_logic_vector(31 downto 0) := (others => '0');
  -- Dado do load aguardando o avanço do pipeline.
  signal pending   : std_logic_vector(31 downto 0) := (others => '0');
  -- Pulso de leitura ou escrita do periférico neste ciclo.
  signal pulse     : std_logic;

begin

  is_periph <= i_addr(31);
  active    <= i_rden or i_wren;
  id        <= to_integer(unsigned(i_addr(30 downto 28)));

  o_m_addr    <= i_addr;
  o_m_wdata   <= i_wdata;
  o_m_byteena <= i_byteena;
  o_m_rden    <= i_rden and not is_periph;
  o_m_wren    <= i_wren and not is_periph;

  o_p_addr    <= i_addr(9 downto 2);
  o_p_wdata   <= i_wdata;
  o_p_byteena <= i_byteena;

  pulse <= '1' when st = ST_IDLE and is_periph = '1' and active = '1' else '0';
  process (pulse, id, i_rden, i_wren)
  begin
    o_p_we <= (others => '0');
    o_p_re <= (others => '0');
    if pulse = '1' then
      o_p_we(id) <= i_wren;
      o_p_re(id) <= i_rden;
    end if;
  end process;

  o_ready <= (i_m_ready) when is_periph = '0' else
           '1' when st = ST_DONE else '0';
  o_rdata <= p_rdata_q when sel_wb = '1' else i_m_rdata;

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        st        <= ST_IDLE;
        sel_wb    <= '0';
        p_rdata_q <= (others => '0');
        pending   <= (others => '0');
      else
        case st is
          when ST_IDLE =>
            if is_periph = '1' and active = '1' then
              pending <= i_p_rdata(32 * id + 31 downto 32 * id);
              st      <= ST_DONE;
            end if;
          when ST_DONE =>
            if i_mem_advance = '1' then
              if i_rden = '1' then
                p_rdata_q <= pending;
                sel_wb    <= '1';
              end if;
              st <= ST_IDLE;
            end if;
        end case;
        -- um acesso à memória que completa devolve o dado à memória
        if is_periph = '0' and i_rden = '1' and i_m_ready = '1' and i_mem_advance = '1' then
          sel_wb <= '0';
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
