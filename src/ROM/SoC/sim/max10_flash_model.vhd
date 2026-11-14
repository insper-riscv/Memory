-- =============================================================================
-- Modelo comportamental da megafunção de flash on-chip do MAX 10 (só simulação)
--
-- Reproduz, no nível das portas Avalon-MM e dos registradores de CSR, o
-- comportamento da altera_onchip_flash que o max10_flash usa: a interface de
-- dados com waitrequest e readdatavalid, o registrador de estado (ocupado, leitura,
-- escrita e apagamento passaram) e o de controle (apagar de setor, proteção de
-- escrita e estado do apagar), e a regra da flash de que uma gravação só leva bits
-- de 1 para 0 e só o apagar de setor devolve uns. O conteúdo nasce apagado.
--
-- Os tempos são generics (write_cycles e erase_cycles) e não os do chip; o modelo
-- serve ao teste do contrato, não à medida de desempenho. Os setores são cinco,
-- contíguos a partir do endereço zero, de sector_words palavras cada um. A leitura
-- devolve a palavra duas bordas depois do aceite; um endereço fora dos cinco
-- setores devolve uns e baixa o bit de leitura passou. Uma escrita ou um apagar em
-- setor protegido não muda o conteúdo e deixa o bit de passou em zero. A leitura do
-- CSR devolve a palavra uma borda depois do pedido, como a megafunção.
--
-- Não modelado: o apagar de página, a proteção de leitura por setor (o estado
-- nasce com todos os setores legíveis), o burst e os tempos reais do chip.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity max10_flash_model is
    generic (
        -- Largura do endereço de palavra da interface de dados.
        data_addr_bits : positive := 20;
        -- Palavras de cada um dos cinco setores.
        sector_words   : positive := 16;
        -- Bordas de uma gravação, com o estado ocupado em escrita.
        write_cycles   : positive := 6;
        -- Bordas de um apagar de setor, com o estado ocupado em apagar.
        erase_cycles   : positive := 30
    );
    port (
        -- Clock do modelo.
        i_clk     : in    std_logic;
        -- Reset, ativo em '0'.
        i_reset_n : in    std_logic;

        -- Dados: pedido de leitura.
        i_data_read   : in    std_logic;
        -- Dados: pedido de escrita.
        i_data_write  : in    std_logic;
        -- Dados: endereço de palavra.
        i_data_addr   : in    std_logic_vector(data_addr_bits - 1 downto 0);
        -- Dados: palavra a escrever.
        i_data_wdata  : in    std_logic_vector(31 downto 0);
        -- Dados: o pedido não foi aceito ('1').
        o_data_wait   : out   std_logic;
        -- Dados: palavra lida válida.
        o_data_rvalid : out   std_logic;
        -- Dados: palavra lida.
        o_data_rdata  : out   std_logic_vector(31 downto 0);

        -- CSR: pedido de leitura.
        i_csr_read  : in    std_logic;
        -- CSR: pedido de escrita.
        i_csr_write : in    std_logic;
        -- CSR: registrador, '0' estado e '1' controle.
        i_csr_addr  : in    std_logic;
        -- CSR: palavra a escrever.
        i_csr_wdata : in    std_logic_vector(31 downto 0);
        -- CSR: palavra lida, valida uma borda depois do pedido.
        o_csr_rdata : out   std_logic_vector(31 downto 0)
    );
end entity max10_flash_model;

architecture sim of max10_flash_model is

    -- Quantidade de palavras da flash.
    constant WORDS : natural := 5 * sector_words;

    -- Bits 31 a 10 da leitura do registrador de estado, sempre em um.
    constant HIGH_ONES : std_logic_vector(21 downto 0) := (others => '1');

    -- Conteúdo da flash.
    type mem_t is array (0 to WORDS - 1) of std_logic_vector(31 downto 0);
    -- Estados do modelo: livre, aceite do pedido, leitura, gravação e apagar.
    type state_t is (S_IDLE, S_ACCEPT, S_READ, S_WRITE, S_ERASE_PEND, S_ERASE);

    -- A flash, apagada.
    signal mem        : mem_t                        := (others => (others => '1'));
    -- Estado do modelo.
    signal st         : state_t                      := S_IDLE;
    -- Pedido aceito é uma escrita.
    signal is_write   : std_logic                    := '0';
    -- Endereço do pedido aceito.
    signal addr_q     : natural range 0 to 2 ** data_addr_bits - 1 := 0;
    -- Dado do pedido aceito.
    signal wdata_q    : std_logic_vector(31 downto 0) := (others => '0');
    -- Contador de bordas da operação.
    signal count      : natural                      := 0;
    -- Campo ocupado do estado: 0 livre, 1 apagar, 2 escrever, 3 ler.
    signal busy_q     : std_logic_vector(1 downto 0) := "00";
    -- Bit de leitura passou.
    signal r_pass     : std_logic                    := '0';
    -- Bit de escrita passou.
    signal w_pass     : std_logic                    := '0';
    -- Bit de apagamento passou.
    signal e_pass     : std_logic                    := '0';
    -- Proteção de escrita por setor, um bit por setor (bit 0 é o setor 1), nasce protegido.
    signal wp_mode    : std_logic_vector(4 downto 0) := (others => '1');
    -- Campo de endereço do controle, 23 bits, nasce todo em um.
    signal ctrl_addr  : std_logic_vector(22 downto 0) := (others => '1');
    -- Estado do apagar no controle: 0 livre, 1 pendente, 2 em andamento.
    signal erase_st   : std_logic_vector(1 downto 0) := "00";
    -- A última leitura do CSR foi do controle.
    signal csr_is_ctl : std_logic                    := '0';
    -- Palavra lida pela interface de dados, registrada.
    signal rdata_q    : std_logic_vector(31 downto 0) := (others => '1');
    -- Palavra lida válida.
    signal rvalid_q   : std_logic                    := '0';

begin

    o_data_wait   <= '0' when st = S_ACCEPT else '1';
    o_data_rvalid <= rvalid_q;
    o_data_rdata  <= rdata_q;

    -- Leitura do CSR: o registrador escolhido na borda do pedido.
    o_csr_rdata <= erase_st & "11" & wp_mode & ctrl_addr when csr_is_ctl = '1'
                   else HIGH_ONES & "00000" & e_pass & w_pass & r_pass & busy_q;

    p_model : process (i_clk) is
        -- Setor do endereço, de 1 a 5, ou zero fora da flash.
        variable sec : natural range 0 to 7;
        -- Setor escolhido pelo controle.
        variable csec : natural range 0 to 7;
    begin
        if rising_edge(i_clk) then
            rvalid_q <= '0';
            if i_reset_n = '0' then
                st         <= S_IDLE;
                busy_q     <= "00";
                r_pass     <= '0';
                w_pass     <= '0';
                e_pass     <= '0';
                wp_mode    <= (others => '1');
                ctrl_addr  <= (others => '1');
                erase_st   <= "00";
                csr_is_ctl <= '0';
            else
                -- CSR: a palavra vem uma borda depois do pedido de leitura.
                if i_csr_read = '1' then
                    csr_is_ctl <= i_csr_addr;
                end if;
                -- CSR: a escrita no controle grava a proteção sempre e o endereço só com o modelo livre.
                if i_csr_write = '1' and i_csr_addr = '1' then
                    wp_mode <= i_csr_wdata(27 downto 23);
                    if busy_q = "00" then
                        ctrl_addr <= i_csr_wdata(22 downto 0);
                        if i_csr_wdata(22 downto 0) /= (22 downto 0 => '1') and erase_st = "00" then
                            erase_st <= "01";
                        end if;
                    end if;
                end if;

                case st is
                    when S_IDLE =>
                        if erase_st = "01" then
                            st       <= S_ERASE_PEND;
                        elsif i_data_read = '1' or i_data_write = '1' then
                            is_write <= i_data_write;
                            addr_q   <= to_integer(unsigned(i_data_addr));
                            wdata_q  <= i_data_wdata;
                            st       <= S_ACCEPT;
                        end if;
                    when S_ACCEPT =>
                        count <= 0;
                        if is_write = '1' then
                            busy_q <= "10";
                            st     <= S_WRITE;
                        else
                            st <= S_READ;
                        end if;
                    when S_READ =>
                        if count = 1 then
                            if addr_q < WORDS then
                                rdata_q <= mem(addr_q);
                                r_pass  <= '1';
                            else
                                rdata_q <= (others => '1');
                                r_pass  <= '0';
                            end if;
                            rvalid_q <= '1';
                            st       <= S_IDLE;
                        end if;
                        count <= count + 1;
                    when S_WRITE =>
                        if count = write_cycles - 1 then
                            sec := 0;
                            if addr_q < WORDS then
                                sec := addr_q / sector_words + 1;
                            end if;
                            if sec /= 0 and wp_mode(sec - 1) = '0' then
                                mem(addr_q) <= mem(addr_q) and wdata_q;
                                w_pass      <= '1';
                            else
                                w_pass <= '0';
                            end if;
                            busy_q <= "00";
                            st     <= S_IDLE;
                        end if;
                        count <= count + 1;
                    when S_ERASE_PEND =>
                        busy_q   <= "01";
                        erase_st <= "10";
                        count    <= 0;
                        st       <= S_ERASE;
                    when S_ERASE =>
                        if count = erase_cycles - 1 then
                            csec := to_integer(unsigned(ctrl_addr(22 downto 20)));
                            if csec >= 1 and csec <= 5 and wp_mode(csec - 1) = '0' then
                                for w in 0 to sector_words - 1 loop
                                    mem((csec - 1) * sector_words + w) <= (others => '1');
                                end loop;
                                e_pass <= '1';
                            else
                                e_pass <= '0';
                            end if;
                            busy_q   <= "00";
                            erase_st <= "00";
                            st       <= S_IDLE;
                        end if;
                        count <= count + 1;
                end case;
            end if;
        end if;
    end process p_model;

end architecture sim;
