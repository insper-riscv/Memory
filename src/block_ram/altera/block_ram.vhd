-- =============================================================================
-- Memória em bloco da Intel (altsyncram) de uma ou duas portas
--
-- Única instância do megafunction altsyncram do projeto: boot_memory, flash,
-- flash_store e ram são instâncias desta entidade e só diferem nos generics.
-- Exclusiva da FPGA (precisa da biblioteca altera_mf), então não é analisada
-- pelo GHDL da imagem de ferramentas; a simulação de topo de hardware a usa
-- pelos modelos altera_mf da Intel.
--
-- Modos (operation_mode):
--   - "SINGLE_PORT": só a porta A (i_clk_a, i_address_a, i_byteena_a, i_data_a,
--     i_rden_a, i_wren_a, o_q_a); as entradas da porta B são ignoradas e o_q_b
--     fica em zero.
--   - "BIDIR_DUAL_PORT": as portas A e B leem e escrevem, cada uma no seu clock.
--
-- Leitura síncrona sem registrador de saída: o endereço é capturado na borda de
-- subida do clock da porta e a palavra aparece na saída logo depois dela (um
-- ciclo de latência). Em leitura e escrita no mesmo endereço da mesma porta, a
-- leitura devolve o dado novo (NEW_DATA_NO_NBE_READ).
--
-- Com instance_name não vazio, o conteúdo é regravável pela JTAG pelo
-- In-System Memory Content Editor com esse nome (ENABLE_RUNTIME_MOD=YES); o
-- Quartus Lite não aceita essa opção em duas portas. Com init_file diferente de
-- "UNUSED", a memória nasce com o conteúdo do arquivo.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

library altera_mf;
use altera_mf.altera_mf_components.all;

entity block_ram is
    generic (
        -- Modo da memória: "SINGLE_PORT" ou "BIDIR_DUAL_PORT".
        operation_mode : string   := "SINGLE_PORT";
        -- Quantidade de palavras de data_width bits.
        word_count     : positive := 1024;
        -- Largura do endereço de palavra, em bits.
        address_width  : positive := 10;
        -- Largura da palavra, em bits.
        data_width     : positive := 32;
        -- Bytes habilitáveis por palavra na escrita da porta A (1 = a palavra inteira; maior que 1 só no modo de uma
        -- porta).
        byte_lanes     : positive := 1;
        -- Arquivo .mif de inicialização, ou "UNUSED" para memória sem conteúdo inicial.
        init_file      : string   := "UNUSED";
        -- Nome da instância para o In-System Memory Content Editor, ou vazio para não expor a memória pela JTAG.
        instance_name  : string   := "";
        -- Palavras por bloco de memória (maximum_depth), ou 0 para o Quartus escolher.
        block_depth    : natural  := 0;
        -- Família do dispositivo para o Quartus.
        device_family  : string   := "Cyclone V"
    );
    port (
        -- Clock da porta A; a borda de subida captura endereço, dado e habilitações.
        i_clk_a     : in    std_logic                                    := '1';
        -- Índice da palavra acessada pela porta A.
        i_address_a : in    std_logic_vector(address_width - 1 downto 0);
        -- Habilita de bytes da escrita da porta A, um bit por byte ('1' escreve o byte).
        i_byteena_a : in    std_logic_vector(byte_lanes - 1 downto 0)    := (others => '1');
        -- Dado de escrita da porta A.
        i_data_a    : in    std_logic_vector(data_width - 1 downto 0)    := (others => '0');
        -- Habilita a leitura da porta A quando em '1'.
        i_rden_a    : in    std_logic                                    := '1';
        -- Habilita a escrita da porta A quando em '1'.
        i_wren_a    : in    std_logic                                    := '0';
        -- Palavra lida pela porta A.
        o_q_a       : out   std_logic_vector(data_width - 1 downto 0);
        -- Clock da porta B (só no modo de duas portas).
        i_clk_b     : in    std_logic                                    := '1';
        -- Índice da palavra acessada pela porta B (só no modo de duas portas).
        i_address_b : in    std_logic_vector(address_width - 1 downto 0) := (others => '0');
        -- Dado de escrita da porta B (só no modo de duas portas).
        i_data_b    : in    std_logic_vector(data_width - 1 downto 0)    := (others => '0');
        -- Habilita a leitura da porta B quando em '1' (só no modo de duas portas).
        i_rden_b    : in    std_logic                                    := '1';
        -- Habilita a escrita da porta B quando em '1' (só no modo de duas portas).
        i_wren_b    : in    std_logic                                    := '0';
        -- Palavra lida pela porta B; zero no modo de uma porta.
        o_q_b       : out   std_logic_vector(data_width - 1 downto 0)
    );
end entity block_ram;

architecture rtl of block_ram is

    -- Dica de síntese que expõe a memória ao In-System Memory Content Editor.

    function runtime_hint (name : string) return string is
    begin

        if name'length > 0 then
            return "ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=" & name;
        end if;

        return "UNUSED";

    end function runtime_hint;

begin

    assert operation_mode = "SINGLE_PORT" or operation_mode = "BIDIR_DUAL_PORT"
        report "block_ram: unsupported operation_mode " & operation_mode
        severity failure;

    assert data_width mod byte_lanes = 0
        report "block_ram: data_width must be a multiple of byte_lanes"
        severity failure;

    assert operation_mode = "SINGLE_PORT" or byte_lanes = 1
        report "block_ram: byte enables are only supported in single-port mode"
        severity failure;

    -- Uma porta, escrita da palavra inteira: o Quartus rejeita o clock1 ligado e o byteena_a e o byte_size com um só
    -- byte.

    gen_single : if operation_mode = "SINGLE_PORT" and byte_lanes = 1 generate

        u_altsyncram : component altsyncram
            generic map (
                clock_enable_input_a          => "BYPASS",
                clock_enable_output_a         => "BYPASS",
                init_file                     => init_file,
                intended_device_family        => device_family,
                lpm_hint                      => runtime_hint(instance_name),
                lpm_type                      => "altsyncram",
                maximum_depth                 => block_depth,
                numwords_a                    => word_count,
                operation_mode                => "SINGLE_PORT",
                outdata_aclr_a                => "NONE",
                outdata_reg_a                 => "UNREGISTERED",
                power_up_uninitialized        => "FALSE",
                read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ",
                widthad_a                     => address_width,
                width_a                       => data_width,
                width_byteena_a               => byte_lanes
            )
            port map (
                address_a => i_address_a,
                clock0    => i_clk_a,
                data_a    => i_data_a,
                rden_a    => i_rden_a,
                wren_a    => i_wren_a,
                q_a       => o_q_a
            );

        o_q_b <= (others => '0');
    end generate gen_single;

    -- Uma porta, escrita por byte: o byte_size é de 8 bits.

    gen_single_bytes : if operation_mode = "SINGLE_PORT" and byte_lanes > 1 generate

        u_altsyncram : component altsyncram
            generic map (
                byte_size                     => 8,
                clock_enable_input_a          => "BYPASS",
                clock_enable_output_a         => "BYPASS",
                init_file                     => init_file,
                intended_device_family        => device_family,
                lpm_hint                      => runtime_hint(instance_name),
                lpm_type                      => "altsyncram",
                maximum_depth                 => block_depth,
                numwords_a                    => word_count,
                operation_mode                => "SINGLE_PORT",
                outdata_aclr_a                => "NONE",
                outdata_reg_a                 => "UNREGISTERED",
                power_up_uninitialized        => "FALSE",
                read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ",
                widthad_a                     => address_width,
                width_a                       => data_width,
                width_byteena_a               => byte_lanes
            )
            port map (
                address_a => i_address_a,
                byteena_a => i_byteena_a,
                clock0    => i_clk_a,
                data_a    => i_data_a,
                rden_a    => i_rden_a,
                wren_a    => i_wren_a,
                q_a       => o_q_a
            );

        o_q_b <= (others => '0');
    end generate gen_single_bytes;

    -- Duas portas verdadeiras, cada uma no seu clock (sem escrita por byte).

    gen_dual : if operation_mode = "BIDIR_DUAL_PORT" generate

        u_altsyncram : component altsyncram
            generic map (
                address_reg_b                 => "CLOCK1",
                clock_enable_input_a          => "BYPASS",
                clock_enable_input_b          => "BYPASS",
                clock_enable_output_a         => "BYPASS",
                clock_enable_output_b         => "BYPASS",
                init_file                     => init_file,
                intended_device_family        => device_family,
                lpm_hint                      => runtime_hint(instance_name),
                lpm_type                      => "altsyncram",
                maximum_depth                 => block_depth,
                numwords_a                    => word_count,
                numwords_b                    => word_count,
                operation_mode                => "BIDIR_DUAL_PORT",
                outdata_aclr_a                => "NONE",
                outdata_aclr_b                => "NONE",
                outdata_reg_a                 => "UNREGISTERED",
                outdata_reg_b                 => "UNREGISTERED",
                power_up_uninitialized        => "FALSE",
                read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ",
                read_during_write_mode_port_b => "NEW_DATA_NO_NBE_READ",
                widthad_a                     => address_width,
                widthad_b                     => address_width,
                width_a                       => data_width,
                width_b                       => data_width,
                width_byteena_a               => byte_lanes,
                width_byteena_b               => 1,
                wrcontrol_wraddress_reg_b     => "CLOCK1"
            )
            port map (
                address_a => i_address_a,
                address_b => i_address_b,
                clock0    => i_clk_a,
                clock1    => i_clk_b,
                data_a    => i_data_a,
                data_b    => i_data_b,
                rden_a    => i_rden_a,
                rden_b    => i_rden_b,
                wren_a    => i_wren_a,
                wren_b    => i_wren_b,
                q_a       => o_q_a,
                q_b       => o_q_b
            );

    end generate gen_dual;

end architecture rtl;
