-- =============================================================================
-- Carregador da FLASH
--
-- Escreve e lê palavras da FLASH em nome do hospedeiro, pela porta B, no clock
-- dessa porta. Um comando é a inversão de cmd_tog (de qualquer clock,
-- sincronizada aqui) com op/addr/data estáveis da inversão até a resposta, uma
-- inversão de done_tog. O resultado (rsp_*) fica estável desde antes dessa
-- inversão até o próximo comando ser aceito.
--
-- A porta B é do estágio MEM, que lê a FLASH como dado, até o comando de parada. A
-- parada ('1' em o_halt) tem de ser ligada ao reset do núcleo: com o núcleo
-- parado, a porta B passa a ser do carregador, e só então as escritas e as
-- leituras dele valem. Com o núcleo em execução, a habilitação de escrita da
-- porta B é forçada a '0' em hardware, e o pedido do hospedeiro é recusado e
-- fica registrado no status. O núcleo nunca escreve na FLASH.
--
-- Comandos (op):
--
--   0  nada (resolvido no flash_jtag_core)
--   1  para o núcleo, zera a soma de verificação e a contagem de escritas
--   2  libera o núcleo
--   3  escreve data na palavra em addr (recusado com o núcleo em execução)
--   4  lê a palavra em addr (recusado com o núcleo em execução)
--   5  devolve a soma de verificação em rsp_data e a contagem em rsp_addr
--   6  posiciona o cursor (resolvido no flash_jtag_core)
--
-- A soma de verificação acumula, a cada escrita, o dado mais o endereço da
-- palavra (módulo 2**32), o que denuncia palavra perdida, repetida ou fora de
-- lugar. rsp_status: bit 0 núcleo parado, bit 1 pedido recusado desde a última
-- parada.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity flash_loader is
    generic (
        -- Largura em bits do índice de palavra da FLASH.
        addr_width : positive := 13
    );
    port (
        -- Clock da porta B da FLASH.
        i_clk : in    std_logic;
        -- Reset do carregador, ativo em '1'; não pode depender de o_halt.
        i_rst : in    std_logic;

        -- Alternância que pede um comando: cada inversão é um comando novo.
        i_cmd_tog    : in    std_logic;
        -- Alternância que confirma o comando concluído.
        o_done_tog   : out   std_logic;
        -- Código do comando (1 a 5).
        i_op         : in    std_logic_vector(3 downto 0);
        -- Índice de palavra do comando.
        i_addr       : in    std_logic_vector(23 downto 0);
        -- Dado de escrita do comando.
        i_data       : in    std_logic_vector(31 downto 0);
        -- Índice da palavra da última resposta ou a contagem de escritas.
        o_rsp_addr   : out   std_logic_vector(23 downto 0);
        -- Dado devolvido pela última leitura ou a soma de verificação.
        o_rsp_data   : out   std_logic_vector(31 downto 0);
        -- Status: bit 0 núcleo parado, bit 1 pedido recusado.
        o_rsp_status : out   std_logic_vector(7 downto 0);

        -- Núcleo parado ('1'): ligar ao reset do núcleo.
        o_halt : out   std_logic;

        -- Índice de palavra pedido pelo estágio MEM.
        i_mem_address : in    std_logic_vector(addr_width - 1 downto 0);
        -- Habilita de leitura do estágio MEM.
        i_mem_rden    : in    std_logic;

        -- Índice de palavra da porta B da FLASH.
        o_address_b : out   std_logic_vector(addr_width - 1 downto 0);
        -- Habilita de leitura da porta B da FLASH.
        o_rden_b    : out   std_logic;
        -- Habilita de escrita da porta B da FLASH.
        o_wren_b    : out   std_logic;
        -- Dado de escrita da porta B da FLASH.
        o_data_b    : out   std_logic_vector(31 downto 0);
        -- Palavra lida pela porta B da FLASH.
        i_q_b       : in    std_logic_vector(31 downto 0)
    );
end entity flash_loader;

architecture rtl of flash_loader is

    -- Comando que para o núcleo.
    constant OP_HALT    : std_logic_vector(3 downto 0) := x"1";
    -- Comando que libera o núcleo.
    constant OP_RUN     : std_logic_vector(3 downto 0) := x"2";
    -- Comando que escreve uma palavra.
    constant OP_WRITE   : std_logic_vector(3 downto 0) := x"3";
    -- Comando que lê uma palavra.
    constant OP_READ    : std_logic_vector(3 downto 0) := x"4";
    -- Comando que devolve a soma de verificação e a contagem.
    constant OP_SUMMARY : std_logic_vector(3 downto 0) := x"5";

    -- Estados do carregador.
    type state_t is (ST_IDLE, ST_READ_ADDRESS, ST_READ_DATA);

    -- Estado corrente.
    signal st        : state_t                                   := ST_IDLE;
    -- cmd_tog como vetor de um bit, entrada do sincronizador.
    signal cmd_tog_v : std_logic_vector(0 downto 0);
    -- cmd_tog sincronizado em i_clk por dois estágios.
    signal cmd_s     : std_logic_vector(0 downto 0);
    -- Valor anterior de cmd_s, terceiro estágio da cadeia, que permite ver a inversão do toggle.
    signal cmd_prev  : std_logic                                 := '0';
    -- Alternância de resposta (registrada).
    signal done_i    : std_logic                                 := '0';
    -- Núcleo parado.
    signal halt      : std_logic                                 := '0';
    -- Algum pedido foi recusado desde a última parada.
    signal refused   : std_logic                                 := '0';
    -- Índice de palavra aplicado à porta B quando ela é do carregador.
    signal address_r : std_logic_vector(addr_width - 1 downto 0) := (others => '0');
    -- Dado aplicado à porta B quando ela é do carregador.
    signal data_r    : std_logic_vector(31 downto 0)             := (others => '0');
    -- Pulso de escrita do carregador.
    signal wren_r    : std_logic                                 := '0';
    -- Pulso de leitura do carregador.
    signal rden_r    : std_logic                                 := '0';
    -- Soma de verificação das palavras escritas.
    signal sum       : unsigned(31 downto 0)                     := (others => '0');
    -- Quantidade de palavras escritas desde a última parada.
    signal count     : unsigned(23 downto 0)                     := (others => '0');
    -- Índice da palavra da última resposta.
    signal rsp_addr  : std_logic_vector(23 downto 0)             := (others => '0');
    -- Dado da última resposta.
    signal rsp_data  : std_logic_vector(31 downto 0)             := (others => '0');
    -- Há um comando novo a executar.
    signal new_cmd   : std_logic;

begin

    cmd_tog_v(0) <= i_cmd_tog;

    -- Cruza o toggle de comando do domínio da JTAG para o clock da porta B.
    u_sync_cmd : entity work.synchronizer
        generic map (
            stages => 2, data_width => 1
        )
        port map (
            i_clk => i_clk,
            i_d   => cmd_tog_v,
            o_d   => cmd_s
        );

    new_cmd      <= '1' when cmd_prev /= cmd_s(0) else '0';
    o_done_tog   <= done_i;
    o_halt       <= halt;
    o_rsp_addr   <= rsp_addr;
    o_rsp_data   <= rsp_data;
    o_rsp_status <= "000000" & refused & halt;

    -- A porta B é do estágio MEM, salvo com o núcleo parado; a escrita só passa com ele parado.
    o_address_b <= address_r when halt = '1' else i_mem_address;
    o_rden_b    <= rden_r when halt = '1' else i_mem_rden;
    o_wren_b    <= wren_r and halt;
    o_data_b    <= data_r;

    process (i_clk) is
    begin

        if rising_edge(i_clk) then
            cmd_prev <= cmd_s(0);

            if i_rst = '1' then
                st      <= ST_IDLE;
                done_i  <= i_cmd_tog;
                halt    <= '0';
                refused <= '0';
                wren_r  <= '0';
                rden_r  <= '0';
                sum     <= (others => '0');
                count   <= (others => '0');
            else
                wren_r <= '0';

                case st is

                    when ST_IDLE =>

                        if new_cmd = '1' then

                            case i_op is

                                when OP_HALT =>

                                    halt    <= '1';
                                    refused <= '0';
                                    sum     <= (others => '0');
                                    count   <= (others => '0');
                                    done_i  <= not done_i;

                                when OP_RUN =>

                                    halt   <= '0';
                                    rden_r <= '0';
                                    done_i <= not done_i;

                                when OP_WRITE =>

                                    if halt = '1' then
                                        address_r <= i_addr(addr_width - 1 downto 0);
                                        data_r    <= i_data;
                                        wren_r    <= '1';
                                        sum       <= sum + unsigned(i_data) + unsigned(i_addr);
                                        count     <= count + 1;
                                    else
                                        refused <= '1';
                                    end if;
                                    done_i <= not done_i;

                                when OP_READ =>

                                    if halt = '1' then
                                        address_r <= i_addr(addr_width - 1 downto 0);
                                        rden_r    <= '1';
                                        st        <= ST_READ_ADDRESS;
                                    else
                                        refused <= '1';
                                        done_i  <= not done_i;
                                    end if;

                                when OP_SUMMARY =>

                                    rsp_data <= std_logic_vector(sum);
                                    rsp_addr <= std_logic_vector(count);
                                    done_i   <= not done_i;

                                when others =>

                                    done_i <= not done_i;

                            end case;

                        end if;

                    -- A porta B captura o endereço nesta borda.
                    when ST_READ_ADDRESS =>

                        st <= ST_READ_DATA;

                    -- A palavra está na saída da porta B.
                    when ST_READ_DATA =>

                        rsp_data <= i_q_b;
                        rsp_addr <= std_logic_vector(resize(unsigned(address_r), 24));
                        rden_r   <= '0';
                        done_i   <= not done_i;
                        st       <= ST_IDLE;

                end case;

            end if;
        end if;

    end process;

end architecture rtl;
