-- =============================================================================
-- Modelo de chip de FLASH com latência configurável
--
-- Atende pedidos de linha (quatro palavras) ou de palavra com o mesmo contrato
-- que a ponte da SDRAM dá ao core: o pedido fica em i_addr, i_rden e i_line até
-- o_ready subir; o_ready permanece em nível alto até i_advance indicar que o
-- pedido foi consumido, e o dado lido só muda no pedido seguinte.
--
-- O armazenamento não está aqui. A entidade comanda uma memória de leitura
-- registrada (a RAM de bloco da FPGA que a ferramenta de carga regrava por JTAG,
-- ou o modelo de simulação): o_mem_addr sai de um registrador e i_mem_data traz a
-- palavra uma borda depois. Trocar o conteúdo ou o chip não muda esta entidade.
--
-- Latência, contada em bordas de i_clk a partir da borda em que o pedido é visto:
--   - first_latency: até a primeira palavra estar capturada;
--   - next_latency: entre uma palavra e a seguinte da mesma linha.
-- Os dois valem pelo menos 2, porque o endereço é registrado numa borda e a
-- memória só responde na seguinte.
--
-- Uma linha começa no endereço alinhado em 16 bytes que contém i_addr; um pedido
-- de palavra (i_line = '0') devolve só a palavra de i_addr em o_rdata. Stores não
-- chegam aqui: a FLASH ignora escritas do core.
--
-- Janela: o chip ocupa 2^window_bits bytes. Um pedido cujos bits 25:window_bits
-- não são todos zero está fora da janela e captura zero em todas as palavras, sem
-- que o armazenamento importe.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity flash_chip is
  generic (
    -- Bordas até a primeira palavra do pedido estar capturada (mínimo 2).
    first_latency : natural := 24;
    -- Bordas entre duas palavras seguidas da mesma linha (mínimo 2).
    next_latency  : natural := 4;
    -- Tamanho da janela do chip, em bits de endereço (20 = 1 MB).
    window_bits   : natural := 20
  );
  port (
    -- Clock do módulo.
    i_clk       : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst       : in  std_logic;

    -- Endereço do pedido.
    i_addr      : in  std_logic_vector(31 downto 0);
    -- Pedido de leitura ('1' = lê).
    i_rden      : in  std_logic;
    -- Pedido de linha de quatro palavras ('1') ou de uma palavra ('0').
    i_line      : in  std_logic;
    -- O pedido foi consumido neste ciclo, o chip pode aceitar outro.
    i_advance   : in  std_logic;
    -- Pedido concluído, o dado lido é válido ('1').
    o_ready     : out std_logic;
    -- O chip está esperando a palavra de um pedido ('1' em cada ciclo de latência).
    o_busy      : out std_logic;
    -- Palavra pedida (a palavra 0 da linha).
    o_rdata     : out std_logic_vector(31 downto 0);
    -- Palavras 1 a 3 da linha, a palavra 1 nos bits mais baixos.
    o_rdata_x   : out std_logic_vector(95 downto 0);

    -- Endereço de byte entregue à memória de armazenamento (registrado).
    o_mem_addr  : out std_logic_vector(31 downto 0);
    -- Palavra lida da memória de armazenamento (leitura registrada).
    i_mem_data  : in  std_logic_vector(31 downto 0)
  );
end entity flash_chip;

architecture rtl of flash_chip is

  -- Estados do chip: livre, esperando a palavra, pedido concluído.
  type state_t is (S_IDLE, S_WAIT, S_DONE);
  -- Estado atual.
  signal st      : state_t := S_IDLE;
  -- Bordas que faltam para capturar a palavra em andamento.
  signal cnt     : natural range 0 to 255 := 0;
  -- Palavra da linha em andamento (0 a 3).
  signal word_n  : natural range 0 to 3 := 0;
  -- Último índice de palavra do pedido (3 para uma linha, 0 para uma palavra).
  signal last_w  : natural range 0 to 3 := 0;
  -- Endereço de byte da palavra pedida, ou o início da linha.
  signal base    : unsigned(31 downto 0) := (others => '0');
  -- Endereço registrado entregue à memória.
  signal addr_q  : std_logic_vector(31 downto 0) := (others => '0');
  -- O pedido em andamento está fora da janela do chip.
  signal out_win : std_logic := '0';
  -- Palavra 0 capturada.
  signal w0      : std_logic_vector(31 downto 0) := (others => '0');
  -- Palavras 1 a 3 capturadas.
  signal wx      : std_logic_vector(95 downto 0) := (others => '0');

begin

  o_mem_addr <= addr_q;
  o_rdata    <= w0;
  o_rdata_x  <= wx;
  o_ready    <= '1' when st = S_DONE else '0';
  o_busy     <= '1' when st = S_WAIT else '0';

  process (i_clk)
    variable next_base : unsigned(31 downto 0);
    variable captured  : std_logic_vector(31 downto 0);
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        st     <= S_IDLE;
        cnt    <= 0;
        word_n <= 0;
      else
        case st is

          when S_IDLE =>
            if i_rden = '1' then
              if i_line = '1' then
                next_base := unsigned(i_addr(31 downto 4)) & "0000";
                last_w    <= 3;
              else
                next_base := unsigned(i_addr(31 downto 2)) & "00";
                last_w    <= 0;
              end if;
              if unsigned(next_base(25 downto window_bits)) /= 0 then
                out_win <= '1';
              else
                out_win <= '0';
              end if;
              base   <= next_base;
              addr_q <= std_logic_vector(next_base);
              word_n <= 0;
              cnt    <= first_latency;
              st     <= S_WAIT;
            end if;

          when S_WAIT =>
            if cnt > 1 then
              cnt <= cnt - 1;
            else
              if out_win = '1' then
                captured := (others => '0');
              else
                captured := i_mem_data;
              end if;
              if word_n = 0 then
                w0 <= captured;
              elsif word_n = 1 then
                wx(31 downto 0) <= captured;
              elsif word_n = 2 then
                wx(63 downto 32) <= captured;
              else
                wx(95 downto 64) <= captured;
              end if;
              if word_n = last_w then
                st <= S_DONE;
              else
                word_n <= word_n + 1;
                addr_q <= std_logic_vector(base + to_unsigned(4 * (word_n + 1), 32));
                cnt    <= next_latency;
              end if;
            end if;

          when S_DONE =>
            if i_advance = '1' then
              st <= S_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
