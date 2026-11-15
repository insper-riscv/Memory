-- =============================================================================
-- Controlador de barramento da flash interna de usuário do MAX 10 (DE10-Lite)
--
-- Atende o SoC por um banco de registradores de 32 bits e comanda a megafunção
-- de flash on-chip da Altera (altera_onchip_flash) por suas duas interfaces
-- Avalon-MM: a de dados (leitura e escrita de uma palavra, com waitrequest e
-- readdatavalid, burst de uma palavra) e a de CSR (registrador de estado e de
-- controle, sem espera, com a leitura devolvida uma borda depois do pedido).
-- A megafunção não está aqui: o topo liga as portas o_data_* e o_csr_* a ela
-- (o IP da placa em MAX-10/, ou o max10_flash_model na simulação).
--
-- Registradores (índice de palavra em i_address):
--   0 STATUS    leitura: bit 0 ocupado, bit 1 concluído, bit 2 erro, bit 3 escrita
--               habilitada. Escrever '1' nos bits 1 ou 2 limpa o bit.
--   1 CONTROL   bit 0 habilita a interrupção.
--   2 ADDRESS   endereço de palavra no espaço de dados da megafunção.
--   3 DATA      palavra a escrever; depois de uma leitura, a palavra lida.
--   4 SECTOR    número do setor a apagar, de 1 a 5.
--   5 COMMAND   escrita: 1 lê, 2 grava, 3 apaga o setor, 4 habilita escrita e
--               apagamento, 5 desabilita. Qualquer outro código é ignorado.
--   6 IP_STATUS leitura: o registrador de estado bruto da megafunção (10 bits).
--   7           reservado, lê zero.
--
-- Regras. Um comando só é aceito com o controlador livre; um comando que chega
-- ocupado, ou gravar e apagar com a escrita desabilitada, ou apagar um setor
-- fora de 1 a 5 ou fora de erase_allowed, é recusado sem tocar na megafunção e
-- sobe o bit de erro. A megafunção nasce protegida (todos os setores só de
-- leitura): habilitar escrita grava no controle dela a liberação dos cinco
-- setores, e desabilitar grava a proteção. O apagar espera o fim da operação
-- pelo registrador de controle e pelo de estado, e depois protege de novo.
--
-- Fim de operação. O bit de concluído sobe ao fim de todo comando aceito, com
-- o bit de erro se a megafunção acusou falha de leitura, de escrita ou de
-- apagamento. A interrupção é o concluído com a habilitação ligada.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity max10_flash is
    generic (
        -- Largura do endereço de palavra da interface de dados da megafunção (17 bits na 10M50, imagem única).
        data_addr_bits : positive                     := 17;
        -- Setores que o apagar pode atingir; o bit k - 1 libera o setor k (padrão: setores 1 e 2).
        erase_allowed  : std_logic_vector(4 downto 0) := "00011"
    );
    port (
        -- Clock do módulo, o mesmo da megafunção.
        i_clk : in    std_logic;
        -- Reset síncrono, ativo em '1'.
        i_rst : in    std_logic;

        -- Barramento: índice do registrador.
        i_address  : in    std_logic_vector(2 downto 0);
        -- Barramento: escrita no registrador.
        i_write    : in    std_logic;
        -- Barramento: leitura do registrador.
        i_read     : in    std_logic;
        -- Barramento: dado de escrita.
        i_data_in  : in    std_logic_vector(31 downto 0);
        -- Barramento: dado de leitura, combinacional sobre i_address.
        o_data_out : out   std_logic_vector(31 downto 0);
        -- Interrupção: concluído com a habilitação ligada.
        o_irq      : out   std_logic;

        -- Megafunção, dados: pedido de leitura, mantido até a espera cair.
        o_data_read     : out   std_logic;
        -- Megafunção, dados: pedido de escrita, mantido até a espera cair.
        o_data_write    : out   std_logic;
        -- Megafunção, dados: endereço de palavra.
        o_data_addr     : out   std_logic_vector(data_addr_bits - 1 downto 0);
        -- Megafunção, dados: palavra a escrever.
        o_data_wdata    : out   std_logic_vector(31 downto 0);
        -- Megafunção, dados: o pedido ainda não foi aceito ('1').
        i_data_wait     : in    std_logic;
        -- Megafunção, dados: palavra lida válida ('1').
        i_data_rvalid   : in    std_logic;
        -- Megafunção, dados: palavra lida.
        i_data_rdata    : in    std_logic_vector(31 downto 0);

        -- Megafunção, CSR: leitura (a palavra vem uma borda depois).
        o_csr_read  : out   std_logic;
        -- Megafunção, CSR: escrita.
        o_csr_write : out   std_logic;
        -- Megafunção, CSR: registrador, '0' estado e '1' controle.
        o_csr_addr  : out   std_logic;
        -- Megafunção, CSR: palavra a escrever.
        o_csr_wdata : out   std_logic_vector(31 downto 0);
        -- Megafunção, CSR: palavra lida.
        i_csr_rdata : in    std_logic_vector(31 downto 0)
    );
end entity max10_flash;

architecture rtl of max10_flash is

    -- Índice do registrador de estado.
    constant REG_STATUS    : std_logic_vector(2 downto 0) := "000";
    -- Índice do registrador de controle.
    constant REG_CONTROL   : std_logic_vector(2 downto 0) := "001";
    -- Índice do registrador de endereço.
    constant REG_ADDRESS   : std_logic_vector(2 downto 0) := "010";
    -- Índice do registrador de dado.
    constant REG_DATA      : std_logic_vector(2 downto 0) := "011";
    -- Índice do registrador de setor.
    constant REG_SECTOR    : std_logic_vector(2 downto 0) := "100";
    -- Índice do registrador de comando.
    constant REG_COMMAND   : std_logic_vector(2 downto 0) := "101";
    -- Índice do registrador de estado bruto da megafunção.
    constant REG_IP_STATUS : std_logic_vector(2 downto 0) := "110";

    -- Código do comando ler.
    constant CMD_READ    : std_logic_vector(2 downto 0) := "001";
    -- Código do comando gravar.
    constant CMD_WRITE   : std_logic_vector(2 downto 0) := "010";
    -- Código do comando apagar setor.
    constant CMD_ERASE   : std_logic_vector(2 downto 0) := "011";
    -- Código do comando habilitar escrita.
    constant CMD_ENABLE  : std_logic_vector(2 downto 0) := "100";
    -- Código do comando desabilitar escrita.
    constant CMD_DISABLE : std_logic_vector(2 downto 0) := "101";

    -- Controle da megafunção: setores liberados, nenhum apagar pedido (setor 7 e página toda em um).
    constant CTRL_ENABLE  : std_logic_vector(31 downto 0) := x"007FFFFF";
    -- Controle da megafunção: setores protegidos, nenhum apagar pedido.
    constant CTRL_DISABLE : std_logic_vector(31 downto 0) := x"0FFFFFFF";
    -- Campo de página do apagar de setor, todo em um (o apagar de página fica desligado).
    constant PAGE_NOT_SET : std_logic_vector(19 downto 0) := (others => '1');

    -- Estados: livre, leitura de dados, escrita de dados, leitura do CSR, escrita de controle e apagar.
    type state_t is (S_IDLE, S_RD_REQ, S_RD_WAIT, S_WR_REQ, S_CSR_ISSUE, S_CSR_CAPTURE, S_CTRL_WRITE, S_FINISH);
    -- Operação em andamento.
    type op_t is (OP_READ, OP_WRITE, OP_ERASE, OP_ENABLE, OP_DISABLE);
    -- Passo da operação de apagar e das demais que consultam o CSR.
    type phase_t is (PH_START, PH_POLL_CTRL, PH_POLL_STATUS, PH_PROTECT, PH_CHECK);

    -- Estado atual.
    signal st        : state_t                      := S_IDLE;
    -- Operação atual.
    signal op        : op_t                         := OP_READ;
    -- Passo atual.
    signal phase     : phase_t                      := PH_START;
    -- Registrador de endereço.
    signal addr_q    : std_logic_vector(data_addr_bits - 1 downto 0) := (others => '0');
    -- Registrador de dado.
    signal data_q    : std_logic_vector(31 downto 0) := (others => '0');
    -- Registrador de setor.
    signal sector_q  : std_logic_vector(2 downto 0)  := (others => '0');
    -- Palavra de controle que a escrita no CSR leva.
    signal ctrl_q    : std_logic_vector(31 downto 0) := (others => '0');
    -- Último estado bruto lido da megafunção.
    signal ipst_q    : std_logic_vector(9 downto 0)  := (others => '0');
    -- Escrita e apagamento habilitados.
    signal wen       : std_logic                     := '0';
    -- Concluído, preso até ser limpo.
    signal done      : std_logic                     := '0';
    -- Erro, preso até ser limpo.
    signal err       : std_logic                     := '0';
    -- Interrupção habilitada.
    signal irq_en    : std_logic                     := '0';
    -- A operação em andamento falhou.
    signal op_failed : std_logic                     := '0';

begin

    -- Leitura dos registradores.
    p_read : process (all) is
    begin
        o_data_out <= (others => '0');
        case i_address is
            when REG_STATUS =>
                if st /= S_IDLE then
                    o_data_out(0) <= '1';
                end if;
                o_data_out(1) <= done;
                o_data_out(2) <= err;
                o_data_out(3) <= wen;
            when REG_CONTROL =>
                o_data_out(0) <= irq_en;
            when REG_ADDRESS =>
                o_data_out(data_addr_bits - 1 downto 0) <= addr_q;
            when REG_DATA =>
                o_data_out <= data_q;
            when REG_SECTOR =>
                o_data_out(2 downto 0) <= sector_q;
            when REG_IP_STATUS =>
                o_data_out(9 downto 0) <= ipst_q;
            when others =>
                null;
        end case;
    end process p_read;

    o_irq <= done and irq_en;

    -- Saídas para a megafunção, derivadas só do estado.
    o_data_read  <= '1' when st = S_RD_REQ else '0';
    o_data_write <= '1' when st = S_WR_REQ else '0';
    o_data_addr  <= addr_q;
    o_data_wdata <= data_q;
    o_csr_read   <= '1' when st = S_CSR_ISSUE else '0';
    o_csr_write  <= '1' when st = S_CTRL_WRITE else '0';
    o_csr_addr   <= '1' when (st = S_CTRL_WRITE or (st = S_CSR_ISSUE and phase = PH_POLL_CTRL)) else '0';
    o_csr_wdata  <= ctrl_q;

    -- Máquina de comandos.
    p_fsm : process (i_clk) is
        -- Setor pedido, como inteiro.
        variable sec     : natural range 0 to 7;
        -- Código do comando de entrada.
        variable cmd     : std_logic_vector(2 downto 0);
        -- Comando aceito.
        variable accept  : boolean;
        -- Comando recusado.
        variable refuse  : boolean;
        -- O setor pedido está entre 1 e 5 e liberado em erase_allowed.
        variable permit  : boolean;
    begin
        if rising_edge(i_clk) then
            if i_rst = '1' then
                st        <= S_IDLE;
                op        <= OP_READ;
                phase     <= PH_START;
                wen       <= '0';
                done      <= '0';
                err       <= '0';
                irq_en    <= '0';
                op_failed <= '0';
                addr_q    <= (others => '0');
                data_q    <= (others => '0');
                sector_q  <= (others => '0');
                ctrl_q    <= CTRL_DISABLE;
                ipst_q    <= (others => '0');
            else
                -- Escritas de registrador, que valem em qualquer estado.
                if i_write = '1' then
                    case i_address is
                        when REG_STATUS =>
                            if i_data_in(1) = '1' then
                                done <= '0';
                            end if;
                            if i_data_in(2) = '1' then
                                err <= '0';
                            end if;
                        when REG_CONTROL =>
                            irq_en <= i_data_in(0);
                        when REG_ADDRESS =>
                            if st = S_IDLE then
                                addr_q <= i_data_in(data_addr_bits - 1 downto 0);
                            end if;
                        when REG_DATA =>
                            if st = S_IDLE then
                                data_q <= i_data_in;
                            end if;
                        when REG_SECTOR =>
                            if st = S_IDLE then
                                sector_q <= i_data_in(2 downto 0);
                            end if;
                        when REG_COMMAND =>
                            if st /= S_IDLE then
                                err <= '1';
                            end if;
                        when others =>
                            null;
                    end case;
                end if;

                case st is
                    when S_IDLE =>
                        cmd    := i_data_in(2 downto 0);
                        sec    := to_integer(unsigned(sector_q));
                        accept := false;
                        refuse := false;
                        if i_write = '1' and i_address = REG_COMMAND then
                            case cmd is
                                when CMD_READ | CMD_ENABLE | CMD_DISABLE =>
                                    accept := true;
                                when CMD_WRITE =>
                                    accept := wen = '1';
                                    refuse := wen = '0';
                                when CMD_ERASE =>
                                    permit := false;
                                    for k in 1 to 5 loop
                                        if sec = k and erase_allowed(k - 1) = '1' then
                                            permit := true;
                                        end if;
                                    end loop;
                                    accept := wen = '1' and permit;
                                    refuse := not accept;
                                when others =>
                                    null;
                            end case;
                        end if;
                        if refuse then
                            err <= '1';
                        end if;
                        if accept then
                            done      <= '0';
                            op_failed <= '0';
                            phase     <= PH_START;
                            case cmd is
                                when CMD_READ =>
                                    op <= OP_READ;
                                    st <= S_RD_REQ;
                                when CMD_WRITE =>
                                    op <= OP_WRITE;
                                    st <= S_WR_REQ;
                                when CMD_ERASE =>
                                    op     <= OP_ERASE;
                                    ctrl_q <= CTRL_ENABLE(31 downto 23) & sector_q & PAGE_NOT_SET;
                                    st     <= S_CTRL_WRITE;
                                when CMD_ENABLE =>
                                    op     <= OP_ENABLE;
                                    ctrl_q <= CTRL_ENABLE;
                                    st     <= S_CTRL_WRITE;
                                when others =>
                                    op     <= OP_DISABLE;
                                    ctrl_q <= CTRL_DISABLE;
                                    st     <= S_CTRL_WRITE;
                            end case;
                        end if;
                    when S_RD_REQ =>
                        if i_data_wait = '0' then
                            st <= S_RD_WAIT;
                        end if;
                    when S_RD_WAIT =>
                        if i_data_rvalid = '1' then
                            data_q <= i_data_rdata;
                            phase  <= PH_CHECK;
                            st     <= S_CSR_ISSUE;
                        end if;
                    when S_WR_REQ =>
                        if i_data_wait = '0' then
                            phase <= PH_CHECK;
                            st    <= S_CSR_ISSUE;
                        end if;
                    when S_CTRL_WRITE =>
                        case op is
                            when OP_ERASE =>
                                phase <= PH_POLL_CTRL;
                                st    <= S_CSR_ISSUE;
                            when others =>
                                if op = OP_ENABLE then
                                    wen <= '1';
                                else
                                    wen <= '0';
                                end if;
                                st <= S_FINISH;
                        end case;
                    when S_CSR_ISSUE =>
                        st <= S_CSR_CAPTURE;
                    when S_CSR_CAPTURE =>
                        case phase is
                            when PH_POLL_CTRL =>
                                -- Apagar pendente ou em andamento: bits 31 e 30 do controle.
                                if i_csr_rdata(31 downto 30) = "00" then
                                    phase <= PH_POLL_STATUS;
                                end if;
                                st <= S_CSR_ISSUE;
                            when others =>
                                ipst_q <= i_csr_rdata(9 downto 0);
                                if i_csr_rdata(1 downto 0) /= "00" then
                                    st <= S_CSR_ISSUE;
                                else
                                    case op is
                                        when OP_READ =>
                                            op_failed <= not i_csr_rdata(2);
                                            st        <= S_FINISH;
                                        when OP_WRITE =>
                                            op_failed <= not i_csr_rdata(3);
                                            st        <= S_FINISH;
                                        when others =>
                                            op_failed <= not i_csr_rdata(4);
                                            ctrl_q    <= CTRL_DISABLE;
                                            op        <= OP_DISABLE;
                                            phase     <= PH_PROTECT;
                                            st        <= S_CTRL_WRITE;
                                    end case;
                                end if;
                        end case;
                    when S_FINISH =>
                        done <= '1';
                        err  <= err or op_failed;
                        st   <= S_IDLE;
                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;
