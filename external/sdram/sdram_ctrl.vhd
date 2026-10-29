-- =============================================================================
-- Controlador da SDRAM SDR de 32M x 16
--
-- Um pedido move uma palavra de 32 bits como uma rajada de dois beats de 16
-- bits. A política é de página fechada: todo acesso ativa a sua linha e lê ou
-- escreve com auto-precharge, de modo que nenhuma linha fica aberta e a ordem
-- dos comandos nunca depende do acesso anterior.
--
-- Interface de pedido (handshake por alternância, que atravessa domínios de
-- clock com segurança): o requisitante coloca we/addr/wdata/be e inverte
-- req_tog; o controlador inverte ack_tog quando a palavra foi movida (dado lido
-- válido em rdata, ou dado de escrita entregue ao chip). we/addr/wdata/be ficam
-- estáveis da inversão de req_tog até a de ack_tog. req_tog é sincronizado aqui,
-- então pode vir de outro clock. addr é o endereço de palavra de 32 bits: linha
-- (13) & banco (2) & coluna (9).
--
-- Um pedido de linha (line = '1') move quatro palavras, os 16 bytes que começam
-- no endereço dado (seus dois bits baixos são ignorados), em uma única abertura
-- da linha: ACTIVE, quatro comandos READ ou WRITE com dois clocks de intervalo
-- (o último com auto-precharge) e oito beats nos pinos de dados sem intervalo.
-- A palavra 0 viaja em wdata/be/rdata e as palavras 1 a 3 em
-- wdata_x/be_x/rdata_x (32 bits cada, a palavra 1 nos bits mais baixos). As
-- quatro palavras estão na mesma linha porque a linha é alinhada em 16 bytes.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;

entity sdram_ctrl is
  generic (
    -- Período do clock em picossegundos, base da conversão dos tempos do chip em ciclos.
    tck_ps         : natural := T_CK_PS;
    -- Ciclos de espera após a energização antes do primeiro comando (reduzível em simulações curtas).
    init_cycles    : natural := cycles(T_INIT_PS, T_CK_PS);
    -- Ciclos entre dois comandos AUTO REFRESH (reduzível em simulações curtas).
    refresh_cycles : natural := cycles(T_REFI_PS, T_CK_PS) * 9 / 10;
    -- Clocks extras antes de amostrar o dado lido (ajuste de fase da placa e do clock).
    capture_extra  : natural := 0;
    -- Verdadeiro: req_tog vem de outro clock e é sincronizado aqui; falso: vem deste clock (o árbitro) e é usado direto, sem a latência do sincronizador.
    sync_req       : boolean := true
  );
  port (
    -- Clock do módulo.
    i_clk       : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst       : in  std_logic;

    -- Alternância que pede um acesso: cada inversão é um pedido novo.
    i_req_tog   : in  std_logic;
    -- Alternância que confirma o acesso: igual a i_req_tog quando o pedido foi atendido.
    o_ack_tog   : out std_logic;
    -- A inicialização da SDRAM terminou ('1').
    o_init_done : out std_logic;
    -- Escrita ('1') ou leitura ('0').
    i_we        : in  std_logic;
    -- Endereço do acesso.
    i_addr      : in  std_logic_vector(23 downto 0);
    -- Dado de escrita.
    i_wdata     : in  std_logic_vector(31 downto 0);
    -- Habilita de bytes do comando.
    i_be        : in  std_logic_vector(3 downto 0);
    -- Dado lido.
    o_rdata     : out std_logic_vector(31 downto 0);
    -- Acesso de linha, quatro palavras seguidas ('1').
    i_line      : in  std_logic := '0';
    -- Palavras 1 a 3 do dado de escrita da linha.
    i_wdata_x   : in  std_logic_vector(95 downto 0) := (others => '0');
    -- Habilita de bytes das palavras 1 a 3 da escrita de linha.
    i_be_x      : in  std_logic_vector(11 downto 0) := (others => '0');
    -- Palavras 1 a 3 do dado lido da linha.
    o_rdata_x   : out std_logic_vector(95 downto 0);

    -- Habilita de clock (CKE) do chip.
    o_dram_cke   : out std_logic;
    -- Seleção do chip, ativa em '0'.
    o_dram_cs_n  : out std_logic;
    -- Strobe de endereço de linha, ativo em '0'.
    o_dram_ras_n : out std_logic;
    -- Strobe de endereço de coluna, ativo em '0'.
    o_dram_cas_n : out std_logic;
    -- Habilita de escrita, ativo em '0'.
    o_dram_we_n  : out std_logic;
    -- Seleção do banco.
    o_dram_ba    : out std_logic_vector(1 downto 0);
    -- Endereço de linha ou de coluna.
    o_dram_addr  : out std_logic_vector(12 downto 0);
    -- Máscara de bytes dos dados (um bit por byte).
    o_dram_dqm   : out std_logic_vector(1 downto 0);
    -- Dado que o controlador coloca nos pinos DQ.
    o_dram_dq_out : out std_logic_vector(15 downto 0);
    -- O controlador dirige os pinos DQ ('1').
    o_dram_dq_oe  : out std_logic;
    -- Dado lido dos pinos DQ.
    i_dram_dq_in  : in  std_logic_vector(15 downto 0)
  );
end entity sdram_ctrl;

architecture rtl of sdram_ctrl is

  -- (o máximo do VHDL-2008 não é aceito pelo Quartus)
  function larger (a, b : natural) return natural is
  begin
    if a > b then
      return a;
    end if;
    return b;
  end function;

  -- ACTIVE até READ/WRITE, em ciclos.
  constant C_RCD : natural := cycles(T_RCD_PS, tck_ps);
  -- PRECHARGE até ACTIVE, em ciclos.
  constant C_RP  : natural := cycles(T_RP_PS, tck_ps);
  -- ACTIVE até ACTIVE no mesmo banco, em ciclos.
  constant C_RC  : natural := cycles(T_RC_PS, tck_ps);
  -- AUTO REFRESH até qualquer comando, em ciclos.
  constant C_RFC : natural := cycles(T_RFC_PS, tck_ps);
  -- Último dado de escrita até PRECHARGE, em ciclos.
  constant C_WR  : natural := cycles(T_WR_PS, tck_ps);
  -- ACTIVE até o próximo ACTIVE de um acesso de página fechada: o maior entre tRC e o caminho de leitura (ACTIVE, tRCD, latência CAS, dois beats e um clock de folga); o caminho de escrita (tRCD, dois beats, tWR, tRP) nunca é mais longo.
  constant ACT_TO_ACT : natural :=
    larger(C_RC, larger(C_RCD + CAS_LATENCY + 4, C_RCD + 2 + C_WR + C_RP));
  -- O mesmo intervalo para uma linha: o último comando sai seis clocks depois do primeiro e o último beat dois clocks depois dele.
  constant ACT_TO_ACT_LINE : natural :=
    larger(C_RC, larger(C_RCD + 6 + CAS_LATENCY + 4, C_RCD + 8 + C_WR + C_RP));

  -- Estados do controlador: sequência de inicialização, espera, comando e leitura ou escrita.
  type state_t is (ST_INIT_WAIT, ST_INIT_PRE, ST_INIT_REF, ST_INIT_MRS, ST_WAIT,
                   ST_IDLE, ST_RW, ST_READ, ST_WRITE2, ST_RDGAP);
  -- Estado atual do controlador.
  signal st  : state_t := ST_INIT_WAIT;
  -- Estado seguinte, depois de a contagem de espera terminar.
  signal nxt : state_t := ST_INIT_WAIT;

  -- Contador de ciclos da espera corrente.
  signal wcnt     : natural range 0 to 2**18 - 1 := 0;
  -- Clocks até o próximo ACTIVE ser permitido.
  signal act_cnt  : natural range 0 to 63 := 0;
  -- Contador do intervalo entre refreshes.
  signal ref_cnt  : natural range 0 to 2**14 - 1 := 0;
  -- Um refresh está devido.
  signal ref_due  : std_logic := '0';
  -- Refreshes já emitidos na sequência de energização.
  signal init_ref : natural range 0 to INIT_REFRESHES := 0;

  -- Toggle de pedido do core, sincronizado com i_clk.
  signal req_sync : std_logic_vector(0 downto 0);
  -- Toggle de pedido sobre o qual o controlador age.
  signal req_eff  : std_logic;
  -- Toggle de confirmação (registrado).
  signal ack_i    : std_logic := '0';
  -- Toggle do pedido em atendimento.
  signal tog_l    : std_logic := '0';

  -- Escrita do pedido em atendimento.
  signal we_l     : std_logic := '0';
  -- Endereço do pedido em atendimento.
  signal addr_l   : std_logic_vector(23 downto 0) := (others => '0');
  -- Dado de escrita do pedido em atendimento.
  signal wdata_l  : std_logic_vector(31 downto 0) := (others => '0');
  -- Habilita de bytes do pedido em atendimento.
  signal be_l     : std_logic_vector(3 downto 0) := (others => '0');
  -- Clocks desde o primeiro comando READ.
  signal rd_t     : natural range 0 to 31 := 0;
  -- O dado lido está sendo amostrado.
  signal rd_run   : std_logic := '0';
  -- Dado lido da palavra 0 (registrado).
  signal rdata_i  : std_logic_vector(31 downto 0) := (others => '0');
  -- Palavras 1 a 3 lidas (registradas).
  signal rdx_i    : std_logic_vector(95 downto 0) := (others => '0');
  -- O pedido em atendimento é de linha.
  signal line_l   : std_logic := '0';
  -- Palavras 1 a 3 de escrita do pedido em atendimento.
  signal wdx_l    : std_logic_vector(95 downto 0) := (others => '0');
  -- Habilita de bytes das palavras 1 a 3 do pedido em atendimento.
  signal bex_l    : std_logic_vector(11 downto 0) := (others => '0');
  -- Palavra da linha para a qual vai o próximo comando.
  signal lcnt     : natural range 0 to 3 := 0;
  -- A inicialização terminou (registrado).
  signal init_i   : std_logic := '0';

begin

  -- Leva o toggle de pedido do clock do core ao do controlador (sem uso quando sync_req = false).
  u_sync_req : entity work.synchronizer
    port map (
      i_clk  => i_clk,
      i_rst  => i_rst,
      i_d(0) => i_req_tog,
      o_d    => req_sync
    );

  o_ack_tog   <= ack_i;
  req_eff   <= req_sync(0) when sync_req else i_req_tog;
  o_init_done <= init_i;
  o_rdata     <= rdata_i;
  o_rdata_x   <= rdx_i;
  o_dram_cke  <= '1';

  process (i_clk)
    -- Comando de quatro bits (cs_n & ras_n & cas_n & we_n) emitido neste clock.
    variable cmd : std_logic_vector(3 downto 0);

    -- estado seguinte depois de n clocks: o comando saiu nesta borda, o seguinte
    -- sai n bordas depois
    procedure goto_after (n : natural; target : state_t) is
    begin
      if n <= 1 then
        st <= target;
      else
        st   <= ST_WAIT;
        nxt  <= target;
        wcnt <= n - 1;
      end if;
    end procedure;
    function to_unsigned_bit (b : boolean) return std_logic is
    begin
      if b then
        return '1';
      end if;
      return '0';
    end function;
  begin
    if rising_edge(i_clk) then
      cmd := CMD_NOP;
      o_dram_ba     <= "00";
      o_dram_addr   <= (others => '0');
      o_dram_dqm    <= "00";
      o_dram_dq_oe  <= '0';
      o_dram_dq_out <= (others => '0');

      if act_cnt /= 0 then
        act_cnt <= act_cnt - 1;
      end if;

      if i_rst = '1' then
        st       <= ST_INIT_WAIT;
        wcnt     <= init_cycles;
        act_cnt  <= 0;
        ref_cnt  <= refresh_cycles;
        ref_due  <= '0';
        init_ref <= 0;
        ack_i    <= '0';
        tog_l    <= '0';
        init_i   <= '0';
        rd_run   <= '0';
        lcnt     <= 0;
      else
        -- temporizador de refresh: um AUTO REFRESH é devido a cada refresh_cycles clocks
        if init_i = '1' then
          if ref_cnt = 0 then
            ref_due <= '1';
            ref_cnt <= refresh_cycles;
          else
            ref_cnt <= ref_cnt - 1;
          end if;
        end if;

        -- amostragem do dado lido: o beat m (0 a 7) está nos pinos no ciclo que termina na borda
        -- em que rd_t = CL + 2 + m; o último beat responde ao pedido
        if rd_run = '1' then
          rd_t <= rd_t + 1;
          for m in 0 to 7 loop
            if rd_t = CAS_LATENCY + 2 + capture_extra + m then
              if m = 0 then
                rdata_i(15 downto 0) <= i_dram_dq_in;
              elsif m = 1 then
                rdata_i(31 downto 16) <= i_dram_dq_in;
              else
                rdx_i(16 * (m - 2) + 15 downto 16 * (m - 2)) <= i_dram_dq_in;
              end if;
              if (line_l = '0' and m = 1) or m = 7 then
                ack_i  <= tog_l;
                rd_run <= '0';
                st     <= ST_IDLE;
              end if;
            end if;
          end loop;
        end if;

        case st is

          when ST_INIT_WAIT =>
            if wcnt <= 1 then
              st <= ST_INIT_PRE;
            else
              wcnt <= wcnt - 1;
            end if;

          when ST_INIT_PRE =>
            cmd := CMD_PRECHARGE;
            o_dram_addr(10) <= '1';                 -- todos os bancos
            goto_after(C_RP, ST_INIT_REF);

          when ST_INIT_REF =>
            cmd := CMD_REFRESH;
            if init_ref = INIT_REFRESHES - 1 then
              goto_after(C_RFC, ST_INIT_MRS);
            else
              init_ref <= init_ref + 1;
              goto_after(C_RFC, ST_INIT_REF);
            end if;

          when ST_INIT_MRS =>
            cmd := CMD_LOAD_MODE;
            o_dram_addr <= MODE_REG;
            init_i    <= '1';
            ref_cnt   <= refresh_cycles;
            act_cnt   <= T_MRD_CK;
            goto_after(T_MRD_CK, ST_IDLE);

          when ST_WAIT =>
            if wcnt <= 1 then
              st <= nxt;
            else
              wcnt <= wcnt - 1;
            end if;

          when ST_IDLE =>
            if ref_due = '1' and act_cnt = 0 then
              cmd     := CMD_REFRESH;
              ref_due <= '0';
              act_cnt <= C_RFC;
              goto_after(C_RFC, ST_IDLE);
            elsif req_eff /= ack_i and act_cnt = 0 then
              -- os barramentos de pedido estão estáveis desde a inversão de req_tog
              tog_l   <= req_eff;
              we_l    <= i_we;
              addr_l  <= i_addr;
              wdata_l <= i_wdata;
              be_l    <= i_be;
              line_l  <= i_line;
              wdx_l   <= i_wdata_x;
              bex_l   <= i_be_x;
              lcnt    <= 0;
              cmd     := CMD_ACTIVE;
              o_dram_ba   <= i_addr(10 downto 9);
              o_dram_addr <= i_addr(23 downto 11);
              if i_line = '1' then
                act_cnt <= ACT_TO_ACT_LINE;
              else
                act_cnt <= ACT_TO_ACT;
              end if;
              goto_after(C_RCD, ST_RW);
            end if;

          when ST_RW =>
            -- a coluna da palavra lcnt de uma linha (uma palavra avulsa mantém a sua coluna); auto-precharge
            -- no último comando
            o_dram_ba <= addr_l(10 downto 9);
            if line_l = '1' then
              o_dram_addr <= "00" & to_unsigned_bit(lcnt = 3) & addr_l(8 downto 2) & std_logic_vector(to_unsigned(lcnt, 2)) & '0';
            else
              o_dram_addr <= "00" & '1' & addr_l(8 downto 0) & '0';   -- A10 = auto-precharge
            end if;
            if we_l = '1' then
              cmd := CMD_WRITE;
              if lcnt = 0 then
                o_dram_dq_out <= wdata_l(15 downto 0);
                o_dram_dqm    <= not be_l(1 downto 0);
              else
                o_dram_dq_out <= wdx_l(32 * (lcnt - 1) + 15 downto 32 * (lcnt - 1));
                o_dram_dqm    <= not bex_l(4 * (lcnt - 1) + 1 downto 4 * (lcnt - 1));
              end if;
              o_dram_dq_oe  <= '1';
              st <= ST_WRITE2;
            else
              cmd := CMD_READ;
              if lcnt = 0 then
                rd_t   <= 1;
                rd_run <= '1';
              end if;
              if line_l = '1' and lcnt /= 3 then
                st <= ST_RDGAP;
              else
                st <= ST_READ;
              end if;
            end if;

          when ST_RDGAP =>
            lcnt <= lcnt + 1;
            st   <= ST_RW;

          when ST_WRITE2 =>
            if lcnt = 0 then
              o_dram_dq_out <= wdata_l(31 downto 16);
              o_dram_dqm    <= not be_l(3 downto 2);
            else
              o_dram_dq_out <= wdx_l(32 * (lcnt - 1) + 31 downto 32 * (lcnt - 1) + 16);
              o_dram_dqm    <= not bex_l(4 * (lcnt - 1) + 3 downto 4 * (lcnt - 1) + 2);
            end if;
            o_dram_dq_oe  <= '1';
            if line_l = '1' and lcnt /= 3 then
              lcnt <= lcnt + 1;
              st   <= ST_RW;
            else
              ack_i <= tog_l;
              st    <= ST_IDLE;
            end if;

          when ST_READ =>
            null;    -- a amostragem acima o encerra

        end case;
      end if;

      o_dram_cs_n  <= cmd(3);
      o_dram_ras_n <= cmd(2);
      o_dram_cas_n <= cmd(1);
      o_dram_we_n  <= cmd(0);
    end if;
  end process;

end architecture rtl;
