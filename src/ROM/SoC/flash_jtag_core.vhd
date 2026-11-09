-- =============================================================================
-- Porta JTAG do carregador da FLASH
--
-- Lógica atrás de uma instância do Virtual JTAG (sld_virtual_jtag no invólucro
-- flash_jtag_shell, conduzida pelo testbench em simulação), no clock JTAG tck, e
-- a entrega dos comandos ao flash_loader, que roda no clock da porta B da FLASH.
--
-- O Virtual JTAG tem um registrador de instrução de 2 bits e um registrador de
-- dados por instrução:
--
--   instrução 1  registrador CMD de 64 bits, um comando por deslocamento
--   instrução 2  registrador STREAM, de comprimento livre: o primeiro bit '1'
--                deslocado é o bit de início, e a cada 32 bits depois dele uma
--                palavra é escrita no cursor, que avança. Os bits anteriores
--                ao bit de início e os que não completam uma palavra são
--                descartados, o que torna o quadro independente do atraso
--                que o hub do Virtual JTAG põe entre os estados e o dado
--   outra        bypass de 1 bit
--
-- Um deslocamento do CMD traz um comando e envia o estado do último:
--
--   entra   [63:60] op   [55:32] endereço de palavra   [31:0] dado
--   sai     [63:56] status   [55:32] endereço da última resposta   [31:0] dado
--
--   bit 0 do status  ocupado: o comando anterior não terminou (endereço e dado ainda inválidos)
--   bit 1 do status  parado: o núcleo está parado e a porta B pertence ao carregador
--   bit 2 do status  recusado: uma leitura ou escrita chegou com o núcleo em execução
--   bit 3 do status  sobrecarga: uma palavra chegou com o carregador ocupado e foi descartada
--
-- Operações (op): 0 só lê o status; 1 para o núcleo; 2 libera o núcleo; 3 escreve
-- o dado no endereço; 4 lê o endereço; 5 devolve a soma de verificação (dado) e a
-- quantidade de palavras escritas (endereço); 6 posiciona o cursor do STREAM. Em
-- 3 e 4 o cursor passa a apontar o endereço seguinte. O comando sai quando o
-- deslocamento termina (estado update). O status de um comando só está
-- atualizado alguns clocks JTAG depois do envio, então o primeiro deslocamento
-- após um comando ainda pode mostrar ocupado e o seguinte não. As saídas de
-- comando ficam estáveis até o próximo comando aceito; done_tog e rsp_* são lidos
-- por um sincronizador em tck.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity flash_jtag_core is
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

        -- Alternância que pede um comando ao carregador.
        o_cmd_tog    : out   std_logic;
        -- Operação do comando.
        o_op         : out   std_logic_vector(3 downto 0);
        -- Endereço de palavra do comando.
        o_addr       : out   std_logic_vector(23 downto 0);
        -- Dado do comando.
        o_data       : out   std_logic_vector(31 downto 0);
        -- Alternância que confirma o comando concluído.
        i_done_tog   : in    std_logic;
        -- Endereço da resposta do comando.
        i_rsp_addr   : in    std_logic_vector(23 downto 0);
        -- Dado da resposta do comando.
        i_rsp_data   : in    std_logic_vector(31 downto 0);
        -- Status da resposta do comando: bit 0 parado, bit 1 recusado.
        i_rsp_status : in    std_logic_vector(7 downto 0)
    );
end entity flash_jtag_core;

architecture rtl of flash_jtag_core is

    -- Operação que só lê o status.
    constant OP_NOP    : std_logic_vector(3 downto 0) := x"0";
    -- Operação que escreve uma palavra, a do STREAM e a do CMD.
    constant OP_WRITE  : std_logic_vector(3 downto 0) := x"3";
    -- Operação que posiciona o cursor do STREAM, resolvida aqui.
    constant OP_CURSOR : std_logic_vector(3 downto 0) := x"6";
    -- Operação que lê uma palavra e move o cursor, resolvida aqui no cursor.
    constant OP_READ   : std_logic_vector(3 downto 0) := x"4";

    -- Instrução que seleciona o registrador CMD.
    constant IR_CMD    : std_logic_vector(1 downto 0) := "01";
    -- Instrução que seleciona o registrador STREAM.
    constant IR_STREAM : std_logic_vector(1 downto 0) := "10";

    -- Registrador de instrução do Virtual JTAG.
    signal ir         : std_logic_vector(1 downto 0)  := (others => '0');
    -- Registrador de deslocamento do CMD e do STREAM.
    signal sr         : std_logic_vector(63 downto 0) := (others => '0');
    -- Registrador de bypass de 1 bit.
    signal bypass     : std_logic                     := '0';
    -- Alternância de comando ao carregador (registrada).
    signal cmd_i      : std_logic                     := '0';
    -- done_tog como vetor de um bit, entrada do sincronizador.
    signal done_tog_v : std_logic_vector(0 downto 0);
    -- done_tog sincronizado em tck por dois estágios.
    signal done_sync  : std_logic_vector(0 downto 0);
    -- Um comando ou uma palavra chegou com o carregador ocupado e foi descartado.
    signal overrun    : std_logic                     := '0';
    -- O comando anterior ainda não terminou.
    signal busy       : std_logic;
    -- Operação do comando enviado (registrada).
    signal op_r       : std_logic_vector(3 downto 0)  := (others => '0');
    -- Endereço do comando enviado (registrado).
    signal addr_r     : std_logic_vector(23 downto 0) := (others => '0');
    -- Dado do comando enviado (registrado).
    signal data_r     : std_logic_vector(31 downto 0) := (others => '0');
    -- Endereço onde a próxima palavra do STREAM é escrita.
    signal cursor     : unsigned(23 downto 0)         := (others => '0');
    -- Bits já deslocados da palavra corrente do STREAM.
    signal bit_cnt    : unsigned(4 downto 0)          := (others => '0');
    -- O bit de início do STREAM já passou: os bits seguintes são palavras.
    signal started    : std_logic                     := '0';

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
    o_addr    <= addr_r;
    o_data    <= data_r;
    o_tdo     <= sr(0) when ir = IR_CMD or ir = IR_STREAM else bypass;

    p_jtag_shift : process (i_tck) is

        -- Operação do comando que acabou de ser deslocado no CMD.
        variable cmd_op : std_logic_vector(3 downto 0);

    begin

        if rising_edge(i_tck) then
            cmd_op := sr(63 downto 60);

            if i_state_uir = '1' then
                ir <= i_ir_in;
            end if;

            if i_state_cdr = '1' then
                bit_cnt <= (others => '0');
                started <= '0';
                if ir = IR_CMD then
                    sr <= ("0000" & overrun & i_rsp_status(1 downto 0) & busy) & i_rsp_addr & i_rsp_data;
                end if;
            elsif i_state_sdr = '1' then
                if ir = IR_CMD then
                    sr <= i_tdi & sr(63 downto 1);
                elsif ir = IR_STREAM then
                    sr <= i_tdi & sr(63 downto 1);
                    if started = '0' then
                        -- Espera o bit de início, que vale '1'.
                        started <= i_tdi;
                    else
                        bit_cnt <= bit_cnt + 1;
                    end if;
                    -- Quando o trigésimo segundo bit depois do início chega, a palavra está completa.
                    if started = '1' and bit_cnt = 31 then
                        if busy = '1' then
                            overrun <= '1';
                        else
                            op_r   <= OP_WRITE;
                            addr_r <= std_logic_vector(cursor);
                            data_r <= i_tdi & sr(63 downto 33);
                            cursor <= cursor + 1;
                            cmd_i  <= not cmd_i;
                        end if;
                    end if;
                else
                    bypass <= i_tdi;
                end if;
            elsif i_state_udr = '1' then
                -- op 0 é só um jeito de ler o status: não envia nada
                if ir = IR_CMD and cmd_op /= OP_NOP then
                    if cmd_op = OP_CURSOR then
                        cursor <= unsigned(sr(55 downto 32));
                    elsif busy = '1' then
                        overrun <= '1';
                    else
                        overrun <= '0';
                        op_r    <= cmd_op;
                        addr_r  <= sr(55 downto 32);
                        data_r  <= sr(31 downto 0);
                        cmd_i   <= not cmd_i;
                        if cmd_op = OP_WRITE or cmd_op = OP_READ then
                            cursor <= unsigned(sr(55 downto 32)) + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;

    end process p_jtag_shift;

end architecture rtl;
