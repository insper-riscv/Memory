-- =============================================================================
-- Registradores, guarda de região e sequenciador do acesso de usuário à flash EPCS
--
-- É a face de barramento do epcs_ctrl: recebe os comandos do software, confere que
-- cada um é seguro para o bitstream e o entrega ao mestre SPI (epcs_spi) por um
-- enlace de pedido, recepção e envio de bytes. Mantém o buffer de uma página
-- (256 bytes), que o READ preenche e o PP envia.
--
-- Registradores (índice de palavra em i_address):
--   0 STATUS     leitura: bit 0 ocupado, bit 1 concluído, bit 2 erro, bit 3 escrita
--                habilitada (WREN concluído), bit 4 operação em andamento no chip
--                (WIP do último RDSR), bits 15 a 8 último registrador de estado
--                lido. Escrever '1' nos bits 1 ou 2 limpa o bit.
--   1 CONTROL    bit 0 habilita a interrupção, bit 1 usa FAST_READ no READ.
--   2 ADDRESS    endereço de byte de 24 bits.
--   3 LENGTH     bytes de dado do READ e do PP, de 1 a 256.
--   4 COMMAND    escrita: 1 RDID, 2 RDSR, 3 WREN, 4 READ, 5 PP (grava a página),
--                6 SE (apaga o setor). Outro código é ignorado.
--   5 ID         leitura: o RDID, fabricante nos bits 23 a 16, tipo e capacidade.
--   6 USER_BASE  leitura: endereço do início da região de usuário.
--   7 SIZE       leitura: tamanho do chip em bytes.
--   8 BUFIDX     índice de palavra do buffer, de 0 a 63.
--   9 BUFDATA    leitura e escrita da palavra do buffer em BUFIDX; cada acesso
--                avança BUFIDX. O valor de uma leitura reflete o índice de dois
--                ciclos antes: deixe dois ciclos entre acessos seguidos. O byte 0 da
--                página fica nos bits 7 a 0 da palavra 0.
--
-- Guarda. A região de usuário vai de user_base ao fim do chip, e o bitstream de
-- configuração fica abaixo dela. Gravar e apagar fora dela, sem WREN concluído, com
-- o controlador ocupado ou com tamanho que sai da página é recusado, sobe o bit de erro,
-- derruba a escrita habilitada e não gera nenhum quadro SPI. A leitura vale em
-- todo o chip. O WREN sobe a escrita habilitada ao concluir; um PP ou SE
-- aceito a derruba, depois de esperar o bit WIP do chip cair por RDSR repetido. O apagar
-- alinha o endereço ao setor. Um comando novo com o controlador ocupado sobe o erro.
--
-- Buffer e janela. O buffer só é acessível com o controlador livre: com ele
-- ocupado, a leitura de BUFDATA devolve zero e a escrita é ignorada.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity epcs_cmd is
    generic (
        -- Tamanho do chip em bytes (8388608 é a EPCS64).
        size_bytes   : positive                       := 8388608;
        -- Início da região de usuário em bytes, múltiplo do setor; abaixo dele fica o bitstream.
        user_base    : natural                        := 4194304
    );
    port (
        -- Clock do módulo.
        i_clk : in    std_logic;
        -- Reset síncrono, ativo em '1'.
        i_rst : in    std_logic;

        -- Barramento: índice do registrador.
        i_address  : in    std_logic_vector(3 downto 0);
        -- Barramento: escrita no registrador.
        i_write    : in    std_logic;
        -- Barramento: leitura do registrador.
        i_read     : in    std_logic;
        -- Barramento: dado de escrita.
        i_data_in  : in    std_logic_vector(31 downto 0);
        -- Barramento: dado de leitura.
        o_data_out : out   std_logic_vector(31 downto 0);
        -- Interrupção: concluído com a habilitação ligada.
        o_irq      : out   std_logic;

        -- Enlace: pulso de pedido de um quadro.
        o_req  : out   std_logic;
        -- Enlace: código da operação do epcs_spi.
        o_op   : out   std_logic_vector(2 downto 0);
        -- Enlace: endereço de byte.
        o_addr : out   std_logic_vector(23 downto 0);
        -- Enlace: bytes de dado.
        o_len  : out   std_logic_vector(8 downto 0);
        -- Enlace: o mestre SPI está ocupado.
        i_busy : in    std_logic;
        -- Enlace: pulso de fim do quadro.
        i_done : in    std_logic;

        -- Enlace: byte recebido válido.
        i_rx_valid : in    std_logic;
        -- Enlace: índice do byte recebido.
        i_rx_idx   : in    std_logic_vector(7 downto 0);
        -- Enlace: byte recebido.
        i_rx_data  : in    std_logic_vector(7 downto 0);

        -- Enlace: índice do byte a enviar.
        i_tx_idx  : in    std_logic_vector(7 downto 0);
        -- Enlace: byte a enviar, válido duas bordas depois do índice.
        o_tx_data : out   std_logic_vector(7 downto 0)
    );
end entity epcs_cmd;

architecture rtl of epcs_cmd is

    -- Códigos de operação do epcs_spi.
    constant LINK_RDID      : std_logic_vector(2 downto 0) := "001";
    -- Código de operação RDSR do epcs_spi.
    constant LINK_RDSR      : std_logic_vector(2 downto 0) := "010";
    -- Código de operação WREN do epcs_spi.
    constant LINK_WREN      : std_logic_vector(2 downto 0) := "011";
    -- Código de operação READ do epcs_spi.
    constant LINK_READ      : std_logic_vector(2 downto 0) := "100";
    -- Código de operação FAST_READ do epcs_spi.
    constant LINK_FAST_READ : std_logic_vector(2 downto 0) := "101";
    -- Código de operação PP do epcs_spi.
    constant LINK_PP        : std_logic_vector(2 downto 0) := "110";
    -- Código de operação SE do epcs_spi.
    constant LINK_SE        : std_logic_vector(2 downto 0) := "111";

    -- Códigos dos comandos do registrador COMMAND.
    constant CMD_RDID : std_logic_vector(2 downto 0) := "001";
    -- Código do comando RDSR.
    constant CMD_RDSR : std_logic_vector(2 downto 0) := "010";
    -- Código do comando WREN.
    constant CMD_WREN : std_logic_vector(2 downto 0) := "011";
    -- Código do comando READ.
    constant CMD_READ : std_logic_vector(2 downto 0) := "100";
    -- Código do comando PP.
    constant CMD_PP   : std_logic_vector(2 downto 0) := "101";
    -- Código do comando SE.
    constant CMD_SE   : std_logic_vector(2 downto 0) := "110";

    -- Bytes de uma página de gravação.
    constant PAGE_BYTES   : natural := 256;
    -- Bytes de um setor de apagar.
    constant SECTOR_BYTES : natural := 65536;

    -- Índices dos registradores.
    constant REG_STATUS    : natural := 0;
    -- Índice do registrador de controle.
    constant REG_CONTROL   : natural := 1;
    -- Índice do registrador de endereço.
    constant REG_ADDRESS   : natural := 2;
    -- Índice do registrador de tamanho.
    constant REG_LENGTH    : natural := 3;
    -- Índice do registrador de comando.
    constant REG_COMMAND   : natural := 4;
    -- Índice do registrador de identificação.
    constant REG_ID        : natural := 5;
    -- Índice do registrador do início da região de usuário.
    constant REG_USER_BASE : natural := 6;
    -- Índice do registrador do tamanho do chip.
    constant REG_SIZE      : natural := 7;
    -- Índice do registrador do índice do buffer.
    constant REG_BUFIDX    : natural := 8;
    -- Índice do registrador de dado do buffer.
    constant REG_BUFDATA   : natural := 9;

    -- Estados: livre, pedido de quadro, espera do quadro, pedido de RDSR, espera do RDSR e fim.
    type state_t is (S_IDLE, S_REQ, S_WAIT, S_POLL_REQ, S_POLL_WAIT, S_FINISH);
    -- Uma faixa de byte do buffer.
    type lane_t is array (0 to 63) of std_logic_vector(7 downto 0);
    -- As quatro faixas de byte do buffer.
    type lanes_t is array (0 to 3) of std_logic_vector(7 downto 0);

    -- Estado atual.
    signal st        : state_t                       := S_IDLE;
    -- Operação do enlace em andamento.
    signal link_op   : std_logic_vector(2 downto 0)  := (others => '0');
    -- Uma gravação (PP) ou um apagar (SE) está em andamento, e o fim espera o chip.
    signal long_op   : std_logic                     := '0';
    -- Endereço do registrador de endereço.
    signal addr_q    : std_logic_vector(23 downto 0) := (others => '0');
    -- Tamanho do registrador de tamanho.
    signal len_q     : std_logic_vector(8 downto 0)  := (others => '0');
    -- Escrita habilitada: WREN concluído e ainda sem PP ou SE.
    signal wel       : std_logic                     := '0';
    -- Concluído, preso.
    signal done      : std_logic                     := '0';
    -- Erro, preso.
    signal err       : std_logic                     := '0';
    -- Interrupção habilitada.
    signal irq_en    : std_logic                     := '0';
    -- Usa FAST_READ no READ.
    signal fast      : std_logic                     := '0';
    -- Último RDID.
    signal id_q      : std_logic_vector(23 downto 0) := (others => '0');
    -- Último RDSR.
    signal sr_q      : std_logic_vector(7 downto 0)  := (others => '0');
    -- Índice do buffer pelo barramento.
    signal bufidx    : unsigned(5 downto 0)          := (others => '0');
    -- Pulso do pedido ao mestre SPI.
    signal req_q     : std_logic                     := '0';
    -- Enlace: operação.
    signal op_q      : std_logic_vector(2 downto 0)  := (others => '0');
    -- Enlace: endereço.
    signal link_addr : std_logic_vector(23 downto 0) := (others => '0');
    -- Enlace: tamanho.
    signal link_len  : std_logic_vector(8 downto 0)  := (others => '0');

    -- O barramento acessa o buffer neste ciclo.
    signal bus_buf    : std_logic;
    -- Escrita do barramento no buffer.
    signal bus_buf_we : std_logic;
    -- Escrita de byte recebido no buffer.
    signal rx_we      : std_logic;
    -- Habilitações de escrita por faixa.
    signal lane_we    : std_logic_vector(3 downto 0);
    -- Endereço de escrita das faixas.
    signal w_addr     : unsigned(5 downto 0);
    -- Dado de escrita de cada faixa.
    signal w_data     : lanes_t;
    -- Endereço de leitura das faixas.
    signal r_addr     : unsigned(5 downto 0);
    -- Palavra lida de cada faixa, registrada.
    signal r_data     : lanes_t                      := (others => (others => '0'));
    -- Faixa do byte a enviar, registrada com a leitura.
    signal tx_lane_q  : unsigned(1 downto 0)         := (others => '0');
    -- O controlador está livre.
    signal idle       : std_logic;

begin

    idle <= '1' when st = S_IDLE else '0';

    o_req  <= req_q;
    o_op   <= op_q;
    o_addr <= link_addr;
    o_len  <= link_len;
    o_irq  <= done and irq_en;

    -- Escrita no buffer: o barramento escreve a palavra, o enlace um byte.
    bus_buf    <= '1' when (i_write = '1' or i_read = '1') and unsigned(i_address) = REG_BUFDATA and idle = '1' else '0';
    bus_buf_we <= '1' when i_write = '1' and bus_buf = '1' else '0';
    rx_we      <= '1' when i_rx_valid = '1' and link_op = LINK_READ else '0';

    -- Escrita do buffer: um processo por faixa recebe os mesmos sinais.
    p_wsel : process (all) is
    begin
        w_addr  <= bufidx;
        lane_we <= (others => '0');
        for l in 0 to 3 loop
            w_data(l) <= i_data_in(8 * l + 7 downto 8 * l);
        end loop;
        if bus_buf_we = '1' then
            lane_we <= (others => '1');
        elsif rx_we = '1' then
            w_addr <= unsigned(i_rx_idx(7 downto 2));
            for l in 0 to 3 loop
                w_data(l) <= i_rx_data;
                if to_integer(unsigned(i_rx_idx(1 downto 0))) = l then
                    lane_we(l) <= '1';
                end if;
            end loop;
        end if;
    end process p_wsel;

    -- Leitura do buffer: o envio do PP escolhe a palavra do byte, e fora dele o barramento escolhe.
    r_addr <= unsigned(i_tx_idx(7 downto 2)) when (st /= S_IDLE and link_op = LINK_PP) else bufidx;

    gen_lanes : for l in 0 to 3 generate
        -- Memória de uma faixa de byte, de escrita única e leitura registrada.
        signal ram : lane_t := (others => (others => '0'));
    begin
        p_lane : process (i_clk) is
        begin
            if rising_edge(i_clk) then
                r_data(l) <= ram(to_integer(r_addr));
                if lane_we(l) = '1' then
                    ram(to_integer(w_addr)) <= w_data(l);
                end if;
            end if;
        end process p_lane;
    end generate gen_lanes;

    p_tx_lane : process (i_clk) is
    begin
        if rising_edge(i_clk) then
            tx_lane_q <= unsigned(i_tx_idx(1 downto 0));
        end if;
    end process p_tx_lane;

    o_tx_data <= r_data(to_integer(tx_lane_q));

    -- Leitura dos registradores.
    p_read : process (all) is
        -- Palavra do buffer lida.
        variable word : std_logic_vector(31 downto 0);
    begin
        o_data_out <= (others => '0');
        for l in 0 to 3 loop
            word(8 * l + 7 downto 8 * l) := r_data(l);
        end loop;
        case to_integer(unsigned(i_address)) is
            when REG_STATUS =>
                o_data_out(0)           <= not idle;
                o_data_out(1)           <= done;
                o_data_out(2)           <= err;
                o_data_out(3)           <= wel;
                o_data_out(4)           <= sr_q(0);
                o_data_out(15 downto 8) <= sr_q;
            when REG_CONTROL =>
                o_data_out(0) <= irq_en;
                o_data_out(1) <= fast;
            when REG_ADDRESS =>
                o_data_out(23 downto 0) <= addr_q;
            when REG_LENGTH =>
                o_data_out(8 downto 0) <= len_q;
            when REG_ID =>
                o_data_out(23 downto 0) <= id_q;
            when REG_USER_BASE =>
                o_data_out <= std_logic_vector(to_unsigned(user_base, 32));
            when REG_SIZE =>
                o_data_out <= std_logic_vector(to_unsigned(size_bytes, 32));
            when REG_BUFIDX =>
                o_data_out(5 downto 0) <= std_logic_vector(bufidx);
            when REG_BUFDATA =>
                if idle = '1' then
                    o_data_out <= word;
                end if;
            when others =>
                null;
        end case;
    end process p_read;

    -- Máquina de comandos.
    p_fsm : process (i_clk) is
        -- Fim do intervalo coberto pelo comando, em bytes.
        variable last_byte : natural;
        -- Comando aceito.
        variable accept    : boolean;
        -- Comando recusado.
        variable refuse    : boolean;
        -- Endereço de entrada, como inteiro.
        variable a         : natural;
        -- Tamanho de entrada, como inteiro.
        variable n         : natural;
        -- Endereço do setor que o apagar atinge.
        variable sector_a  : natural;
    begin
        if rising_edge(i_clk) then
            req_q <= '0';
            if i_rst = '1' then
                st        <= S_IDLE;
                link_op   <= (others => '0');
                long_op   <= '0';
                addr_q    <= (others => '0');
                len_q     <= (others => '0');
                wel       <= '0';
                done      <= '0';
                err       <= '0';
                irq_en    <= '0';
                fast      <= '0';
                id_q      <= (others => '0');
                sr_q      <= (others => '0');
                bufidx    <= (others => '0');
                op_q      <= (others => '0');
                link_addr <= (others => '0');
                link_len  <= (others => '0');
            else
                -- Escritas de registrador.
                if i_write = '1' then
                    case to_integer(unsigned(i_address)) is
                        when REG_STATUS =>
                            if i_data_in(1) = '1' then
                                done <= '0';
                            end if;
                            if i_data_in(2) = '1' then
                                err <= '0';
                            end if;
                        when REG_CONTROL =>
                            irq_en <= i_data_in(0);
                            fast   <= i_data_in(1);
                        when REG_ADDRESS =>
                            if idle = '1' then
                                addr_q <= i_data_in(23 downto 0);
                            end if;
                        when REG_LENGTH =>
                            if idle = '1' then
                                len_q <= i_data_in(8 downto 0);
                            end if;
                        when REG_BUFIDX =>
                            if idle = '1' then
                                bufidx <= unsigned(i_data_in(5 downto 0));
                            end if;
                        when REG_COMMAND =>
                            if idle = '0' then
                                err <= '1';
                            end if;
                        when others =>
                            null;
                    end case;
                end if;
                -- Cada acesso a BUFDATA avança o índice.
                if bus_buf = '1' then
                    bufidx <= bufidx + 1;
                end if;
                -- Bytes recebidos do enlace.
                if i_rx_valid = '1' then
                    case link_op is
                        when LINK_RDID =>
                            id_q <= id_q(15 downto 0) & i_rx_data;
                        when LINK_RDSR =>
                            sr_q <= i_rx_data;
                        when others =>
                            null;
                    end case;
                end if;

                case st is
                    when S_IDLE =>
                        a         := to_integer(unsigned(addr_q));
                        n         := to_integer(unsigned(len_q));
                        sector_a  := (a / SECTOR_BYTES) * SECTOR_BYTES;
                        accept    := false;
                        refuse    := false;
                        if i_write = '1' and to_integer(unsigned(i_address)) = REG_COMMAND then
                            case i_data_in(2 downto 0) is
                                when CMD_RDID | CMD_RDSR | CMD_WREN =>
                                    accept := true;
                                when CMD_READ =>
                                    accept := n >= 1 and n <= PAGE_BYTES and a + n <= size_bytes;
                                    refuse := not accept;
                                when CMD_PP =>
                                    accept := wel = '1' and n >= 1 and n <= PAGE_BYTES and a >= user_base
                                              and (a mod PAGE_BYTES) + n <= PAGE_BYTES and a + n <= size_bytes;
                                    refuse := not accept;
                                when CMD_SE =>
                                    accept := wel = '1' and sector_a >= user_base and a < size_bytes;
                                    refuse := not accept;
                                when others =>
                                    null;
                            end case;
                        end if;
                        if refuse then
                            err <= '1';
                            wel <= '0';
                        end if;
                        if accept then
                            done      <= '0';
                            link_addr <= addr_q;
                            link_len  <= len_q;
                            long_op   <= '0';
                            case i_data_in(2 downto 0) is
                                when CMD_RDID =>
                                    op_q    <= LINK_RDID;
                                    link_op <= LINK_RDID;
                                when CMD_RDSR =>
                                    op_q    <= LINK_RDSR;
                                    link_op <= LINK_RDSR;
                                when CMD_WREN =>
                                    op_q    <= LINK_WREN;
                                    link_op <= LINK_WREN;
                                when CMD_READ =>
                                    if fast = '1' then
                                        op_q    <= LINK_FAST_READ;
                                        link_op <= LINK_READ;
                                    else
                                        op_q    <= LINK_READ;
                                        link_op <= LINK_READ;
                                    end if;
                                when CMD_PP =>
                                    op_q    <= LINK_PP;
                                    link_op <= LINK_PP;
                                    long_op <= '1';
                                when others =>
                                    op_q      <= LINK_SE;
                                    link_op   <= LINK_SE;
                                    link_addr <= std_logic_vector(to_unsigned(sector_a, 24));
                                    long_op   <= '1';
                            end case;
                            req_q <= '1';
                            st    <= S_WAIT;
                        end if;
                    when S_REQ =>
                        req_q <= '1';
                        st    <= S_POLL_WAIT;
                    when S_WAIT =>
                        if i_done = '1' then
                            if link_op = LINK_WREN then
                                wel <= '1';
                            end if;
                            if long_op = '1' then
                                st <= S_POLL_REQ;
                            else
                                st <= S_FINISH;
                            end if;
                        end if;
                    when S_POLL_REQ =>
                        -- Pergunta ao chip se a operação terminou (RDSR), enquanto o WIP estiver em um.
                        op_q    <= LINK_RDSR;
                        link_op <= LINK_RDSR;
                        st      <= S_REQ;
                    when S_POLL_WAIT =>
                        if i_done = '1' then
                            if sr_q(0) = '1' then
                                st <= S_POLL_REQ;
                            else
                                wel <= '0';
                                st  <= S_FINISH;
                            end if;
                        end if;
                    when S_FINISH =>
                        done <= '1';
                        st   <= S_IDLE;
                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;
