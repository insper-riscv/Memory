-- =============================================================================
-- Autoteste embutido da SDRAM
--
-- Ligado direto ao controlador (sem core e sem ponte): escreve dados conhecidos
-- sobre uma faixa de palavras, lê de volta e conta as palavras que diferem. É a
-- verificação dos pinos, da fase do clock e do controlador que não depende de
-- mais nada do sistema.
--
-- Uma execução é escolhida por mode e iniciada por uma borda de subida de start:
--
--   0  rápido: janela de 2^window_log2 palavras, dados dependentes do endereço e
--      as máscaras de bytes (um byte mascarado mantém o valor antigo, um habilitado muda)
--   1  padrões: a mesma janela com tudo zero, tudo um, 0xAAAAAAAA, 0x55555555, um
--      um andante e um zero andante em cada bit do barramento, depois os dados do
--      endereço e o seu complemento
--   2  varredura: o chip inteiro (2^sweep_log2 palavras), dados do endereço e depois o complemento
--   3  aleatório: 2^random_log2 palavras em endereços pseudoaleatórios, escritas e relidas
--
-- O dado de uma palavra depende do seu endereço de um modo que nunca se repete
-- dentro do chip (uma linha de endereço presa ou trocada põe o dado de uma
-- palavra em outra).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_bist is
  generic (
    -- Log2 do número de palavras da janela dos modos 0 e 1.
    window_log2    : natural := 16;
    -- Log2 do número de palavras da varredura do modo 2.
    sweep_log2     : natural := 24;
    -- Log2 do número de palavras do modo aleatório.
    random_log2    : natural := 20;
    -- Clocks de espera por uma palavra antes de a execução ser declarada falha.
    timeout_cycles : natural := 4096
  );
  port (
    -- Clock do módulo.
    i_clk        : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst        : in  std_logic;

    -- Inicia uma execução na borda de subida.
    i_start      : in  std_logic;
    -- Modo da execução: 0 rápido, 1 padrões, 2 varredura, 3 aleatório.
    i_mode       : in  std_logic_vector(1 downto 0);
    -- A inicialização da SDRAM terminou ('1').
    i_init_done  : in  std_logic;

    -- Há uma execução em andamento.
    o_busy       : out std_logic;
    -- Uma execução terminou (permanece em '1' até o próximo start).
    o_done       : out std_logic;
    -- Uma palavra diferiu ou o controlador não respondeu.
    o_fail       : out std_logic;
    -- O controlador não respondeu dentro do prazo.
    o_timeout    : out std_logic;
    -- Fase da execução em andamento.
    o_phase      : out std_logic_vector(4 downto 0);
    -- Quantidade de palavras que diferiram.
    o_err_count  : out std_logic_vector(31 downto 0);
    -- Endereço da primeira palavra que diferiu.
    o_first_addr : out std_logic_vector(23 downto 0);
    -- Valor esperado na primeira palavra que diferiu.
    o_first_exp  : out std_logic_vector(31 downto 0);
    -- Valor lido na primeira palavra que diferiu.
    o_first_got  : out std_logic_vector(31 downto 0);
    -- Quantidade de palavras já movidas.
    o_ops_done   : out std_logic_vector(31 downto 0);

    -- Porta do controlador SDRAM: alternância que pede um acesso, cada inversão é um pedido novo.
    o_c_req_tog  : out std_logic;
    -- Porta do controlador SDRAM: alternância que confirma o acesso, igual a req_tog quando o pedido foi atendido.
    i_c_ack_tog  : in  std_logic;
    -- Porta do controlador SDRAM: escrita ('1') ou leitura ('0').
    o_c_we       : out std_logic;
    -- Porta do controlador SDRAM: endereço de palavra.
    o_c_addr     : out std_logic_vector(23 downto 0);
    -- Porta do controlador SDRAM: dado de escrita.
    o_c_wdata    : out std_logic_vector(31 downto 0);
    -- Porta do controlador SDRAM: habilita de bytes da escrita.
    o_c_be       : out std_logic_vector(3 downto 0);
    -- Porta do controlador SDRAM: dado lido.
    i_c_rdata    : in  std_logic_vector(31 downto 0)
  );
end entity sdram_bist;

architecture rtl of sdram_bist is

  -- Tipo de uma fase: escrita, leitura ou fim da lista.
  type kind_t is (K_WRITE, K_READ, K_END);
  -- Definição de uma fase: tipo, padrão, máscara de bytes, endereços aleatórios e log2 da quantidade de palavras.
  type phase_def_t is record
    kind     : kind_t;
    pat      : natural range 0 to 9;
    be       : std_logic_vector(3 downto 0);
    rnd      : boolean;
    cnt_log2 : natural;
  end record;

  function hash (w : unsigned(23 downto 0)) return std_logic_vector is
    -- Byte alto do dado derivado do endereço.
    variable hi : std_logic_vector(7 downto 0);
    -- Três bytes baixos do dado derivado do endereço.
    variable lo : std_logic_vector(23 downto 0);
  begin
    hi := std_logic_vector(w(7 downto 0) xor w(15 downto 8) xor w(23 downto 16));
    lo := std_logic_vector(w xor x"5AC3A5");
    return hi & lo;
  end function;

  -- o dado da palavra w para um padrão
  function expected (pat : natural; w : unsigned(23 downto 0)) return std_logic_vector is
    -- Dado derivado do endereço da palavra.
    variable h : std_logic_vector(31 downto 0) := hash(w);
    -- Palavra com um único bit em um, na posição dada pelo endereço.
    variable one : std_logic_vector(31 downto 0);
  begin
    one := std_logic_vector(shift_left(to_unsigned(1, 32), to_integer(w(4 downto 0))));
    case pat is
      when 0 => return x"00000000";
      when 1 => return x"FFFFFFFF";
      when 2 => return x"AAAAAAAA";
      when 3 => return x"55555555";
      when 4 => return one;
      when 5 => return not one;
      when 6 => return h;
      when 7 => return not h;
      -- os bytes 1 e 3 mantêm h, os bytes 0 e 2 receberam o complemento (uma escrita do padrão 7 com máscara 0101 sobre o 6)
      when 8 => return (h and x"FF00FF00") or ((not h) and x"00FF00FF");
      -- depois os bytes 1 e 3 receberam tudo um (máscara 1010)
      when others => return x"FF00FF00" or ((not h) and x"00FF00FF");
    end case;
  end function;

  function def (m : std_logic_vector(1 downto 0); idx : natural) return phase_def_t is
    -- Definição da fase pedida (fim da lista quando o índice é inválido).
    variable d : phase_def_t := (K_END, 0, "1111", false, 0);
    -- Padrão de dados da fase.
    variable p : natural;
  begin
    case m is
      when "00" =>
        case idx is
          when 0 => d := (K_WRITE, 6, "1111", false, window_log2);
          when 1 => d := (K_WRITE, 7, "0101", false, window_log2);
          when 2 => d := (K_READ,  8, "1111", false, window_log2);
          when 3 => d := (K_WRITE, 1, "1010", false, window_log2);
          when 4 => d := (K_READ,  9, "1111", false, window_log2);
          when 5 => d := (K_WRITE, 6, "1111", false, window_log2);
          when 6 => d := (K_READ,  6, "1111", false, window_log2);
          when others => null;
        end case;
      when "01" =>
        if idx < 16 then
          p := idx / 2;
          if idx mod 2 = 0 then
            d := (K_WRITE, p, "1111", false, window_log2);
          else
            d := (K_READ,  p, "1111", false, window_log2);
          end if;
        end if;
      when "10" =>
        case idx is
          when 0 => d := (K_WRITE, 6, "1111", false, sweep_log2);
          when 1 => d := (K_READ,  6, "1111", false, sweep_log2);
          when 2 => d := (K_WRITE, 7, "1111", false, sweep_log2);
          when 3 => d := (K_READ,  7, "1111", false, sweep_log2);
          when others => null;
        end case;
      when others =>
        case idx is
          when 0 => d := (K_WRITE, 6, "1111", true, random_log2);
          when 1 => d := (K_READ,  6, "1111", true, random_log2);
          when others => null;
        end case;
    end case;
    return d;
  end function;

  -- Semente do gerador pseudoaleatório de endereços.
  constant SEED : unsigned(31 downto 0) := x"2545F491";

  -- Estados do autoteste.
  type state_t is (ST_IDLE, ST_PHASE, ST_ISSUE, ST_TOG, ST_WAIT);
  -- Estado atual do autoteste.
  signal st : state_t := ST_IDLE;

  -- Valor anterior de start, para detectar a borda de subida.
  signal start_q   : std_logic := '0';
  -- Modo da execução em andamento.
  signal mode_l    : std_logic_vector(1 downto 0) := "00";
  -- Índice da fase em andamento.
  signal idx       : natural range 0 to 31 := 0;
  -- Definição da fase em andamento.
  signal cur       : phase_def_t := (K_END, 0, "1111", false, 0);
  -- Palavra corrente da fase.
  signal n         : unsigned(31 downto 0) := (others => '0');
  -- Última palavra da fase.
  signal limit     : unsigned(31 downto 0) := (others => '0');
  -- Fonte dos endereços das fases aleatórias (registrador de deslocamento).
  signal lf        : unsigned(31 downto 0) := SEED;
  -- Toggle de pedido ao controlador (registrado).
  signal req_i     : std_logic := '0';
  -- Valor esperado da palavra corrente.
  signal exp_r     : std_logic_vector(31 downto 0) := (others => '0');
  -- Endereço da palavra corrente.
  signal addr_r    : unsigned(23 downto 0) := (others => '0');
  -- Clocks esperando a resposta do controlador.
  signal wait_cnt  : natural range 0 to timeout_cycles := 0;
  -- Execução em andamento (registrado).
  signal busy_i : std_logic := '0';
  -- Execução terminada (registrado).
  signal done_i : std_logic := '0';
  -- Falha detectada (registrado).
  signal fail_i : std_logic := '0';
  -- Prazo estourado (registrado).
  signal timeout_i : std_logic := '0';
  -- Contagem das palavras que diferiram.
  signal errs      : unsigned(31 downto 0) := (others => '0');
  -- Contagem das palavras movidas.
  signal ops       : unsigned(31 downto 0) := (others => '0');
  -- Endereço da primeira diferença.
  signal f_addr    : std_logic_vector(23 downto 0) := (others => '0');
  -- Valor esperado na primeira diferença.
  signal f_exp : std_logic_vector(31 downto 0) := (others => '0');
  -- Valor lido na primeira diferença.
  signal f_got : std_logic_vector(31 downto 0) := (others => '0');

begin

  o_busy       <= busy_i;
  o_done       <= done_i;
  o_fail       <= fail_i;
  o_timeout    <= timeout_i;
  o_phase      <= std_logic_vector(to_unsigned(idx, 5));
  o_err_count  <= std_logic_vector(errs);
  o_first_addr <= f_addr;
  o_first_exp  <= f_exp;
  o_first_got  <= f_got;
  o_ops_done   <= std_logic_vector(ops);
  o_c_req_tog  <= req_i;

  process (i_clk)
    -- Próximo valor do gerador de endereços aleatórios.
    variable next_lf : unsigned(31 downto 0);
    -- A palavra corrente é a última da fase.
    variable last    : boolean;
    -- Endereço da palavra corrente.
    variable a       : unsigned(23 downto 0);
  begin
    if rising_edge(i_clk) then
      start_q <= i_start;

      if i_rst = '1' then
        st        <= ST_IDLE;
        req_i     <= '0';
        busy_i    <= '0';
        done_i    <= '0';
        fail_i    <= '0';
        timeout_i <= '0';
        errs      <= (others => '0');
        ops       <= (others => '0');
        idx       <= 0;
      else
        case st is

          when ST_IDLE =>
            if i_start = '1' and start_q = '0' and i_init_done = '1' then
              mode_l    <= i_mode;
              idx       <= 0;
              busy_i    <= '1';
              done_i    <= '0';
              fail_i    <= '0';
              timeout_i <= '0';
              errs      <= (others => '0');
              ops       <= (others => '0');
              f_addr    <= (others => '0');
              f_exp     <= (others => '0');
              f_got     <= (others => '0');
              st        <= ST_PHASE;
            end if;

          when ST_PHASE =>
            cur <= def(mode_l, idx);
            n   <= (others => '0');
            lf  <= SEED;
            limit <= shift_left(to_unsigned(1, 32), def(mode_l, idx).cnt_log2) - 1;
            if def(mode_l, idx).kind = K_END then
              busy_i <= '0';
              done_i <= '1';
              st     <= ST_IDLE;
            else
              st <= ST_ISSUE;
            end if;

          when ST_ISSUE =>
            if cur.rnd then
              a := lf(23 downto 0);
            else
              a := n(23 downto 0);
            end if;
            addr_r  <= a;
            o_c_addr  <= std_logic_vector(a);
            if cur.kind = K_WRITE then
              o_c_we <= '1';
            else
              o_c_we <= '0';
            end if;
            o_c_be    <= cur.be;
            o_c_wdata <= expected(cur.pat, a);
            exp_r   <= expected(cur.pat, a);
            wait_cnt <= 0;
            st      <= ST_TOG;

          when ST_TOG =>
            req_i <= not req_i;
            st    <= ST_WAIT;

          when ST_WAIT =>
            if i_c_ack_tog = req_i then
              ops <= ops + 1;
              if cur.kind = K_READ and i_c_rdata /= exp_r then
                if errs = 0 then
                  f_addr <= std_logic_vector(addr_r);
                  f_exp  <= exp_r;
                  f_got  <= i_c_rdata;
                end if;
                errs   <= errs + 1;
                fail_i <= '1';
              end if;
              -- próxima palavra da fase
              last := n = limit;
              if last then
                idx <= idx + 1;
                st  <= ST_PHASE;
              else
                n <= n + 1;
                next_lf := lf xor shift_left(lf, 13);
                next_lf := next_lf xor shift_right(next_lf, 17);
                next_lf := next_lf xor shift_left(next_lf, 5);
                lf <= next_lf;
                st <= ST_ISSUE;
              end if;
            elsif wait_cnt = timeout_cycles then
              timeout_i <= '1';
              fail_i    <= '1';
              busy_i    <= '0';
              done_i    <= '1';
              st        <= ST_IDLE;
            else
              wait_cnt <= wait_cnt + 1;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
