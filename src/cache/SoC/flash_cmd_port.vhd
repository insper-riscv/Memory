-- =============================================================================
-- Porta de comandos (porta B) do modelo de chip de FLASH
--
-- Executa os comandos de programação de um chip de FLASH real sobre o
-- armazenamento de duas portas, enquanto a porta A (flash_chip) segue lendo.
-- Um comando chega como um pulso em i_cmd_valid, com o código em i_cmd_op e o
-- endereço de byte em i_cmd_addr:
--
--   - habilitar escrita: arma o latch de escrita (o_wel);
--   - apagar setor: põe todos os bits do setor em 1;
--   - gravar página: cada bit gravado só vai de 1 para 0 (E bit a bit do
--     conteúdo atual com a palavra do buffer de página);
--   - proteger e desproteger: marcam o setor que apagar e gravar recusam.
--
-- Um apagar ou gravar sem o latch armado é ignorado por inteiro. Com o latch
-- armado, um setor protegido ou um endereço fora da janela é recusado: nada é
-- escrito, o latch cai e o_refused sobe. Um comando aceito mantém o_busy em
-- nível alto até a última palavra estar escrita, e só então o latch cai e sai
-- o pulso de invalidação com a região alterada (o_inval_valid, o_inval_first e
-- o_inval_last, endereços de byte da FLASH com a base base_addr). Qualquer
-- comando que chega com o_busy alto é ignorado.
--
-- O armazenamento não está aqui. A entidade comanda a porta B de uma memória de
-- duas portas de leitura registrada (o IP de FLASH da Cyclone V ou
-- flash_simulation): o_mem_addr sai de um registrador e i_mem_data traz a
-- palavra duas bordas depois do endereço. O dado da gravação vem do buffer de
-- página do controlador, lido do mesmo modo por o_buf_idx e i_buf_data.
--
-- Latência, contada em bordas de i_clk a partir da borda que aceita o comando:
--   - erase_latency e program_latency: espera antes de a varredura começar,
--     mais uma borda;
--   - depois, três bordas por palavra da região (endereço, leitura, escrita).
-- Um apagar ocupa erase_latency + 1 + 3 * (sector_bytes / 4) bordas e uma
-- gravação program_latency + 1 + 3 * (page_bytes / 4).
--
-- Janela: o chip ocupa size_bytes bytes, uma potência de dois. Um endereço
-- cujos bits 25 até o fim do tamanho não são todos zero está fora da janela,
-- como no flash_chip; os bits 31 a 26 não entram na checagem. Os bits abaixo
-- do tamanho do setor (apagar, proteger) ou da página (gravar) são ignorados.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.utils_pkg.all;
use work.chip_timing_pkg.max_natural;

entity flash_cmd_port is
    generic (
        -- Tamanho do chip em bytes, uma potência de dois maior que sector_bytes e de até 32 MB (1048576 é 1 MB).
        size_bytes      : positive                      := 1048576;
        -- Tamanho do setor de apagar e de proteger em bytes, uma potência de dois (4096 é 4 KB).
        sector_bytes    : positive                      := 4096;
        -- Tamanho da página de gravar em bytes, uma potência de dois de 8 bytes até sector_bytes (256).
        page_bytes      : positive                      := 256;
        -- Endereço de byte do início do chip no mapa do SoC, somado ao deslocamento na região de invalidação.
        base_addr       : std_logic_vector(31 downto 0) := x"20000000";
        -- Bordas de espera de um apagar antes da varredura do setor.
        erase_latency   : natural                       := 2000;
        -- Bordas de espera de uma gravação antes da varredura da página.
        program_latency : natural                       := 200
    );
    port (
        -- Clock do módulo, o mesmo da memória de armazenamento.
        i_clk : in    std_logic;
        -- Reset, ativo em '1'. Zera o latch, a recusa e a proteção.
        i_rst : in    std_logic;

        -- Pulso de um ciclo que entrega um comando ao chip.
        i_cmd_valid : in    std_logic;
        -- Código do comando: 001 habilitar escrita, 010 apagar, 011 gravar, 100 proteger, 101 desproteger.
        i_cmd_op    : in    std_logic_vector(2 downto 0);
        -- Endereço de byte do comando (a região é a do setor ou da página que o contém).
        i_cmd_addr  : in    std_logic_vector(31 downto 0);

        -- O chip está executando um apagar ou uma gravação ('1').
        o_busy    : out   std_logic;
        -- O latch de escrita está armado ('1').
        o_wel     : out   std_logic;
        -- O último apagar ou gravar com o latch armado foi recusado ('1'); cai no próximo habilitar escrita.
        o_refused : out   std_logic;

        -- Índice da palavra do buffer de página lida pela gravação (registrado).
        o_buf_idx  : out   std_logic_vector(log2_exact(page_bytes) - 3 downto 0);
        -- Palavra do buffer de página, com leitura registrada.
        i_buf_data : in    std_logic_vector(31 downto 0);

        -- Endereço de byte entregue à porta B da memória de armazenamento (registrado).
        o_mem_addr  : out   std_logic_vector(31 downto 0);
        -- Habilita de escrita da porta B da memória de armazenamento.
        o_mem_we    : out   std_logic;
        -- Palavra a escrever na porta B da memória de armazenamento.
        o_mem_wdata : out   std_logic_vector(31 downto 0);
        -- Palavra lida da porta B da memória de armazenamento (leitura registrada).
        i_mem_data  : in    std_logic_vector(31 downto 0);

        -- Pulso de um ciclo no fim de um apagar ou gravar aceito: as caches devem derrubar a região.
        o_inval_valid : out   std_logic;
        -- Primeiro endereço de byte da região alterada.
        o_inval_first : out   std_logic_vector(31 downto 0);
        -- Último endereço de byte da região alterada.
        o_inval_last  : out   std_logic_vector(31 downto 0)
    );
end entity flash_cmd_port;

architecture rtl of flash_cmd_port is

    -- Código do comando habilitar escrita.
    constant CMD_WREN    : std_logic_vector(2 downto 0) := "001";
    -- Código do comando apagar setor.
    constant CMD_ERASE   : std_logic_vector(2 downto 0) := "010";
    -- Código do comando gravar página.
    constant CMD_PROGRAM : std_logic_vector(2 downto 0) := "011";
    -- Código do comando proteger setor.
    constant CMD_PROTECT : std_logic_vector(2 downto 0) := "100";
    -- Código do comando desproteger setor.
    constant CMD_UNPROT  : std_logic_vector(2 downto 0) := "101";

    -- Bits de endereço da janela do chip (falha se size_bytes não for uma potência de dois).
    constant WINDOW_BITS  : natural := log2_exact(size_bytes);
    -- Bits de endereço dentro de um setor.
    constant SECTOR_BITS  : natural := log2_exact(sector_bytes);
    -- Bits de endereço dentro de uma página.
    constant PAGE_BITS    : natural := log2_exact(page_bytes);
    -- Quantidade de setores do chip.
    constant SECTORS      : natural := size_bytes / sector_bytes;
    -- Palavras de um setor.
    constant SECTOR_WORDS : natural := sector_bytes / 4;
    -- Palavras de uma página.
    constant PAGE_WORDS   : natural := page_bytes / 4;
    -- Maior espera inicial entre as duas operações.
    constant MAX_LATENCY  : natural := max_natural(erase_latency, program_latency);

    -- Estados: livre, espera inicial e varredura das palavras da região.
    type state_t is (S_IDLE, S_WAIT, S_RUN);

    -- Estado atual.
    signal st       : state_t                                := S_IDLE;
    -- Fase da varredura de uma palavra: 0 endereço emitido, 1 dado disponível, 2 escrita concluída.
    signal ph       : natural range 0 to 2                   := 0;
    -- Bordas que faltam da espera inicial.
    signal cnt      : natural range 0 to MAX_LATENCY         := 0;
    -- Índice da palavra em andamento dentro da região.
    signal word_n   : natural range 0 to SECTOR_WORDS - 1    := 0;
    -- Índice da última palavra da região em andamento.
    signal last_n   : natural range 0 to SECTOR_WORDS - 1    := 0;
    -- A operação em andamento é um apagar ('1') ou uma gravação ('0').
    signal is_erase : std_logic                              := '0';
    -- Deslocamento do início da região em andamento dentro do chip.
    signal base_off : unsigned(WINDOW_BITS - 1 downto 0)     := (others => '0');
    -- Deslocamento da palavra em andamento dentro do chip (registrado).
    signal addr_q   : unsigned(WINDOW_BITS - 1 downto 0)     := (others => '0');
    -- Índice da palavra do buffer de página (registrado).
    signal buf_idx  : unsigned(PAGE_BITS - 3 downto 0)       := (others => '0');
    -- Latch de escrita.
    signal wel      : std_logic                              := '0';
    -- Última operação recusada.
    signal refused  : std_logic                              := '0';
    -- Proteção de cada setor.
    signal prot     : std_logic_vector(SECTORS - 1 downto 0) := (others => '0');
    -- Habilita de escrita registrada.
    signal we_q     : std_logic                              := '0';
    -- Palavra de escrita registrada.
    signal wdata_q  : std_logic_vector(31 downto 0)          := (others => '0');
    -- Pulso de invalidação registrado.
    signal inval_q  : std_logic                              := '0';
    -- Primeiro endereço da região invalidada (registrado).
    signal first_q  : unsigned(31 downto 0)                  := (others => '0');
    -- Último endereço da região invalidada (registrado).
    signal last_q   : unsigned(31 downto 0)                  := (others => '0');

begin

    assert size_bytes > sector_bytes and size_bytes <= 2 ** 25
        report "size_bytes must be greater than sector_bytes and at most 32 MB"
        severity failure;
    assert page_bytes >= 8 and page_bytes <= sector_bytes
        report "page_bytes must be between 8 bytes and sector_bytes"
        severity failure;

    o_busy        <= '1' when st /= S_IDLE else '0';
    o_wel         <= wel;
    o_refused     <= refused;
    o_buf_idx     <= std_logic_vector(buf_idx);
    o_mem_addr    <= std_logic_vector(resize(addr_q, 32));
    o_mem_we      <= we_q;
    o_mem_wdata   <= wdata_q;
    o_inval_valid <= inval_q;
    o_inval_first <= std_logic_vector(first_q);
    o_inval_last  <= std_logic_vector(last_q);

    process (i_clk) is

        -- Deslocamento do endereço do comando dentro do chip.
        variable off     : unsigned(WINDOW_BITS - 1 downto 0);
        -- Setor do endereço do comando.
        variable sec     : natural range 0 to SECTORS - 1;
        -- O endereço do comando está fora da janela do chip.
        variable out_win : boolean;
        -- Primeiro endereço da região invalidada, no mapa do SoC.
        variable first_a : unsigned(31 downto 0);

    begin

        if rising_edge(i_clk) then
            we_q    <= '0';
            inval_q <= '0';
            if i_rst = '1' then
                st      <= S_IDLE;
                wel     <= '0';
                refused <= '0';
                prot    <= (others => '0');
                ph      <= 0;
            else

                case st is

                    when S_IDLE =>

                        off     := unsigned(i_cmd_addr(WINDOW_BITS - 1 downto 0));
                        sec     := to_integer(off(WINDOW_BITS - 1 downto SECTOR_BITS));
                        out_win := unsigned(i_cmd_addr(25 downto WINDOW_BITS)) /= 0;
                        if i_cmd_valid = '1' then
                            if i_cmd_op = CMD_WREN then
                                wel     <= '1';
                                refused <= '0';
                            elsif i_cmd_op = CMD_PROTECT and not out_win then
                                prot(sec) <= '1';
                            elsif i_cmd_op = CMD_UNPROT and not out_win then
                                prot(sec) <= '0';
                            elsif (i_cmd_op = CMD_ERASE or i_cmd_op = CMD_PROGRAM) and wel = '1' then
                                if out_win or prot(sec) = '1' then
                                    refused <= '1';
                                    wel     <= '0';
                                else
                                    if i_cmd_op = CMD_ERASE then
                                        is_erase <= '1';
                                        last_n   <= SECTOR_WORDS - 1;
                                        cnt      <= erase_latency;
                                        base_off <= off(WINDOW_BITS - 1 downto SECTOR_BITS) & (SECTOR_BITS - 1 downto 0 => '0');
                                    else
                                        is_erase <= '0';
                                        last_n   <= PAGE_WORDS - 1;
                                        cnt      <= program_latency;
                                        base_off <= off(WINDOW_BITS - 1 downto PAGE_BITS) & (PAGE_BITS - 1 downto 0 => '0');
                                    end if;
                                    st <= S_WAIT;
                                end if;
                            end if;
                        end if;

                    when S_WAIT =>

                        if cnt > 0 then
                            cnt <= cnt - 1;
                        else
                            addr_q  <= base_off;
                            buf_idx <= (others => '0');
                            word_n  <= 0;
                            ph      <= 0;
                            st      <= S_RUN;
                        end if;

                    when S_RUN =>

                        case ph is

                            when 0 =>

                                ph <= 1;

                            when 1 =>

                                if is_erase = '1' then
                                    wdata_q <= (others => '1');
                                else
                                    wdata_q <= i_mem_data and i_buf_data;
                                end if;
                                we_q <= '1';
                                ph   <= 2;

                            when 2 =>

                                ph <= 0;
                                if word_n = last_n then
                                    first_a := unsigned(base_addr) + resize(base_off, 32);
                                    first_q <= first_a;
                                    last_q  <= first_a + to_unsigned(4 * (last_n + 1) - 1, 32);
                                    inval_q <= '1';
                                    wel     <= '0';
                                    st      <= S_IDLE;
                                else
                                    word_n  <= word_n + 1;
                                    addr_q  <= addr_q + 4;
                                    buf_idx <= buf_idx + 1;
                                end if;

                        end case;

                end case;

            end if;
        end if;

    end process;

end architecture rtl;
