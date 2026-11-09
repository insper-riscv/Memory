-- =============================================================================
-- Controlador da SDRAM SDR
--
-- A largura do barramento de dados (dq_width) e as larguras de linha, banco e
-- coluna do chip são generics, e o padrão é o chip de 32M x 16 da DE0-CV (16
-- bits, 13 de linha, 2 de banco, 10 de coluna). Um pedido move uma palavra de 32
-- bits como uma rajada de 32 / dq_width beats: dois de 16 bits no padrão, um de
-- 32 bits com dq_width igual a 32 (a rajada do registrador de modo acompanha). A política é de página fechada: todo acesso ativa a sua linha e lê ou
-- escreve com auto-precharge, de modo que nenhuma linha fica aberta e a ordem
-- dos comandos nunca depende do acesso anterior.
--
-- Interface de pedido (handshake por alternância, que atravessa domínios de
-- clock com segurança): o requisitante coloca we/addr/wdata/be e inverte
-- req_tog; o controlador inverte ack_tog quando a palavra foi movida (dado lido
-- válido em rdata, ou dado de escrita entregue ao chip). we/addr/wdata/be ficam
-- estáveis da inversão de req_tog até a de ack_tog. req_tog é sincronizado aqui,
-- então pode vir de outro clock. addr é o endereço de palavra de 32 bits: linha
-- (row_bits) & banco (bank_bits) & coluna da palavra (col_bits menos o bit que a
-- rajada de dois beats percorre: 9 no padrão).
--
-- Um pedido de linha (line = '1') move quatro palavras, os 16 bytes que começam
-- no endereço dado (seus dois bits baixos são ignorados), em uma única abertura
-- da linha: ACTIVE, quatro comandos READ ou WRITE com dois clocks de intervalo
-- (o último com auto-precharge) e oito beats nos pinos de dados sem intervalo
-- (quatro beats com dq_width igual a 32, um comando por clock).
-- A palavra 0 viaja em wdata/be/rdata e as palavras 1 a 3 em
-- wdata_x/be_x/rdata_x (32 bits cada, a palavra 1 nos bits mais baixos). As
-- quatro palavras estão na mesma linha porque a linha é alinhada em 16 bytes.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;
use work.chip_timing_pkg.max_natural;

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
        sync_req       : boolean := true;
        -- Largura do barramento de dados DQ do chip, em bits (16 ou 32).
        dq_width       : natural := 16;
        -- Bits do endereço de linha do chip.
        row_bits       : natural := 13;
        -- Bits do endereço de banco do chip.
        bank_bits      : natural := 2;
        -- Bits do endereço de coluna do chip (no máximo 10, o A10 é o auto-precharge).
        col_bits       : natural := 10
    );
    port (
        -- Clock do módulo.
        i_clk : in    std_logic;
        -- Reset, ativo em '1'.
        i_rst : in    std_logic;

        -- Alternância que pede um acesso: cada inversão é um pedido novo.
        i_req_tog   : in    std_logic;
        -- Alternância que confirma o acesso: igual a i_req_tog quando o pedido foi atendido.
        o_ack_tog   : out   std_logic;
        -- A inicialização da SDRAM terminou ('1').
        o_init_done : out   std_logic;
        -- Escrita ('1') ou leitura ('0').
        i_we        : in    std_logic;
        -- Endereço do acesso.
        i_addr      : in    std_logic_vector(dram_word_addr_bits(row_bits, bank_bits, col_bits, dq_width) - 1 downto 0);
        -- Dado de escrita.
        i_wdata     : in    std_logic_vector(31 downto 0);
        -- Habilita de bytes do comando.
        i_be        : in    std_logic_vector(3 downto 0);
        -- Dado lido.
        o_rdata     : out   std_logic_vector(31 downto 0);
        -- Acesso de linha, quatro palavras seguidas ('1').
        i_line      : in    std_logic                     := '0';
        -- Palavras 1 a 3 do dado de escrita da linha.
        i_wdata_x   : in    std_logic_vector(95 downto 0) := (others => '0');
        -- Habilita de bytes das palavras 1 a 3 da escrita de linha.
        i_be_x      : in    std_logic_vector(11 downto 0) := (others => '0');
        -- Palavras 1 a 3 do dado lido da linha.
        o_rdata_x   : out   std_logic_vector(95 downto 0);

        -- Habilita de clock (CKE) do chip.
        o_dram_cke    : out   std_logic;
        -- Seleção do chip, ativa em '0'.
        o_dram_cs_n   : out   std_logic;
        -- Strobe de endereço de linha, ativo em '0'.
        o_dram_ras_n  : out   std_logic;
        -- Strobe de endereço de coluna, ativo em '0'.
        o_dram_cas_n  : out   std_logic;
        -- Habilita de escrita, ativo em '0'.
        o_dram_we_n   : out   std_logic;
        -- Seleção do banco.
        o_dram_ba     : out   std_logic_vector(bank_bits - 1 downto 0);
        -- Endereço de linha ou de coluna.
        o_dram_addr   : out   std_logic_vector(dram_a_bits(row_bits, col_bits) - 1 downto 0);
        -- Máscara de bytes dos dados (um bit por byte).
        o_dram_dqm    : out   std_logic_vector(dq_width / 8 - 1 downto 0);
        -- Dado que o controlador coloca nos pinos DQ.
        o_dram_dq_out : out   std_logic_vector(dq_width - 1 downto 0);
        -- O controlador dirige os pinos DQ ('1').
        o_dram_dq_oe  : out   std_logic;
        -- Dado lido dos pinos DQ.
        i_dram_dq_in  : in    std_logic_vector(dq_width - 1 downto 0)
    );
end entity sdram_ctrl;

architecture rtl of sdram_ctrl is

    -- Beats de dados por palavra de 32 bits (a rajada do chip).
    constant BEATS     : natural                               := dram_beats(dq_width);
    -- Bits do endereço de palavra do pedido.
    constant ADDR_BITS : natural                               := dram_word_addr_bits(row_bits, bank_bits, col_bits, dq_width);
    -- Bits da coluna da palavra (a coluna do chip sem os bits que a rajada percorre).
    constant WCOL      : natural                               := ADDR_BITS - row_bits - bank_bits;
    -- Bits do barramento de endereço do chip.
    constant A_BITS    : natural                               := dram_a_bits(row_bits, col_bits);
    -- Bytes do barramento DQ (largura da máscara DQM).
    constant DQB       : natural                               := dq_width / 8;
    -- Registrador de modo da rajada desta largura, no barramento de endereço do chip.
    constant MODE_A    : std_logic_vector(A_BITS - 1 downto 0) := dram_fit_a(dram_mode_register(dq_width), A_BITS);

    -- ACTIVE até READ/WRITE, em ciclos.
    constant C_RCD           : natural := cycles(T_RCD_PS, tck_ps);
    -- PRECHARGE até ACTIVE, em ciclos.
    constant C_RP            : natural := cycles(T_RP_PS, tck_ps);
    -- ACTIVE até ACTIVE no mesmo banco, em ciclos.
    constant C_RC            : natural := cycles(T_RC_PS, tck_ps);
    -- AUTO REFRESH até qualquer comando, em ciclos.
    constant C_RFC           : natural := cycles(T_RFC_PS, tck_ps);
    -- Último dado de escrita até PRECHARGE, em ciclos.
    constant C_WR            : natural := cycles(T_WR_PS, tck_ps);
    -- ACTIVE até o próximo ACTIVE de um acesso de página fechada: o maior entre tRC e o caminho de leitura (ACTIVE, tRCD, latência CAS, os beats e um clock de folga); o caminho de escrita (tRCD, os beats, tWR, tRP) nunca é mais longo.
    constant ACT_TO_ACT      : natural :=
        max_natural(C_RC, max_natural(C_RCD + CAS_LATENCY + BEATS + 2, C_RCD + BEATS + C_WR + C_RP));
    -- O mesmo intervalo para uma linha: o último comando sai três palavras de beats depois do primeiro e o último beat dois clocks depois dele.
    constant ACT_TO_ACT_LINE : natural :=
        max_natural(C_RC,
            max_natural(C_RCD + 3 * BEATS + CAS_LATENCY + BEATS + 2,
                C_RCD + 4 * BEATS + C_WR + C_RP));

    -- Coluna do chip do comando READ ou WRITE: a coluna da palavra (ou a da palavra lcnt da linha) seguida dos bits que a rajada percorre.

    function chip_col (colword : std_logic_vector; lcnt : natural; line : std_logic) return std_logic_vector is

        -- Coluna montada do chip.
        variable col : std_logic_vector(col_bits - 1 downto 0) := (others => '0');

    begin

        if line = '1' then
            col(col_bits - 1 downto col_bits - WCOL + 2)    := colword(WCOL - 1 downto 2);
            col(col_bits - WCOL + 1 downto col_bits - WCOL) := std_logic_vector(to_unsigned(lcnt, 2));
        else
            col(col_bits - 1 downto col_bits - WCOL) := colword;
        end if;

        return col;

    end function chip_col;

    -- Estados do controlador: sequência de inicialização, espera, comando e leitura ou escrita.
    type state_t is (
        ST_INIT_WAIT, ST_INIT_PRE, ST_INIT_REF, ST_INIT_MRS, ST_WAIT,
        ST_IDLE, ST_RW, ST_READ, ST_WRITE2, ST_RDGAP
    );

    -- Estado atual do controlador.
    signal st  : state_t := ST_INIT_WAIT;
    -- Estado seguinte, depois de a contagem de espera terminar.
    signal nxt : state_t := ST_INIT_WAIT;

    -- Contador de ciclos da espera corrente.
    signal wcnt     : natural range 0 to 2 ** 18 - 1    := 0;
    -- Clocks até o próximo ACTIVE ser permitido.
    signal act_cnt  : natural range 0 to 63             := 0;
    -- Contador do intervalo entre refreshes.
    signal ref_cnt  : natural range 0 to 2 ** 14 - 1    := 0;
    -- Um refresh está devido.
    signal ref_due  : std_logic                         := '0';
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
    signal we_l    : std_logic                                := '0';
    -- Endereço do pedido em atendimento.
    signal addr_l  : std_logic_vector(ADDR_BITS - 1 downto 0) := (others => '0');
    -- Dado de escrita do pedido em atendimento.
    signal wdata_l : std_logic_vector(31 downto 0)            := (others => '0');
    -- Habilita de bytes do pedido em atendimento.
    signal be_l    : std_logic_vector(3 downto 0)             := (others => '0');
    -- Clocks desde o primeiro comando READ.
    signal rd_t    : natural range 0 to 31                    := 0;
    -- O dado lido está sendo amostrado.
    signal rd_run  : std_logic                                := '0';
    -- Dado lido da palavra 0 (registrado).
    signal rdata_i : std_logic_vector(31 downto 0)            := (others => '0');
    -- Palavras 1 a 3 lidas (registradas).
    signal rdx_i   : std_logic_vector(95 downto 0)            := (others => '0');
    -- O pedido em atendimento é de linha.
    signal line_l  : std_logic                                := '0';
    -- Palavras 1 a 3 de escrita do pedido em atendimento.
    signal wdx_l   : std_logic_vector(95 downto 0)            := (others => '0');
    -- Habilita de bytes das palavras 1 a 3 do pedido em atendimento.
    signal bex_l   : std_logic_vector(11 downto 0)            := (others => '0');
    -- Palavra da linha para a qual vai o próximo comando.
    signal lcnt    : natural range 0 to 3                     := 0;
    -- A inicialização terminou (registrado).
    signal init_i  : std_logic                                := '0';

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
    req_eff     <= req_sync(0) when sync_req else i_req_tog;
    o_init_done <= init_i;
    o_rdata     <= rdata_i;
    o_rdata_x   <= rdx_i;
    o_dram_cke  <= '1';

    process (i_clk) is

        -- Comando de quatro bits (cs_n & ras_n & cas_n & we_n) emitido neste clock.
        variable cmd : std_logic_vector(3 downto 0);

        -- estado seguinte depois de n clocks: o comando saiu nesta borda, o seguinte
        -- sai n bordas depois

        procedure goto_after (
            n      : natural;
            target : state_t
        ) is
        begin

            if n <= 1 then
                st <= target;
            else
                st   <= ST_WAIT;
                nxt  <= target;
                wcnt <= n - 1;
            end if;

        end procedure goto_after;

        function to_unsigned_bit (b : boolean) return std_logic is
        begin

            if b then
                return '1';
            end if;

            return '0';

        end function to_unsigned_bit;

    begin

        if rising_edge(i_clk) then
            cmd           := CMD_NOP;
            o_dram_ba     <= (others => '0');
            o_dram_addr   <= (others => '0');
            o_dram_dqm    <= (others => '0');
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

                    for m in 0 to 4 * BEATS - 1 loop

                        if rd_t = CAS_LATENCY + 2 + capture_extra + m then
                            if m * dq_width < 32 then
                                rdata_i(m * dq_width + dq_width - 1 downto m * dq_width) <= i_dram_dq_in;
                            else
                                rdx_i(m * dq_width - 32 + dq_width - 1 downto m * dq_width - 32) <= i_dram_dq_in;
                            end if;
                            if (line_l = '0' and m = BEATS - 1) or m = 4 * BEATS - 1 then
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

                        cmd             := CMD_PRECHARGE;
                        o_dram_addr(10) <= '1'; -- todos os bancos
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

                        cmd         := CMD_LOAD_MODE;
                        o_dram_addr <= MODE_A;
                        init_i      <= '1';
                        ref_cnt     <= refresh_cycles;
                        act_cnt     <= T_MRD_CK;
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
                            tog_l                              <= req_eff;
                            we_l                               <= i_we;
                            addr_l                             <= i_addr;
                            wdata_l                            <= i_wdata;
                            be_l                               <= i_be;
                            line_l                             <= i_line;
                            wdx_l                              <= i_wdata_x;
                            bex_l                              <= i_be_x;
                            lcnt                               <= 0;
                            cmd                                := CMD_ACTIVE;
                            o_dram_ba                          <= i_addr(WCOL + bank_bits - 1 downto WCOL);
                            o_dram_addr(row_bits - 1 downto 0) <= i_addr(ADDR_BITS - 1 downto WCOL + bank_bits);
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
                        o_dram_ba                          <= addr_l(WCOL + bank_bits - 1 downto WCOL);
                        o_dram_addr(col_bits - 1 downto 0) <= chip_col(addr_l(WCOL - 1 downto 0), lcnt, line_l);
                        if line_l = '1' then
                            o_dram_addr(10) <= to_unsigned_bit(lcnt = 3);
                        else
                            o_dram_addr(10) <= '1'; -- A10 = auto-precharge
                        end if;
                        if we_l = '1' then
                            cmd := CMD_WRITE;
                            if lcnt = 0 then
                                o_dram_dq_out <= wdata_l(dq_width - 1 downto 0);
                                o_dram_dqm    <= not be_l(DQB - 1 downto 0);
                            else
                                o_dram_dq_out <= wdx_l(32 * (lcnt - 1) + dq_width - 1 downto 32 * (lcnt - 1));
                                o_dram_dqm    <= not bex_l(4 * (lcnt - 1) + DQB - 1 downto 4 * (lcnt - 1));
                            end if;
                            o_dram_dq_oe <= '1';
                            if BEATS = 2 then
                                st <= ST_WRITE2;
                            elsif line_l = '1' and lcnt /= 3 then
                                lcnt <= lcnt + 1;
                            else
                                ack_i <= tog_l;
                                st    <= ST_IDLE;
                            end if;
                        else
                            cmd := CMD_READ;
                            if lcnt = 0 then
                                rd_t   <= 1;
                                rd_run <= '1';
                            end if;
                            if line_l = '1' and lcnt /= 3 then
                                if BEATS = 2 then
                                    st <= ST_RDGAP;
                                else
                                    lcnt <= lcnt + 1;
                                end if;
                            else
                                st <= ST_READ;
                            end if;
                        end if;

                    when ST_RDGAP =>

                        lcnt <= lcnt + 1;
                        st   <= ST_RW;

                    when ST_WRITE2 =>

                        if lcnt = 0 then
                            o_dram_dq_out <= wdata_l(31 downto 32 - dq_width);
                            o_dram_dqm    <= not be_l(3 downto 4 - DQB);
                        else
                            o_dram_dq_out <= wdx_l(32 * (lcnt - 1) + 31 downto 32 * (lcnt - 1) + 32 - dq_width);
                            o_dram_dqm    <= not bex_l(4 * (lcnt - 1) + 3 downto 4 * (lcnt - 1) + 4 - DQB);
                        end if;
                        o_dram_dq_oe <= '1';
                        if line_l = '1' and lcnt /= 3 then
                            lcnt <= lcnt + 1;
                            st   <= ST_RW;
                        else
                            ack_i <= tog_l;
                            st    <= ST_IDLE;
                        end if;

                    when ST_READ =>

                        null; -- a amostragem acima o encerra

                end case;

            end if;

            o_dram_cs_n  <= cmd(3);
            o_dram_ras_n <= cmd(2);
            o_dram_cas_n <= cmd(1);
            o_dram_we_n  <= cmd(0);
        end if;

    end process;

end architecture rtl;
