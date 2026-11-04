-- =============================================================================
-- RAM interna (IP altsyncram de uma porta, 256 KB por padrão)
--
-- Memória de dados dentro da FPGA, com habilitação de escrita por byte (palavra de
-- 32 bits, quatro bytes de 8 bits) e regravável pela JTAG pelo In-System Memory
-- Content Editor (INSTANCE_NAME=RAM). Não é inicializada com conteúdo
-- (power_up_uninitialized = FALSE).
--
-- Leitura síncrona sem registrador de saída: o endereço é capturado na borda de
-- i_clk e a palavra aparece em o_q logo depois dela (um ciclo de latência). Em
-- leitura e escrita no mesmo endereço, a leitura devolve o dado novo
-- (NEW_DATA_NO_NBE_READ).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

library altera_mf;
use altera_mf.altera_mf_components.all;

library work;
use work.utils_pkg.all;

entity ram is
	generic (
		-- Tamanho da janela endereçável em bytes, uma potência de dois.
		size_bytes : positive := 262144;
		-- Quantidade de palavras de 32 bits fisicamente implementadas.
		word_count : positive := 65536
	);
	port (
		-- Índice da palavra (endereço de byte sem os dois bits baixos).
		i_address : in  std_logic_vector (log2_exact(size_bytes) - 3 downto 0);
		-- Habilita de bytes da escrita, um bit por byte da palavra ('1' escreve o byte).
		i_byteena : in  std_logic_vector (3 downto 0) := (others => '1');
		-- Clock da memória; a borda de subida captura endereço, dado e habilitações.
		i_clk     : in  std_logic := '1';
		-- Dado de escrita.
		i_data    : in  std_logic_vector (31 downto 0);
		-- Habilita a leitura quando em '1'.
		i_rden    : in  std_logic := '1';
		-- Habilita a escrita quando em '1'.
		i_wren    : in  std_logic;
		-- Palavra lida.
		o_q       : out std_logic_vector (31 downto 0)
	);
end entity ram;

architecture rtl of ram is
begin
	assert word_count <= size_bytes / 4
		report "word_count exceeds the addressable window"
		severity failure;

	u_altsyncram : altsyncram
	generic map (
		byte_size => 8,
		clock_enable_input_a => "BYPASS",
		clock_enable_output_a => "BYPASS",
		intended_device_family => "Cyclone V",
		lpm_hint => "ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=RAM",
		lpm_type => "altsyncram",
		numwords_a => word_count,
		operation_mode => "SINGLE_PORT",
		outdata_aclr_a => "NONE",
		outdata_reg_a => "UNREGISTERED",
		power_up_uninitialized => "FALSE",
		read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ",
		widthad_a => log2_exact(size_bytes) - 2,
		width_a => 32,
		width_byteena_a => 4
	)
	port map (
		address_a => i_address,
		byteena_a => i_byteena,
		clock0 => i_clk,
		data_a => i_data,
		rden_a => i_rden,
		wren_a => i_wren,
		q_a => o_q
	);

end architecture rtl;
