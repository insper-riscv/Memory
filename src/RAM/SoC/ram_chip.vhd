-- =============================================================================
-- Modelo de chip de RAM externa para simulação
--
-- Faz nas plataformas simuladas o papel da SDRAM da placa, sem o controlador nem o
-- modelo do chip: um vetor de palavras de 32 bits, com a mesma lista de portas do
-- sdram_system que o topo usa (a porta de dados do core, a porta da ponte de instruções
-- e a porta de depuração por palavra), e o mesmo contrato da ponte da SDRAM.
--
-- Contrato de cada porta (igual ao da sdram_cpu_bridge): o acesso fica em addr, rden ou
-- wren e line enquanto o estágio que o pede está parado. ready sobe quando o acesso
-- termina e permanece em nível alto até advance indicar que o pipeline andou. O dado
-- lido só muda nessa mesma borda, porque o load que ainda está no estágio de write-back
-- lê o valor anterior até lá. Um acesso de linha move as quatro palavras que começam em
-- addr alinhado em 16 bytes: a palavra 0 em wdata, byteena e rdata, e as palavras 1 a 3
-- em wdata_x, byteena_x e rdata_x, a palavra 1 nos bits mais baixos.
--
-- Latência: latency bordas de i_clk entre a borda em que o pedido é visto e a borda em
-- que o acesso se completa e ready sobe (mínimo 2). A leitura e a escrita acontecem no
-- fim da latência, então um store da porta de dados é visto pela porta de instruções
-- que pedir depois dele.
--
-- Tamanho: o genérico size_bytes, uma potência de dois (1 MB por padrão, no máximo 32 MB). Um
-- acesso cujos bits 25 até o fim do tamanho não são todos zero está fora da janela do chip: a
-- leitura devolve zero e a escrita é descartada.
--
-- init_file (opcional): imagem gravada no chip no instante zero, uma palavra de 32 bits
-- por linha, em hexadecimal, a partir do primeiro endereço da janela. É como o hospedeiro
-- do ACT4 carrega o programa e os dados, o mesmo formato do SDRAM_FILE da SDRAM.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.config_pkg.all;
use std.textio.all;
use work.utils_pkg.all;
use work.ram_pkg.all;

entity ram_chip is
    generic (
        -- Arquivo com a imagem inicial do chip; vazio deixa tudo em zero.
        init_file  : string   := "";
        -- Bordas entre o pedido e a conclusão do acesso (mínimo 2).
        latency    : natural  := 8;
        -- Tamanho do chip em bytes, uma potência de dois de 16 bytes a 32 MB (1048576 é 1 MB).
        size_bytes : positive := 1048576;
        -- Onde o chip começa dentro dos 64 MB da região, em KiB: o endereço do chip é o da região menos
        -- esta base. Origem: o espaço de endereços da região da memória que o Memory enxerga (26 bits
        -- baixos), não o mapa do Core.
        base_kib   : natural  := 0
    );
    port (
        -- Clock do módulo.
        i_clk : in    std_logic;
        -- Reset, ativo em '1'.
        i_rst : in    std_logic;

        -- Porta de dados: endereço do acesso.
        i_addr        : in    addr_t;
        -- Porta de dados: dado de escrita.
        i_wdata       : in    word_t;
        -- Porta de dados: habilita de bytes da escrita, um bit por byte.
        i_byteena     : in    std_logic_vector(3 downto 0);
        -- Porta de dados: pedido de leitura ('1' = lê).
        i_rden        : in    std_logic;
        -- Porta de dados: pedido de escrita ('1' = escreve).
        i_wren        : in    std_logic;
        -- Porta de dados: o pipeline avançou neste ciclo, o acesso concluído pode terminar.
        i_mem_advance : in    std_logic;
        -- Porta de dados: acesso concluído, o dado lido é válido ('1').
        o_ready       : out   std_logic;
        -- Porta de dados: dado lido.
        o_rdata       : out   word_t;
        -- Porta de dados: acesso de linha, quatro palavras seguidas ('1').
        i_line        : in    std_logic                     := '0';
        -- Porta de dados: palavras 1 a 3 do dado de escrita da linha.
        i_wdata_x     : in    std_logic_vector(95 downto 0) := (others => '0');
        -- Porta de dados: habilita de bytes das palavras 1 a 3 da linha.
        i_byteena_x   : in    std_logic_vector(11 downto 0) := (others => '0');
        -- Porta de dados: palavras 1 a 3 do dado lido da linha.
        o_rdata_x     : out   std_logic_vector(95 downto 0);

        -- Porta de instruções: endereço do acesso.
        i_ins_addr    : in    addr_t := (others => '0');
        -- Porta de instruções: pedido de leitura ('1' = lê).
        i_ins_rden    : in    std_logic                     := '0';
        -- Porta de instruções: o pipeline avançou neste ciclo.
        i_ins_advance : in    std_logic                     := '0';
        -- Porta de instruções: acesso concluído, o dado lido é válido ('1').
        o_ins_ready   : out   std_logic;
        -- Porta de instruções: dado lido.
        o_ins_rdata   : out   std_logic_vector(31 downto 0);
        -- Porta de instruções: acesso de linha, quatro palavras seguidas ('1').
        i_ins_line    : in    std_logic                     := '0';
        -- Porta de instruções: palavras 1 a 3 do dado lido da linha.
        o_ins_rdata_x : out   std_logic_vector(95 downto 0);

        -- O chip está pronto para atender pedidos ('1' desde a borda seguinte ao reset).
        o_init_done     : out   std_logic;
        -- Índice da palavra que a porta de depuração lê, a partir do início da janela.
        i_dbg_word_addr : in    std_logic_vector(23 downto 0) := (others => '0');
        -- Palavra do chip no índice de i_dbg_word_addr.
        o_dbg_word_data : out   std_logic_vector(31 downto 0)
    );
end entity ram_chip;

architecture rtl of ram_chip is

    -- Bits de endereço da janela do chip (falha se size_bytes não for uma potência de dois).
    constant WINDOW_BITS : natural := log2_exact(size_bytes);
    -- Palavras do chip.
    constant WORDS       : natural := size_bytes / 4;

    -- Vetor de palavras do chip.
    type word_array_t is array(0 to WORDS - 1) of std_logic_vector(31 downto 0);

    -- O vetor, compartilhado pelas duas portas e pela porta de depuração.
    type store_t is protected
        -- Escreve os bytes habilitados da palavra de índice index.

        procedure write_word (
            index   : in natural;
            data    : in std_logic_vector(31 downto 0);
            byteena : in std_logic_vector(3 downto 0)
        );
        -- Devolve a palavra de índice index, ou zero fora do vetor.

        impure function read_word (index : natural) return std_logic_vector;
        -- Grava a palavra de índice index inteira.

        procedure set_word (
            index : in natural;
            data  : in std_logic_vector(31 downto 0)
        );
    end protected store_t;

    -- Corpo do tipo protegido que guarda as palavras do chip.
    type store_t is protected body
        -- Palavras do chip.
        variable mem : word_array_t := (others => (others => '0'));

        procedure write_word (
            index   : in natural;
            data    : in std_logic_vector(31 downto 0);
            byteena : in std_logic_vector(3 downto 0)
        ) is

            -- Palavra lida do vetor antes de receber os bytes habilitados.
            variable word : std_logic_vector(31 downto 0);

        begin

            if index < WORDS then
                word := mem(index);

                for b in 0 to 3 loop

                    if byteena(b) = '1' then
                        word(8 * b + 7 downto 8 * b) := data(8 * b + 7 downto 8 * b);
                    end if;

                end loop;

                mem(index) := word;
            end if;

        end procedure write_word;

        impure function read_word (index : natural) return std_logic_vector is
        begin

            if index < WORDS then
                return mem(index);
            end if;

            return x"00000000";

        end function read_word;

        procedure set_word (
            index : in natural;
            data  : in std_logic_vector(31 downto 0)
        ) is
        begin

            if index < WORDS then
                mem(index) := data;
            end if;

        end procedure set_word;

    end protected body store_t;

    -- O chip.
    shared variable store : store_t;

    -- Estados de uma porta: livre, esperando a latência, acesso concluído.
    type state_t is (S_IDLE, S_WAIT, S_DONE);

    -- Estado da porta de dados.
    signal d_st      : state_t                       := S_IDLE;
    -- Início da contagem de latência da porta de dados ('1' carrega).
    signal d_load    : std_logic;
    -- A contagem de latência da porta de dados termina nesta borda.
    signal d_last    : std_logic;
    -- O acesso da porta de dados é uma escrita.
    signal d_we      : std_logic                     := '0';
    -- O acesso da porta de dados é de linha.
    signal d_line    : std_logic                     := '0';
    -- Endereço de byte do acesso da porta de dados.
    signal d_addr    : addr_t := (others => '0');
    -- Dado de escrita capturado na porta de dados.
    signal d_wdata   : std_logic_vector(31 downto 0) := (others => '0');
    -- Habilita de bytes capturado na porta de dados.
    signal d_be      : std_logic_vector(3 downto 0)  := (others => '0');
    -- Palavras 1 a 3 do dado de escrita capturado.
    signal d_wdx     : std_logic_vector(95 downto 0) := (others => '0');
    -- Habilita de bytes das palavras 1 a 3 capturado.
    signal d_bex     : std_logic_vector(11 downto 0) := (others => '0');
    -- Palavra 0 lida, à espera do avanço do pipeline.
    signal d_pending : std_logic_vector(31 downto 0) := (others => '0');
    -- Palavras 1 a 3 lidas, à espera do avanço do pipeline.
    signal d_pend_x  : std_logic_vector(95 downto 0) := (others => '0');
    -- Palavra 0 entregue ao core.
    signal d_rdata   : std_logic_vector(31 downto 0) := (others => '0');
    -- Palavras 1 a 3 entregues ao core.
    signal d_rdx     : std_logic_vector(95 downto 0) := (others => '0');

    -- Estado da porta de instruções.
    signal i_st      : state_t                       := S_IDLE;
    -- Início da contagem de latência da porta de instruções ('1' carrega).
    signal i_load    : std_logic;
    -- A contagem de latência da porta de instruções termina nesta borda.
    signal i_last    : std_logic;
    -- O acesso da porta de instruções é de linha.
    signal i_line_q  : std_logic                     := '0';
    -- Endereço de byte do acesso da porta de instruções.
    signal i_addr_q  : addr_t := (others => '0');
    -- Palavra 0 lida, à espera do avanço do pipeline.
    signal i_pending : std_logic_vector(31 downto 0) := (others => '0');
    -- Palavras 1 a 3 lidas, à espera do avanço do pipeline.
    signal i_pend_x  : std_logic_vector(95 downto 0) := (others => '0');
    -- Palavra 0 entregue ao core.
    signal i_rdata   : std_logic_vector(31 downto 0) := (others => '0');
    -- Palavras 1 a 3 entregues ao core.
    signal i_rdx     : std_logic_vector(95 downto 0) := (others => '0');

    -- O chip aceita pedidos.
    signal init_done : std_logic := '0';

    -- Devolve o índice da palavra de um endereço de byte, ou WORDS quando está fora da janela.

    function word_index (addr : addr_t) return natural is

        -- Deslocamento do endereço dentro da janela do chip, em bytes.
        variable offset : unsigned(25 downto 0);

    begin

        if unsigned(addr(25 downto 0)) < base_kib * 1024 then
            return WORDS;
        end if;

        offset := window_offset(addr, base_kib);

        if offset(25 downto WINDOW_BITS) /= 0 then
            return WORDS;
        end if;

        return to_integer(offset(WINDOW_BITS - 1 downto 2));

    end function word_index;

    -- Devolve o endereço inicial de um acesso: o da linha alinhado em 16 bytes, ou o da palavra.

    function start_addr (addr : addr_t; line : std_logic) return std_logic_vector is

        -- Endereço de partida, alinhado em 16 bytes quando o acesso é de linha.
        variable a : addr_t := addr;

    begin

        if line = '1' then
            a(3 downto 0) := "0000";
        else
            a(1 downto 0) := "00";
        end if;

        return a;

    end function start_addr;

begin

    o_ready       <= '1' when d_st = S_DONE else '0';
    o_rdata       <= d_rdata;
    o_rdata_x     <= d_rdx;
    o_ins_ready   <= '1' when i_st = S_DONE else '0';
    o_ins_rdata   <= i_rdata;
    o_ins_rdata_x <= i_rdx;
    o_init_done   <= init_done;

    -- Um acesso aceito em repouso inicia a contagem da latência, uma por porta.
    d_load <= '1' when d_st = S_IDLE and (i_rden = '1' or i_wren = '1') and init_done = '1' else '0';
    i_load <= '1' when i_st = S_IDLE and i_ins_rden = '1' and init_done = '1' else '0';

    u_data_latency : entity work.latency_counter
        generic map (
            max_count => latency + 1
        )
        port map (
            i_clk   => i_clk,
            i_rst   => i_rst,
            i_load  => d_load,
            i_count => latency,
            o_last  => d_last,
            o_wait  => open
        );

    u_instruction_latency : entity work.latency_counter
        generic map (
            max_count => latency + 1
        )
        port map (
            i_clk   => i_clk,
            i_rst   => i_rst,
            i_load  => i_load,
            i_count => latency,
            o_last  => i_last,
            o_wait  => open
        );

    -- Grava a imagem inicial no instante zero.
    p_load : process is

        file     f  : text;
        -- Linha de texto lida do arquivo.
        variable l  : line;
        -- Palavra de 32 bits convertida da linha.
        variable w  : std_logic_vector(31 downto 0);
        -- Indica se a conversão da linha deu certo.
        variable ok : boolean;
        -- Índice da próxima palavra a gravar.
        variable n  : natural := 0;

    begin

        if init_file'length > 0 then
            file_open(f, init_file, read_mode);

            while not endfile(f) loop

                readline(f, l);
                hread(l, w, ok);
                if ok then
                    store.set_word(n, w);
                    n := n + 1;
                end if;

            end loop;

            file_close(f);
        end if;

        wait;

    end process p_load;

    -- Porta de depuração: a palavra pedida, atualizada a cada borda e a cada troca de índice.
    p_debug : process (i_clk, i_dbg_word_addr) is
    begin

        o_dbg_word_data <= store.read_word(to_integer(unsigned(i_dbg_word_addr)));

    end process p_debug;

    -- Porta de dados.
    p_data_port : process (i_clk) is

        -- Índice da primeira palavra do acesso da porta de dados.
        variable base : natural;

    begin

        if rising_edge(i_clk) then
            if i_rst = '1' then
                d_st      <= S_IDLE;
                init_done <= '0';
            else
                init_done <= '1';

                case d_st is

                    when S_IDLE =>

                        if (i_rden = '1' or i_wren = '1') and init_done = '1' then
                            d_addr  <= start_addr(i_addr, i_line);
                            d_line  <= i_line;
                            d_we    <= i_wren;
                            d_wdata <= i_wdata;
                            d_be    <= i_byteena;
                            d_wdx   <= i_wdata_x;
                            d_bex   <= i_byteena_x;
                            d_st    <= S_WAIT;
                        end if;

                    when S_WAIT =>

                        if d_last = '1' then
                            base := word_index(d_addr);
                            if d_we = '1' then
                                if base < WORDS then
                                    store.write_word(base, d_wdata, d_be);
                                    if d_line = '1' then
                                        store.write_word(base + 1, d_wdx(31 downto 0), d_bex(3 downto 0));
                                        store.write_word(base + 2, d_wdx(63 downto 32), d_bex(7 downto 4));
                                        store.write_word(base + 3, d_wdx(95 downto 64), d_bex(11 downto 8));
                                    end if;
                                end if;
                            else
                                d_pending <= store.read_word(base);
                                if d_line = '1' then
                                    d_pend_x <= store.read_word(base + 3) & store.read_word(base + 2)
                                                & store.read_word(base + 1);
                                end if;
                            end if;
                            d_st <= S_DONE;
                        end if;

                    when S_DONE =>

                        if i_mem_advance = '1' then
                            if d_we = '0' then
                                d_rdata <= d_pending;
                                d_rdx   <= d_pend_x;
                            end if;
                            d_st <= S_IDLE;
                        end if;

                end case;

            end if;
        end if;

    end process p_data_port;

    -- Porta de instruções.
    p_instruction_port : process (i_clk) is

        -- Índice da primeira palavra do acesso da porta de instruções.
        variable base : natural;

    begin

        if rising_edge(i_clk) then
            if i_rst = '1' then
                i_st <= S_IDLE;
            else

                case i_st is

                    when S_IDLE =>

                        if i_ins_rden = '1' and init_done = '1' then
                            i_addr_q <= start_addr(i_ins_addr, i_ins_line);
                            i_line_q <= i_ins_line;
                            i_st     <= S_WAIT;
                        end if;

                    when S_WAIT =>

                        if i_last = '1' then
                            base      := word_index(i_addr_q);
                            i_pending <= store.read_word(base);
                            if i_line_q = '1' then
                                i_pend_x <= store.read_word(base + 3) & store.read_word(base + 2)
                                            & store.read_word(base + 1);
                            end if;
                            i_st <= S_DONE;
                        end if;

                    when S_DONE =>

                        if i_ins_advance = '1' then
                            i_rdata <= i_pending;
                            i_rdx   <= i_pend_x;
                            i_st    <= S_IDLE;
                        end if;

                end case;

            end if;
        end if;

    end process p_instruction_port;

end architecture rtl;
