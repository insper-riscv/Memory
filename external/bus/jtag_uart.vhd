-- =============================================================================
-- UART sobre JTAG
--
-- Uma UART cuja outra ponta é um hospedeiro no JTAG em vez de uma linha serial:
-- o core escreve bytes que o hospedeiro lê, e o hospedeiro escreve bytes que o
-- core lê.
--
-- Lado do core (clock clk): três registradores de palavra, um acesso por pulso
-- de we ou re.
--
--   palavra 0  TXDATA  escrita: enfileira o byte dos bits 7:0 para o hospedeiro (descartado e
--                      sinalizado se a fila está cheia); leitura: 0
--   palavra 1  RXDATA  leitura: bit 8 = havia um byte esperando, bits 7:0 = esse byte, que é
--                      removido; bit 8 = 0 quando vazia; escrita: ignorada
--   palavra 2  STATUS  leitura: bits 7:0 lugares livres na fila de transmissão (0 a 64), bits
--                      15:8 bytes esperando na fila de recepção (0 a 64), bit 16 um byte foi
--                      descartado desde a última leitura deste registrador (a leitura limpa),
--                      bit 17 um hospedeiro já varreu desde o reset (um programa que só imprime
--                      quando alguém escuta o lê); escrita: ignorada
--
-- Lado do hospedeiro: a lógica atrás de uma instância do Virtual JTAG
-- (sld_virtual_jtag no topo da placa, conduzida pelo testbench em simulação) em
-- tck. A instrução 1 seleciona um registrador de 48 bits. Uma varredura envia um
-- comando e traz a resposta ao anterior:
--
--   entra   [8] push   [7:0] byte a entregar ao core (só vale se push = 1)
--   sai     [31:0] até quatro bytes vindos do core, o primeiro nos bits 7:0
--           [34:32] quantos deles são válidos
--           [35] o push do comando anterior foi descartado (fila de recepção cheia)
--           [36] a varredura anterior foi descartada: o comando antes dela não havia terminado
--           [47:40] bytes ainda esperando na fila de transmissão
--
-- Toda varredura aceita tira até quatro bytes da fila de transmissão. O clock da
-- cadeia JTAG só roda durante uma varredura, então uma resposta chega à lógica
-- da varredura durante a varredura seguinte e é mostrada pela outra depois dela:
-- uma varredura mostra a resposta ao comando da varredura anterior à anterior.
-- Uma resposta é mostrada uma vez. Um hospedeiro que quer a saída continua
-- varrendo. O comando atravessa para clk com um toggle e dois flip-flops; o byte
-- e o flag de push ficam estáveis até o próximo comando aceito, e a resposta
-- atravessa de volta do mesmo modo.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jtag_uart is
  generic (
    -- Log2 da profundidade de cada fila de bytes.
    log2_depth : natural := 6
  );
  port (
    -- Clock do módulo.
    i_clk     : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst     : in  std_logic;

    -- Endereço do acesso.
    i_addr    : in  std_logic_vector(7 downto 0);
    -- Dado de escrita.
    i_wdata   : in  std_logic_vector(31 downto 0);
    -- Escrita ('1') ou leitura ('0').
    i_we      : in  std_logic;
    -- Leitura ('1').
    i_re      : in  std_logic;
    -- Dado lido.
    o_rdata   : out std_logic_vector(31 downto 0);

    -- Clock da cadeia JTAG.
    i_tck       : in  std_logic;
    -- Dado serial vindo do hospedeiro.
    i_tdi       : in  std_logic;
    -- Dado serial para o hospedeiro.
    o_tdo       : out std_logic;
    -- Registrador de instrução do Virtual JTAG.
    i_ir_in     : in  std_logic_vector(1 downto 0);
    -- Estado Capture-DR da cadeia virtual.
    i_state_cdr : in  std_logic;
    -- Estado Shift-DR da cadeia virtual.
    i_state_sdr : in  std_logic;
    -- Estado Update-DR da cadeia virtual.
    i_state_udr : in  std_logic;
    -- Estado Update-IR da cadeia virtual.
    i_state_uir : in  std_logic
  );
end entity jtag_uart;

architecture rtl of jtag_uart is

  -- Profundidade de cada fila de bytes.
  constant DEPTH : natural := 2 ** log2_depth;
  -- Memória de uma fila de bytes.
  type fifo_t is array (0 to DEPTH - 1) of std_logic_vector(7 downto 0);

  -- Fila de bytes do core para o hospedeiro.
  signal tx_mem    : fifo_t := (others => (others => '0'));
  -- Fila de bytes do hospedeiro para o core.
  signal rx_mem    : fifo_t := (others => (others => '0'));
  -- Ponteiro de escrita da fila de transmissão.
  signal tx_w : unsigned(log2_depth downto 0) := (others => '0');
  -- Ponteiro de leitura da fila de transmissão.
  signal tx_r : unsigned(log2_depth downto 0) := (others => '0');
  -- Ponteiro de escrita da fila de recepção.
  signal rx_w : unsigned(log2_depth downto 0) := (others => '0');
  -- Ponteiro de leitura da fila de recepção.
  signal rx_r : unsigned(log2_depth downto 0) := (others => '0');
  -- Um byte foi descartado desde a última leitura do status.
  signal lost      : std_logic := '0';
  -- Um hospedeiro já varreu desde o reset.
  signal attached  : std_logic := '0';
  -- Sincronizador de dois estágios do toggle de comando.
  signal cmd_s     : std_logic_vector(1 downto 0) := "00";
  -- Toggle de conclusão (registrado).
  signal done_i    : std_logic := '0';
  -- Resposta ao último comando (lado clk).
  signal resp      : std_logic_vector(47 downto 0) := (others => '0');
  -- Bytes esperando na fila de transmissão.
  signal tx_level  : unsigned(log2_depth downto 0);
  -- Bytes esperando na fila de recepção.
  signal rx_level  : unsigned(log2_depth downto 0);

  -- Registrador de instrução do Virtual JTAG.
  signal ir        : std_logic_vector(1 downto 0) := (others => '0');
  -- Registrador de deslocamento de 48 bits.
  signal sr        : std_logic_vector(47 downto 0) := (others => '0');
  -- Registrador de bypass de 1 bit.
  signal bypass    : std_logic := '0';
  -- Toggle de comando ao lado clk (registrado).
  signal cmd_i     : std_logic := '0';
  -- Sincronizador de dois estágios do toggle de conclusão em tck.
  signal done_s    : std_logic_vector(1 downto 0) := "00";
  -- A resposta anterior já foi mostrada.
  signal seen      : std_logic := '0';
  -- Resposta guardada para a próxima varredura.
  signal held      : std_logic_vector(47 downto 0) := (others => '0');
  -- A varredura anterior foi descartada por chegar com o comando anterior em andamento.
  signal overrun   : std_logic := '0';
  -- O comando anterior ainda não terminou.
  signal busy      : std_logic;
  -- Byte do comando a entregar ao core.
  signal byte_r    : std_logic_vector(7 downto 0) := (others => '0');
  -- O comando traz um byte para o core.
  signal push_r    : std_logic := '0';

begin

  tx_level <= tx_w - tx_r;
  rx_level <= rx_w - rx_r;
  busy     <= '1' when cmd_i /= done_s(1) else '0';
  o_tdo      <= sr(0) when ir = "01" else bypass;

  -- os registradores lidos pelo core
  process (i_addr, rx_mem, rx_r, rx_level, tx_level, lost, attached)
    -- Lugares livres na fila de transmissão.
    variable free : unsigned(15 downto 0);
  begin
    o_rdata <= (others => '0');
    case to_integer(unsigned(i_addr)) is
      when 1 =>
        if rx_level /= 0 then
          o_rdata(8) <= '1';
          o_rdata(7 downto 0) <= rx_mem(to_integer(rx_r(log2_depth - 1 downto 0)));
        end if;
      when 2 =>
        free := to_unsigned(DEPTH, 16) - resize(tx_level, 16);
        o_rdata(7 downto 0)  <= std_logic_vector(free(7 downto 0));
        o_rdata(15 downto 8) <= std_logic_vector(resize(rx_level, 8));
        o_rdata(16)          <= lost;
        o_rdata(17)          <= attached;
      when others =>
        null;
    end case;
  end process;

  process (i_clk)
    -- Quantidade de bytes retirados da fila de transmissão.
    variable n      : natural range 0 to 4;
    -- Bytes retirados da fila de transmissão.
    variable taken  : std_logic_vector(31 downto 0);
    -- A fila de recepção estava cheia no push.
    variable rxovf  : std_logic;
    -- Ponteiro de leitura da fila de transmissão depois da retirada.
    variable tx_r_n : unsigned(log2_depth downto 0);
    -- Bytes ainda na fila de transmissão depois da retirada.
    variable left   : unsigned(log2_depth downto 0);
  begin
    if rising_edge(i_clk) then
      cmd_s <= cmd_s(0) & cmd_i;

      if i_rst = '1' then
        tx_w <= (others => '0');
        tx_r <= (others => '0');
        rx_w <= (others => '0');
        rx_r <= (others => '0');
        lost <= '0';
        attached <= '0';
        done_i <= cmd_s(1);   -- um comando pendente antes do reset não é executado
        resp <= (others => '0');
      else
        -- o core
        if i_we = '1' and to_integer(unsigned(i_addr)) = 0 then
          if tx_level = DEPTH then
            lost <= '1';
          else
            tx_mem(to_integer(tx_w(log2_depth - 1 downto 0))) <= i_wdata(7 downto 0);
            tx_w <= tx_w + 1;
          end if;
        end if;
        if i_re = '1' then
          if to_integer(unsigned(i_addr)) = 1 and rx_level /= 0 then
            rx_r <= rx_r + 1;
          elsif to_integer(unsigned(i_addr)) = 2 then
            lost <= '0';
          end if;
        end if;

        -- um comando do hospedeiro
        if cmd_s(1) /= done_i then
          attached <= '1';
          if tx_level > 4 then
            n := 4;
          else
            n := to_integer(tx_level);
          end if;
          taken := (others => '0');
          for i in 0 to 3 loop
            if i < n then
              taken(8 * i + 7 downto 8 * i) := tx_mem(to_integer(tx_r(log2_depth - 1 downto 0) + i));
            end if;
          end loop;
          tx_r_n := tx_r + n;
          tx_r   <= tx_r_n;
          left   := tx_w - tx_r_n;

          rxovf := '0';
          if push_r = '1' then
            if rx_level = DEPTH then
              rxovf := '1';
            else
              rx_mem(to_integer(rx_w(log2_depth - 1 downto 0))) <= byte_r;
              rx_w <= rx_w + 1;
            end if;
          end if;

          resp <= std_logic_vector(resize(left, 8)) & "00000" & std_logic_vector(to_unsigned(n, 3))
                  & taken;
          resp(35) <= rxovf;
          done_i <= not done_i;
        end if;
      end if;
    end if;
  end process;

  process (i_tck)
  begin
    if rising_edge(i_tck) then
      done_s <= done_s(0) & done_i;

      if i_state_uir = '1' then
        ir <= i_ir_in;
      end if;

      if i_state_cdr = '1' then
        if ir = "01" then
          sr <= held(47 downto 37) & overrun & held(35 downto 0);
          -- uma resposta é mostrada uma vez
          held(34 downto 0) <= (others => '0');
        end if;
      elsif i_state_sdr = '1' then
        if ir = "01" then
          sr <= i_tdi & sr(47 downto 1);
        else
          bypass <= i_tdi;
        end if;
      elsif i_state_udr = '1' then
        if ir = "01" then
          -- a resposta do comando anterior já está no registrador do outro clock de vez (o
          -- deslocamento durou muitas bordas de tck): guarda-a para a próxima captura
          if done_s(1) /= seen then
            held <= resp;
            seen <= done_s(1);
          end if;
          if busy = '1' then
            overrun <= '1';
          else
            overrun <= '0';
            byte_r  <= sr(7 downto 0);
            push_r  <= sr(8);
            cmd_i   <= not cmd_i;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
