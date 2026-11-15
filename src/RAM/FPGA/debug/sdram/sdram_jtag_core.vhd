-- =============================================================================
-- Porta JTAG da depuração da SDRAM
--
-- Lógica atrás de uma instância do Virtual JTAG (sld_virtual_jtag no topo da
-- placa, conduzida pelo testbench em simulação), no clock JTAG tck, e a entrega
-- dos comandos ao sdram_dbg_master, que roda em outro clock.
--
-- O Virtual JTAG tem um registrador de instrução (aqui de 2 bits) e um
-- registrador de dados por instrução:
--
--   0 e outras  bypass de 1 bit
--   1           DEBUG, de 64 bits: um comando por deslocamento
--   2           STREAM de escrita: de 1 a 128 palavras por deslocamento
--   3           STREAM de leitura: de 1 a 128 palavras por deslocamento
--
-- DEBUG. Um deslocamento traz um comando e envia o estado do último:
--
--   entra   [63:60] op   [59:56] habilita de bytes   [55:32] endereço de palavra   [31:0] dado
--   sai     [63:56] status   [55:32] última palavra acessada   [31:0] dado lido
--
--   bit 0 do status  ocupado: o comando anterior não terminou (dado e palavra ainda inválidos)
--   bit 1 do status  erro: o controlador não respondeu
--   bit 2 do status  a SDRAM está inicializada
--   bit 3 do status  sobrecarga: um comando chegou com o mestre ocupado e foi descartado (limpa no comando seguinte)
--   bit 4 do status  erro de rajada: uma palavra da rajada anterior chegou tarde ou foi perdida (limpa no início da
--                    rajada seguinte e no comando seguinte)
--   bit 5 do status  hold: o mestre de depuração mantém o núcleo parado
--
-- O comando sai quando o deslocamento termina (estado update). Os comandos são
-- os do sdram_dbg_master, exceto op 0, que não envia nada: um deslocamento com
-- op 0 só lê o status. Também não vai ao mestre o comando op 7 com be = 2
-- (seek), que aponta o ponteiro de rajada deste bloco para o endereço de palavra
-- do comando (o bit 63 é o bit 24 do endereço). O status de um comando só está
-- atualizado alguns clocks JTAG depois do envio, então o primeiro deslocamento
-- após um comando ainda pode mostrar ocupado e o seguinte não. cmd_tog, op, be,
-- addr e data ficam estáveis até o próximo comando aceito; done_tog e rsp_* são
-- lidos por um sincronizador em tck.
--
-- Rajada. Um deslocamento das instruções 2 e 3 move palavras de 32 bits (o bit
-- menos significativo primeiro) entre o hospedeiro e a SDRAM a partir do
-- ponteiro de rajada, que avança uma palavra por palavra movida. Os primeiros 64
-- bits que saem são sempre o quadro de status do DEBUG. Com menos de 64 bits
-- deslocados o quadro sai truncado.
--
--   instrução 2  as palavras que entram (a partir do primeiro bit) são escritas
--                na SDRAM, uma por comando de escrita ao mestre, assim que
--                cada 32 bits chegam; o que sai depois do quadro de status é 0
--   instrução 3  depois do quadro de status saem as palavras lidas, a primeira
--                lida no Capture-DR e cada palavra seguinte pedida ao mestre no
--                instante em que a anterior vai para o registrador de saída;
--                o que entra é ignorado
--
-- Cada palavra tem de terminar (ocupado = 0) antes de a seguinte ser pedida:
-- com 32 clocks JTAG por palavra, isso vale quando o acesso ao chip leva menos
-- que 32 períodos de tck. Caso contrário o bit de erro de rajada sobe, a palavra
-- é perdida (escrita) ou inválida (leitura), e o hospedeiro refaz a rajada
-- depois de apontar de novo o ponteiro. Palavras além da 128ª são ignoradas. A
-- última palavra de uma rajada de leitura é seguida de uma leitura antecipada da
-- palavra seguinte, que não é entregue e não move o ponteiro: o ponteiro avança quando o primeiro bit de uma palavra
-- sai, então só as palavras que o hospedeiro deslocou contam.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_jtag_core is
    port (
        -- Clock da cadeia JTAG.
        i_tck       : in    std_logic;
        -- Dado serial vindo do hospedeiro.
        i_tdi       : in    std_logic;
        -- Dado serial para o hospedeiro.
        o_tdo       : out   std_logic;
        -- Registrador de instrução do Virtual JTAG.
        i_ir_in     : in    std_logic_vector(1 downto 0);
        -- Estado Capture-DR da cadeia virtual.
        i_state_cdr : in    std_logic;
        -- Estado Shift-DR da cadeia virtual.
        i_state_sdr : in    std_logic;
        -- Estado Update-DR da cadeia virtual.
        i_state_udr : in    std_logic;
        -- Estado Update-IR da cadeia virtual.
        i_state_uir : in    std_logic;

        -- Alternância que pede um comando ao mestre de debug.
        o_cmd_tog    : out   std_logic;
        -- Operação do comando de debug.
        o_op         : out   std_logic_vector(3 downto 0);
        -- Habilita de bytes do comando.
        o_be         : out   std_logic_vector(3 downto 0);
        -- Endereço do acesso.
        o_addr       : out   std_logic_vector(23 downto 0);
        -- Dado lido.
        -- Largura física do dispositivo ou do protocolo (32 bits), não do núcleo.
        o_data       : out   std_logic_vector(31 downto 0);
        -- Alternância que confirma o comando concluído.
        i_done_tog   : in    std_logic;
        -- Endereço da resposta do comando.
        i_rsp_addr   : in    std_logic_vector(23 downto 0);
        -- Dado da resposta do comando.
        -- Largura física do dispositivo ou do protocolo (32 bits), não do núcleo.
        i_rsp_data   : in    std_logic_vector(31 downto 0);
        -- Status da resposta do comando.
        i_rsp_status : in    std_logic_vector(7 downto 0)
    );
end entity sdram_jtag_core;

architecture rtl of sdram_jtag_core is

    -- Instrução do registrador DEBUG de 64 bits.
    constant IR_DEBUG        : std_logic_vector(1 downto 0) := "01";
    -- Instrução da rajada de escrita.
    constant IR_STREAM_WRITE : std_logic_vector(1 downto 0) := "10";
    -- Instrução da rajada de leitura.
    constant IR_STREAM_READ  : std_logic_vector(1 downto 0) := "11";

    -- Bits de uma palavra da rajada.
    constant WORD_BITS       : natural := 32;
    -- Bits do quadro de status que abre todo deslocamento de rajada e é o do DEBUG.
    constant FRAME_BITS      : natural := 64;
    -- Palavras no máximo por rajada (4096 bits).
    constant STREAM_WORDS    : natural := 128;

    -- Códigos de comando do mestre de depuração usados pela rajada, nos bits 2 a 0 de op.
    constant CODE_READ       : std_logic_vector(2 downto 0) := "001";
    -- Escrita de uma palavra.
    constant CODE_WRITE      : std_logic_vector(2 downto 0) := "010";
    -- Controle (hold, crc32 e seek).
    constant CODE_CONTROL    : std_logic_vector(2 downto 0) := "111";
    -- Subcomando seek do controle, nos bits 2 a 0 de be.
    constant CONTROL_SEEK    : std_logic_vector(2 downto 0) := "010";

    -- Registrador de instrução do Virtual JTAG.
    signal ir         : std_logic_vector(1 downto 0)  := (others => '0');
    -- Registrador de deslocamento de saída (o quadro do DEBUG e as palavras lidas pela rajada).
    signal sr         : std_logic_vector(63 downto 0) := (others => '0');
    -- Palavra em montagem a partir do dado que entra na rajada de escrita.
    signal wsr        : std_logic_vector(31 downto 0) := (others => '0');
    -- Registrador de bypass de 1 bit.
    signal bypass     : std_logic                     := '0';
    -- Toggle de comando ao mestre de debug (registrado).
    signal cmd_i      : std_logic                     := '0';
    -- done_tog como vetor de um bit, entrada do sincronizador.
    signal done_tog_v : std_logic_vector(0 downto 0);
    -- done_tog sincronizado em tck por dois estágios.
    signal done_sync  : std_logic_vector(0 downto 0);
    -- Um comando chegou com o mestre ocupado e foi descartado.
    signal overrun    : std_logic                     := '0';
    -- Uma palavra da rajada chegou tarde ou foi perdida.
    signal stream_err : std_logic                     := '0';
    -- O comando anterior ainda não terminou.
    signal busy       : std_logic;
    -- Operação do comando enviado (registrada).
    signal op_r       : std_logic_vector(3 downto 0)  := (others => '0');
    -- Habilita de bytes do comando enviado (registrado).
    signal be_r       : std_logic_vector(3 downto 0)  := (others => '0');
    -- Endereço do comando enviado (registrado).
    signal addr_r     : std_logic_vector(23 downto 0) := (others => '0');
    -- Dado do comando enviado (registrado).
    signal data_r     : std_logic_vector(31 downto 0) := (others => '0');
    -- Ponteiro de rajada: endereço de palavra da próxima palavra a mover (25 bits, como o endereço do mestre).
    signal sp         : unsigned(24 downto 0)         := (others => '0');
    -- Bits já deslocados no Shift-DR corrente (satura em 8191).
    signal cnt        : unsigned(12 downto 0)         := (others => '0');

begin

    done_tog_v(0) <= i_done_tog;

    -- Cruza o toggle de confirmação do domínio da porta B para tck.
    u_sync_done : entity work.synchronizer
        generic map (
            stages => 2, data_width => 1
        )
        port map (
            i_clk => i_tck,
            i_d   => done_tog_v,
            o_d   => done_sync
        );

    busy      <= '1' when cmd_i /= done_sync(0) else '0';
    o_cmd_tog <= cmd_i;
    o_op      <= op_r;
    o_be      <= be_r;
    o_addr    <= addr_r;
    o_data    <= data_r;
    o_tdo     <= bypass when ir = "00" else sr(0);

    p_jtag_shift : process (i_tck) is

        -- Quadro de status que sai no Capture-DR: status, última palavra acessada e dado lido.
        impure function frame return std_logic_vector is
        begin

            return "00" & i_rsp_status(4) & stream_err & overrun & i_rsp_status(2 downto 1) & busy
                   & i_rsp_addr & i_rsp_data;

        end function frame;

        -- Pede ao mestre o acesso (leitura ou escrita) da palavra a do chip, com o dado d.
        procedure send (
            code : std_logic_vector(2 downto 0);
            a    : unsigned(24 downto 0);
            d    : std_logic_vector(31 downto 0)
        ) is
        begin

            op_r   <= a(24) & code;
            be_r   <= "1111";
            addr_r <= std_logic_vector(a(23 downto 0));
            data_r <= d;
            cmd_i  <= not cmd_i;

        end procedure send;

        -- Índice (a partir de 0) do bit que o Shift-DR corrente desloca nesta borda.
        variable pos : integer;

    begin

        if rising_edge(i_tck) then
            if i_state_uir = '1' then
                ir <= i_ir_in;
            end if;

            if i_state_cdr = '1' then
                cnt <= (others => '0');
                if ir = IR_DEBUG then
                    sr <= frame;
                elsif ir = IR_STREAM_WRITE then
                    sr         <= frame;
                    stream_err <= '0';
                elsif ir = IR_STREAM_READ then
                    sr         <= frame;
                    -- a primeira palavra é lida durante o quadro de status
                    if busy = '1' then
                        stream_err <= '1';
                    else
                        stream_err <= '0';
                        send(CODE_READ, sp, (others => '0'));
                    end if;
                end if;
            elsif i_state_sdr = '1' then
                if cnt < 8191 then
                    cnt <= cnt + 1;
                end if;
                pos := to_integer(cnt);

                if ir = IR_DEBUG then
                    sr <= i_tdi & sr(63 downto 1);
                elsif ir = IR_STREAM_WRITE then
                    sr  <= '0' & sr(63 downto 1);
                    wsr <= i_tdi & wsr(31 downto 1);
                    -- ao completar uma palavra (32 bits, até a 128ª), escreve-a e avança o ponteiro
                    if pos < STREAM_WORDS * WORD_BITS and pos mod WORD_BITS = WORD_BITS - 1 then
                        if busy = '1' then
                            stream_err <= '1';
                        else
                            send(CODE_WRITE, sp, i_tdi & wsr(31 downto 1));
                            sp <= sp + 1;
                        end if;
                    end if;
                elsif ir = IR_STREAM_READ then
                    -- No último bit do quadro e no de cada palavra, a palavra lida (a do ponteiro) vai para a saída e a
                    -- seguinte é pedida. O ponteiro só avança no primeiro bit de uma palavra, que só chega se o
                    -- hospedeiro a pediu: o último bit da rajada não consome a palavra que ele carregou.
                    if pos >= FRAME_BITS - 1 and pos < FRAME_BITS - 1 + STREAM_WORDS * WORD_BITS
                       and pos mod WORD_BITS = WORD_BITS - 1 then
                        sr <= x"00000000" & i_rsp_data;
                        if busy = '1' or i_rsp_addr /= std_logic_vector(sp(23 downto 0)) then
                            stream_err <= '1';
                        else
                            send(CODE_READ, sp + 1, (others => '0'));
                        end if;
                    else
                        sr <= '0' & sr(63 downto 1);
                        if pos >= FRAME_BITS and pos mod WORD_BITS = 0 then
                            sp <= sp + 1;
                        end if;
                    end if;
                else
                    bypass <= i_tdi;
                end if;
            elsif i_state_udr = '1' then
                -- op 0 é só um jeito de ler o status: não envia nada
                if ir = IR_DEBUG and sr(63 downto 60) /= "0000" then
                    if sr(62 downto 60) = CODE_CONTROL and sr(58 downto 56) = CONTROL_SEEK then
                        -- seek: só aponta o ponteiro de rajada, o mestre não participa
                        sp         <= unsigned(sr(63 downto 63) & sr(55 downto 32));
                        stream_err <= '0';
                    elsif busy = '1' then
                        overrun <= '1';
                    else
                        overrun    <= '0';
                        stream_err <= '0';
                        op_r       <= sr(63 downto 60);
                        be_r       <= sr(59 downto 56);
                        addr_r     <= sr(55 downto 32);
                        data_r     <= sr(31 downto 0);
                        cmd_i      <= not cmd_i;
                    end if;
                end if;
            end if;
        end if;

    end process p_jtag_shift;

end architecture rtl;
