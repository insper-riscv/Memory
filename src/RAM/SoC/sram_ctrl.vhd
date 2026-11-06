-- =============================================================================
-- Controlador de SRAM assíncrona de 16 bits
--
-- Atende o SoC com o contrato de dados do ram_chip (K2: pedido de palavra ou de
-- linha de quatro palavras, handshake o_ready/i_advance, habilita de bytes na
-- escrita, endereço fora da janela lê zero e descarta a escrita) e comanda os
-- pinos de uma SRAM assíncrona de 1M x 16, como a IS61WV102416BLL-10 da DE2-115:
-- 20 bits de endereço de palavra de 16 bits, CE#, OE#, WE#, LB# e UB#. Uma palavra
-- de 32 bits são dois acessos de meia palavra, e uma linha são oito.
--
-- Leitura. A cada meia palavra o endereço sai de um registrador junto com CE#,
-- OE#, LB# e UB# baixos, e o dado é capturado depois de n_rd ciclos, o teto do
-- maior entre t_aa e t_rc sobre o período do clock. Com t_aa 10 ns, um clock de
-- 50 MHz cobre cada meia palavra em um ciclo, e uma palavra leva dois. Quando o
-- período é menor que o tempo de acesso o número de ciclos sobe (ciclo duplo).
--
-- Escrita. Só as meias palavras com algum byte habilitado são escritas, e LB# e
-- UB# seguem os bits de habilita de bytes, de modo que um store de byte não
-- toca no byte vizinho. Cada escrita tem a preparação do endereço, do dado e dos
-- controles por um ciclo, WE# baixo por n_wl ciclos e WE# alto por n_wh ciclos. O
-- número n_wl cobre t_pwe e deixa endereço, dado e CE# estáveis por t_aw, t_sd e
-- t_sce antes da subida de WE#; n_wh cobre t_ha e t_hd e completa o ciclo t_wc.
-- OE# fica alto na escrita, e o controlador só dirige o barramento de dados nela.
--
-- Contrato (igual ao do ram_chip). O pedido fica em i_addr, i_rden ou i_wren e
-- i_line enquanto o estágio que o pede está parado. o_ready sobe quando o acesso
-- termina e permanece em nível alto até i_advance. O dado lido só muda nessa
-- mesma borda, porque o load que ainda está no estágio de escrita lê o valor
-- anterior até lá. Um pedido de escrita prevalece sobre o de leitura.
--
-- Janela. O chip ocupa size_bytes bytes, uma potência de dois de 16 bytes a 2 MB,
-- a partir de base_kib dentro dos 64 MB da região. Um acesso fora dela termina
-- sem tocar no chip: a leitura devolve zero e a escrita é descartada.
--
-- Tempos. O período do clock, a margem de pino e os tempos do chip são generics
-- (padrões em chip_timing_pkg, marcados "inferido" na ficha da DE2-115).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.utils_pkg.all;
use work.chip_timing_pkg.all;

entity sram_ctrl is
  generic (
    -- Período do clock i_clk, em ns.
    clk_period_ns : positive := 20;
    -- Margem somada a cada tempo do chip para o atraso de pino e de placa, em ns.
    margin_ns     : natural  := 0;
    -- Tamanho do chip em bytes, uma potência de dois de 16 bytes a 2 MB.
    size_bytes    : positive := 2097152;
    -- Onde o chip começa dentro dos 64 MB da região, em KiB.
    base_kib      : natural  := 0;
    -- Acesso por endereço, em ns.
    t_aa_ns       : natural  := SRAM_T_AA_NS;
    -- Ciclo de leitura, em ns.
    t_rc_ns       : natural  := SRAM_T_RC_NS;
    -- Ciclo de escrita, em ns.
    t_wc_ns       : natural  := SRAM_T_WC_NS;
    -- CE# até o fim da escrita, em ns.
    t_sce_ns      : natural  := SRAM_T_SCE_NS;
    -- Endereço válido até o fim da escrita, em ns.
    t_aw_ns       : natural  := SRAM_T_AW_NS;
    -- Largura do pulso de WE#, em ns.
    t_pwe_ns      : natural  := SRAM_T_PWE_NS;
    -- Dado válido antes da subida de WE#, em ns.
    t_sd_ns       : natural  := SRAM_T_SD_NS;
    -- Endereço mantido depois da subida de WE#, em ns.
    t_ha_ns       : natural  := SRAM_T_HA_NS;
    -- Dado mantido depois da subida de WE#, em ns.
    t_hd_ns       : natural  := SRAM_T_HD_NS
  );
  port (
    -- Clock do módulo.
    i_clk       : in  std_logic;
    -- Reset síncrono, ativo em '1'.
    i_rst       : in  std_logic;

    -- Endereço de byte do acesso.
    i_addr      : in  std_logic_vector(31 downto 0);
    -- Dado de escrita (palavra 0 da linha).
    i_wdata     : in  std_logic_vector(31 downto 0);
    -- Habilita de bytes da escrita, um bit por byte (palavra 0).
    i_byteena   : in  std_logic_vector(3 downto 0);
    -- Pedido de leitura ('1' = lê).
    i_rden      : in  std_logic;
    -- Pedido de escrita ('1' = escreve), que prevalece sobre a leitura.
    i_wren      : in  std_logic;
    -- O pipeline avançou neste ciclo, o acesso concluído pode terminar.
    i_advance   : in  std_logic;
    -- Acesso concluído, o dado lido é válido ('1').
    o_ready     : out std_logic;
    -- Dado lido (palavra 0 da linha).
    o_rdata     : out std_logic_vector(31 downto 0);
    -- Acesso de linha, quatro palavras seguidas ('1').
    i_line      : in  std_logic := '0';
    -- Palavras 1 a 3 do dado de escrita da linha.
    i_wdata_x   : in  std_logic_vector(95 downto 0) := (others => '0');
    -- Habilita de bytes das palavras 1 a 3 da linha.
    i_byteena_x : in  std_logic_vector(11 downto 0) := (others => '0');
    -- Palavras 1 a 3 do dado lido da linha.
    o_rdata_x   : out std_logic_vector(95 downto 0);

    -- Chip: endereço de palavra de 16 bits (SRAM_ADDR[19:0]).
    o_sram_addr  : out std_logic_vector(19 downto 0);
    -- Chip: dado a escrever (SRAM_DQ[15:0]).
    o_sram_dq    : out std_logic_vector(15 downto 0);
    -- Chip: o controlador dirige SRAM_DQ ('1'); o topo faz o tristate.
    o_sram_dq_oe : out std_logic;
    -- Chip: dado lido (SRAM_DQ[15:0]).
    i_sram_dq    : in  std_logic_vector(15 downto 0);
    -- Chip: chip habilitado, ativo em '0'.
    o_sram_ce_n  : out std_logic;
    -- Chip: saída habilitada, ativo em '0'.
    o_sram_oe_n  : out std_logic;
    -- Chip: escrita habilitada, ativo em '0'.
    o_sram_we_n  : out std_logic;
    -- Chip: byte baixo habilitado, ativo em '0'.
    o_sram_lb_n  : out std_logic;
    -- Chip: byte alto habilitado, ativo em '0'.
    o_sram_ub_n  : out std_logic
  );
end entity sram_ctrl;

architecture rtl of sram_ctrl is

  -- Bits de endereço da janela do chip (falha se size_bytes não for uma potência de dois).
  constant WINDOW_BITS : natural := log2_exact(size_bytes);

  -- Ciclos de espera de uma leitura de meia palavra.
  constant N_RD : positive := cycles_of(max_natural(t_aa_ns, t_rc_ns), clk_period_ns, margin_ns);
  -- Ciclos de WE# baixo: cobrem t_pwe e, junto com o ciclo de preparação, t_aw, t_sd e t_sce.
  constant N_WL : positive := max_natural(cycles_of(t_pwe_ns, clk_period_ns, margin_ns),
                              max_natural(cycles_of(max_natural(t_sd_ns, max_natural(t_aw_ns, t_sce_ns)), clk_period_ns, margin_ns), 2) - 1);
  -- Ciclos de WE# alto: cobrem t_ha e t_hd e completam t_wc.
  constant N_WH : positive := max_natural(cycles_of(max_natural(t_ha_ns, t_hd_ns), clk_period_ns, margin_ns),
                              max_natural(cycles_of(t_wc_ns, clk_period_ns, margin_ns), N_WL + 2) - N_WL - 1);
  -- Maior valor de contagem.
  constant CNT_MAX : natural := N_RD + N_WL + N_WH;

  -- Estados: livre, espera da leitura, escolha da meia palavra a escrever, preparação, WE# baixo, WE# alto e concluído.
  type state_t is (S_IDLE, S_RD, S_WSEL, S_WSETUP, S_WLOW, S_WHIGH, S_DONE);
  -- Estado atual.
  signal st       : state_t := S_IDLE;
  -- Ciclos que faltam da espera em andamento.
  signal cnt      : natural range 0 to CNT_MAX := 0;
  -- Meia palavra em andamento (0 a 7).
  signal half_n   : natural range 0 to 8 := 0;
  -- Última meia palavra do acesso (1 para uma palavra, 7 para uma linha).
  signal last_h   : natural range 0 to 7 := 1;
  -- O acesso em andamento é uma escrita.
  signal is_wr    : std_logic := '0';
  -- O acesso em andamento está fora da janela.
  signal out_win  : std_logic := '0';
  -- Endereço entregue ao chip (registrado).
  signal addr_q   : unsigned(19 downto 0) := (others => '0');
  -- Dado entregue ao chip (registrado).
  signal dq_q     : std_logic_vector(15 downto 0) := (others => '0');
  -- O controlador dirige o barramento de dados (registrado).
  signal dq_oe_q  : std_logic := '0';
  -- CE# registrado.
  signal ce_n_q   : std_logic := '1';
  -- OE# registrado.
  signal oe_n_q   : std_logic := '1';
  -- WE# registrado.
  signal we_n_q   : std_logic := '1';
  -- LB# registrado.
  signal lb_n_q   : std_logic := '1';
  -- UB# registrado.
  signal ub_n_q   : std_logic := '1';
  -- Dado de escrita capturado (palavra 0 nos bits 31 a 0).
  signal wdata_q  : std_logic_vector(127 downto 0) := (others => '0');
  -- Habilita de bytes capturado.
  signal be_q     : std_logic_vector(15 downto 0) := (others => '0');
  -- Dado lido, à espera do avanço do pipeline.
  signal pend_q   : std_logic_vector(127 downto 0) := (others => '0');
  -- Dado entregue ao pipeline.
  signal rdata_q  : std_logic_vector(127 downto 0) := (others => '0');

begin

  assert size_bytes >= 16 and size_bytes <= 2 ** 21
    report "size_bytes must be between 16 bytes and 2 MB" severity failure;

  o_ready      <= '1' when st = S_DONE else '0';
  o_rdata      <= rdata_q(31 downto 0);
  o_rdata_x    <= rdata_q(127 downto 32);
  o_sram_addr  <= std_logic_vector(addr_q);
  o_sram_dq    <= dq_q;
  o_sram_dq_oe <= dq_oe_q;
  o_sram_ce_n  <= ce_n_q;
  o_sram_oe_n  <= oe_n_q;
  o_sram_we_n  <= we_n_q;
  o_sram_lb_n  <= lb_n_q;
  o_sram_ub_n  <= ub_n_q;

  process (i_clk)
    -- Endereço de byte do acesso, alinhado a palavra ou a linha.
    variable a      : unsigned(31 downto 0);
    -- Deslocamento do acesso dentro do chip, em bytes.
    variable offset : unsigned(25 downto 0);
    -- O acesso está fora da janela.
    variable outw   : boolean;
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        st      <= S_IDLE;
        ce_n_q  <= '1';
        oe_n_q  <= '1';
        we_n_q  <= '1';
        lb_n_q  <= '1';
        ub_n_q  <= '1';
        dq_oe_q <= '0';
      else
        case st is

          when S_IDLE =>
            if i_rden = '1' or i_wren = '1' then
              if i_line = '1' then
                a      := unsigned(i_addr(31 downto 4)) & "0000";
                last_h <= 7;
              else
                a      := unsigned(i_addr(31 downto 2)) & "00";
                last_h <= 1;
              end if;
              outw := false;
              if a(25 downto 0) < base_kib * 1024 then
                outw := true;
              else
                offset := a(25 downto 0) - to_unsigned(base_kib * 1024, 26);
                if offset(25 downto WINDOW_BITS) /= 0 then
                  outw := true;
                end if;
              end if;
              is_wr   <= i_wren;
              half_n  <= 0;
              wdata_q <= i_wdata_x & i_wdata;
              be_q    <= i_byteena_x & i_byteena;
              if outw then
                if i_wren = '0' then
                  pend_q <= (others => '0');
                end if;
                st <= S_DONE;
              else
                addr_q <= resize(offset(WINDOW_BITS - 1 downto 1), 20);
                if i_wren = '1' then
                  st <= S_WSEL;
                else
                  ce_n_q  <= '0';
                  oe_n_q  <= '0';
                  lb_n_q  <= '0';
                  ub_n_q  <= '0';
                  dq_oe_q <= '0';
                  cnt     <= N_RD;
                  st      <= S_RD;
                end if;
              end if;
            end if;

          when S_RD =>
            if cnt > 1 then
              cnt <= cnt - 1;
            else
              for h in 0 to 7 loop
                if half_n = h then
                  pend_q(16 * h + 15 downto 16 * h) <= i_sram_dq;
                end if;
              end loop;
              if half_n = last_h then
                ce_n_q <= '1';
                oe_n_q <= '1';
                lb_n_q <= '1';
                ub_n_q <= '1';
                st     <= S_DONE;
              else
                half_n <= half_n + 1;
                addr_q <= addr_q + 1;
                cnt    <= N_RD;
              end if;
            end if;

          when S_WSEL =>
            if half_n > last_h then
              ce_n_q  <= '1';
              lb_n_q  <= '1';
              ub_n_q  <= '1';
              dq_oe_q <= '0';
              st      <= S_DONE;
            elsif be_q(2 * half_n + 1 downto 2 * half_n) = "00" then
              half_n <= half_n + 1;
              addr_q <= addr_q + 1;
            else
              ce_n_q  <= '0';
              oe_n_q  <= '1';
              we_n_q  <= '1';
              lb_n_q  <= not be_q(2 * half_n);
              ub_n_q  <= not be_q(2 * half_n + 1);
              dq_oe_q <= '1';
              for h in 0 to 7 loop
                if half_n = h then
                  dq_q <= wdata_q(16 * h + 15 downto 16 * h);
                end if;
              end loop;
              st <= S_WSETUP;
            end if;

          when S_WSETUP =>
            we_n_q <= '0';
            cnt    <= N_WL;
            st     <= S_WLOW;

          when S_WLOW =>
            if cnt > 1 then
              cnt <= cnt - 1;
            else
              we_n_q <= '1';
              cnt    <= N_WH;
              st     <= S_WHIGH;
            end if;

          when S_WHIGH =>
            if cnt > 1 then
              cnt <= cnt - 1;
            else
              half_n <= half_n + 1;
              addr_q <= addr_q + 1;
              st     <= S_WSEL;
            end if;

          when S_DONE =>
            if i_advance = '1' then
              if is_wr = '0' then
                rdata_q <= pend_q;
              end if;
              st <= S_IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
