-- =============================================================================
-- Ponte entre o core (i_clk_cpu) e o controlador da SDRAM (outro clock)
--
-- Lado do core: o acesso fica em addr/wdata/byteena/rden/wren enquanto o estágio
-- de memória está parado. ready sobe quando o acesso termina e permanece em nível
-- alto até mem_advance indicar que o pipeline andou. O dado lido (rdata) só muda
-- nessa mesma borda, porque o load que ainda está no estágio de write-back lê o
-- valor anterior até lá.
--
-- Um acesso de linha (line = '1' com rden ou wren) move as quatro palavras que
-- começam em addr (alinhado em 16 bytes): a palavra 0 em wdata/byteena/rdata,
-- como numa palavra, e as palavras 1 a 3 em wdata_x/byteena_x/rdata_x (32 bits
-- cada, a palavra 1 nos bits mais baixos). As mesmas regras valem para as
-- palavras extras.
--
-- Lado do controlador: um pedido é a inversão de req_tog com a palavra em
-- c_we/c_addr/c_wdata/c_be; o controlador responde invertendo ack_tog. ack_tog
-- e init_done vêm do clock do controlador e são sincronizados aqui com dois
-- flip-flops. Os barramentos de pedido mudam na mesma borda que inverte req_tog
-- e ficam estáveis até ack_tog inverter; o controlador só os amostra depois de
-- ver a inversão, então precisam de uma restrição de atraso apenas no caminho de
-- dados (menor que a latência do sincronizador), não de sincronizadores.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_cpu_bridge is
  port (
    -- Clock do lado do core.
    i_clk_cpu     : in  std_logic;
    -- Reset do lado do core, ativo em '1'.
    i_rst_cpu     : in  std_logic;

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

    -- Alternância que pede um acesso ao controlador: cada inversão é um pedido novo.
    o_req_tog     : out std_logic;
    -- Alternância do controlador que confirma o acesso (sincronizada aqui).
    i_ack_tog     : in  std_logic;
    -- A inicialização da SDRAM terminou ('1').
    i_init_done   : in  std_logic;
    -- Porta do controlador SDRAM: escrita ('1') ou leitura ('0').
    o_c_we        : out std_logic;
    -- Porta do controlador SDRAM: endereço de palavra.
    o_c_addr      : out std_logic_vector(23 downto 0);
    -- Porta do controlador SDRAM: dado de escrita.
    o_c_wdata     : out std_logic_vector(31 downto 0);
    -- Porta do controlador SDRAM: habilita de bytes da escrita.
    o_c_be        : out std_logic_vector(3 downto 0);
    -- Porta do controlador SDRAM: dado lido.
    i_c_rdata     : in  std_logic_vector(31 downto 0);
    -- Porta do controlador SDRAM: acesso de linha de quatro palavras ('1').
    o_c_line      : out std_logic;
    -- Porta do controlador SDRAM: palavras 1 a 3 do dado de escrita da linha.
    o_c_wdata_x   : out std_logic_vector(95 downto 0);
    -- Porta do controlador SDRAM: habilita de bytes das palavras 1 a 3.
    o_c_be_x      : out std_logic_vector(11 downto 0);
    -- Porta do controlador SDRAM: palavras 1 a 3 do dado lido da linha.
    i_c_rdata_x   : in  std_logic_vector(95 downto 0)
  );
end entity sdram_cpu_bridge;

architecture rtl of sdram_cpu_bridge is

  -- Estados da ponte: livre, esperando o controlador e acesso concluído aguardando o avanço do pipeline.
  type state_t is (ST_IDLE, ST_WAIT, ST_DONE);
  -- Estado atual da ponte.
  signal st : state_t := ST_IDLE;

  -- Toggle de pedido ao controlador (registrado).
  signal req_i       : std_logic := '0';
  -- Sincronizador de dois estágios do toggle de confirmação.
  signal ack_s       : std_logic_vector(1 downto 0) := "00";
  -- Sincronizador de dois estágios de init_done.
  signal init_s      : std_logic_vector(1 downto 0) := "00";
  -- O acesso em andamento é uma escrita.
  signal we_l        : std_logic := '0';
  -- Palavra 0 do dado lido, à espera do avanço do pipeline.
  signal pending     : std_logic_vector(31 downto 0) := (others => '0');
  -- Palavra 0 do dado lido entregue ao core.
  signal rdata_q     : std_logic_vector(31 downto 0) := (others => '0');
  -- Palavras 1 a 3 do dado lido, à espera do avanço do pipeline.
  signal pending_x   : std_logic_vector(95 downto 0) := (others => '0');
  -- Palavras 1 a 3 do dado lido entregues ao core.
  signal rdx_q       : std_logic_vector(95 downto 0) := (others => '0');
  -- O acesso em andamento é de linha.
  signal line_l      : std_logic := '0';

begin

  o_req_tog <= req_i;
  o_c_we    <= we_l;
  o_ready   <= '1' when st = ST_DONE else '0';
  o_rdata   <= rdata_q;
  o_rdata_x <= rdx_q;
  o_c_line  <= line_l;

  process (i_clk_cpu)
  begin
    if rising_edge(i_clk_cpu) then
      ack_s  <= ack_s(0) & i_ack_tog;
      init_s <= init_s(0) & i_init_done;

      if i_rst_cpu = '1' then
        st      <= ST_IDLE;
        req_i   <= '0';
        ack_s   <= "00";
        init_s  <= "00";
        we_l    <= '0';
      else
        case st is

          when ST_IDLE =>
            if (i_rden = '1' or i_wren = '1') and init_s(1) = '1' then
              o_c_addr  <= i_addr(25 downto 2);
              o_c_wdata <= i_wdata;
              o_c_be    <= i_byteena;
              line_l    <= i_line;
              o_c_wdata_x <= i_wdata_x;
              o_c_be_x    <= i_byteena_x;
              we_l    <= i_wren;
              req_i   <= not req_i;
              st      <= ST_WAIT;
            end if;

          when ST_WAIT =>
            if ack_s(1) = req_i then
              pending   <= i_c_rdata;
              pending_x <= i_c_rdata_x;
              st        <= ST_DONE;
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
