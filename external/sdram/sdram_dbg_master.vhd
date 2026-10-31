-- =============================================================================
-- Mestre de debug da SDRAM
--
-- Lê e escreve palavras da SDRAM em nome do hospedeiro, pelo árbitro, no clock
-- do controlador. Um comando é a inversão de cmd_tog (de qualquer clock,
-- sincronizada aqui) com op/be/addr/data estáveis da inversão até a resposta,
-- uma inversão de done_tog. O resultado (rsp_*) fica estável desde antes dessa
-- inversão até o próximo comando ser aceito.
--
-- Comandos (op):
--
--   0  nada
--   1  lê a palavra em addr
--   2  escreve data na palavra em addr, bytes por be
--   3  preenche count palavras a partir de addr com data (todos os bytes);
--      count vem do comando 4
--   4  define o count do comando 3 como data(24:0), até 2**24 palavras: a SDRAM inteira
--   5  lê a palavra seguinte à acessada por último
--   6  escreve data na palavra seguinte à acessada por último, bytes por be
--
-- rsp_addr é a última palavra acessada, rsp_data o que uma leitura devolveu e
-- rsp_status: bit 1 indica que o controlador não respondeu (o comando foi
-- descartado) e bit 2 que a SDRAM está inicializada.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_dbg_master is
  generic (
    -- Ciclos de espera pela resposta do controlador antes de descartar o comando.
    timeout_cycles : natural := 1 * 2**16
  );
  port (
    -- Clock do módulo.
    i_clk        : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst        : in  std_logic;

    -- Alternância que pede um comando: cada inversão é um comando novo.
    i_cmd_tog    : in  std_logic;
    -- Alternância que confirma o comando concluído.
    o_done_tog   : out std_logic;
    -- Código do comando de debug (0 a 6).
    i_op         : in  std_logic_vector(3 downto 0);
    -- Habilita de bytes das escritas.
    i_be         : in  std_logic_vector(3 downto 0);
    -- Endereço de palavra do comando.
    i_addr       : in  std_logic_vector(23 downto 0);
    -- Dado de escrita ou, no comando 4, a quantidade de palavras do preenchimento.
    i_data       : in  std_logic_vector(31 downto 0);
    -- Última palavra acessada.
    o_rsp_addr   : out std_logic_vector(23 downto 0);
    -- Dado devolvido pela última leitura.
    o_rsp_data   : out std_logic_vector(31 downto 0);
    -- Status do último comando: bit 1 sem resposta do controlador, bit 2 SDRAM inicializada.
    o_rsp_status : out std_logic_vector(7 downto 0);

    -- A inicialização da SDRAM terminou ('1').
    i_init_done  : in  std_logic;

    -- Porta do mestre B (porta de debug): alternância que pede um acesso, cada inversão é um pedido novo.
    o_b_req_tog  : out std_logic;
    -- Porta do mestre B (porta de debug): alternância que confirma o acesso, igual a req_tog quando o pedido foi atendido.
    i_b_ack_tog  : in  std_logic;
    -- Porta do mestre B (porta de debug): escrita ('1') ou leitura ('0').
    o_b_we       : out std_logic;
    -- Porta do mestre B (porta de debug): endereço de palavra.
    o_b_addr     : out std_logic_vector(23 downto 0);
    -- Porta do mestre B (porta de debug): dado de escrita.
    o_b_wdata    : out std_logic_vector(31 downto 0);
    -- Porta do mestre B (porta de debug): habilita de bytes da escrita.
    o_b_be       : out std_logic_vector(3 downto 0);
    -- Porta do mestre B (porta de debug): dado lido.
    i_b_rdata    : in  std_logic_vector(31 downto 0)
  );
end entity sdram_dbg_master;

architecture rtl of sdram_dbg_master is

  -- Estados do mestre: livre, esperando a resposta e avançando para a próxima palavra do preenchimento.
  type state_t is (ST_IDLE, ST_WAIT, ST_NEXT);
  -- Estado atual do mestre.
  signal st : state_t := ST_IDLE;

  -- Toggle de comando do hospedeiro, sincronizado com i_clk.
  signal cmd_sync : std_logic_vector(0 downto 0);
  -- Toggle de conclusão (registrado).
  signal done_i   : std_logic := '0';
  -- Toggle de pedido ao árbitro (registrado).
  signal req_i    : std_logic := '0';
  -- Há um comando novo pendente.
  signal pending  : std_logic;

  -- Comando em execução.
  signal op_l     : std_logic_vector(3 downto 0) := (others => '0');
  -- Habilita de bytes do comando em execução.
  signal be_l     : std_logic_vector(3 downto 0) := (others => '0');
  -- Dado do comando em execução.
  signal data_l   : std_logic_vector(31 downto 0) := (others => '0');
  -- Palavra sendo acessada.
  signal cur_addr : unsigned(23 downto 0) := (others => '0');
  -- Palavra acessada por último.
  signal last     : unsigned(23 downto 0) := (others => '0');
  -- Quantidade definida para o comando 3 (até 2**24).
  signal count    : unsigned(24 downto 0) := (others => '0');
  -- Palavras do preenchimento ainda por escrever.
  signal left     : unsigned(24 downto 0) := (others => '0');
  -- Contador de ciclos da espera pela resposta do controlador.
  signal wcnt     : natural range 0 to timeout_cycles := 0;
  -- O controlador não respondeu no prazo (registrado).
  signal err      : std_logic := '0';
  -- init_done do controlador, sincronizado com i_clk.
  signal init_sync : std_logic_vector(0 downto 0);
  -- Dado lido devolvido ao hospedeiro (registrado).
  signal rdata_i  : std_logic_vector(31 downto 0) := (others => '0');

begin

  -- Levam o toggle de comando e o init_done de outros clocks ao de i_clk.
  u_sync_cmd : entity work.synchronizer
    port map (
      i_clk  => i_clk,
      i_rst  => i_rst,
      i_d(0) => i_cmd_tog,
      o_d    => cmd_sync
    );

  u_sync_init : entity work.synchronizer
    port map (
      i_clk  => i_clk,
      i_rst  => i_rst,
      i_d(0) => i_init_done,
      o_d    => init_sync
    );

  o_done_tog   <= done_i;
  o_b_req_tog  <= req_i;
  o_rsp_addr   <= std_logic_vector(last);
  o_rsp_data   <= rdata_i;
  o_rsp_status <= "00000" & init_sync(0) & err & '0';
  pending    <= '1' when cmd_sync(0) /= done_i else '0';

  process (i_clk)
    procedure issue (a : unsigned(23 downto 0); we : std_logic; d : std_logic_vector(31 downto 0);
                     b : std_logic_vector(3 downto 0)) is
    begin
      o_b_addr  <= std_logic_vector(a);
      o_b_we    <= we;
      o_b_wdata <= d;
      o_b_be    <= b;
      cur_addr <= a;
      req_i   <= not req_i;
      wcnt    <= 0;
      st      <= ST_WAIT;
    end procedure;
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        st     <= ST_IDLE;
        done_i <= '0';
        req_i  <= '0';
        err    <= '0';
        last   <= (others => '0');
        count  <= to_unsigned(1, 25);
      else
        case st is

          when ST_IDLE =>
            if pending = '1' then
              -- os barramentos de comando estão estáveis desde a inversão de cmd_tog
              op_l   <= i_op;
              be_l   <= i_be;
              data_l <= i_data;
              err    <= '0';
              case i_op is
                when "0001" =>
                  issue(unsigned(i_addr), '0', (others => '0'), "1111");
                when "0010" =>
                  issue(unsigned(i_addr), '1', i_data, i_be);
                when "0011" =>
                  if count = 0 then
                    done_i <= cmd_sync(0);
                  else
                    left <= count - 1;
                    issue(unsigned(i_addr), '1', i_data, "1111");
                  end if;
                when "0100" =>
                  count  <= unsigned(i_data(24 downto 0));
                  done_i <= cmd_sync(0);
                when "0101" =>
                  issue(last + 1, '0', (others => '0'), "1111");
                when "0110" =>
                  issue(last + 1, '1', i_data, i_be);
                when others =>
                  done_i <= cmd_sync(0);
              end case;
            end if;

          when ST_WAIT =>
            if i_b_ack_tog = req_i then
              last    <= cur_addr;
              rdata_i <= i_b_rdata;
              st      <= ST_NEXT;
            elsif wcnt = timeout_cycles then
              err    <= '1';
              done_i <= cmd_sync(0);
              st     <= ST_IDLE;
            else
              wcnt <= wcnt + 1;
            end if;

          when ST_NEXT =>
            if op_l = "0011" and left /= 0 then
              left <= left - 1;
              issue(cur_addr + 1, '1', data_l, "1111");
            else
              done_i <= cmd_sync(0);
              st     <= ST_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
