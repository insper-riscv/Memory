-- =============================================================================
-- Segunda cópia física da FLASH interna, lida pelo estágio MEM (IP altsyncram)
--
-- Existe para que o laço de cópia de .data do boot_rom.S consiga ler a FLASH como
-- dado. Não é a porta B de uma FLASH de duas portas: um altsyncram DUAL_PORT com
-- ENABLE_RUNTIME_MOD=YES não compila nesta edição do Quartus. É um clone exato do
-- flash, só com INSTANCE_NAME=FLASH_MEM, para o In-System Memory Content Editor
-- tratá-lo como uma instância JTAG separada.
--
-- As duas cópias precisam ter sempre o mesmo conteúdo, e a ferramenta de carga
-- regrava ambas a cada troca de teste. A BOOT_ROM não precisa de cópia, porque nunca
-- é lida como dado.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

library altera_mf;
use altera_mf.altera_mf_components.all;

library work;
use work.utils_pkg.all;

entity flash_mem is
	generic (
		-- Tamanho da memória em bytes, uma potência de dois: é o que ela ocupa na FPGA.
		size_bytes : positive := 32768
	);
	port (
		-- Índice da palavra (endereço de byte sem os dois bits baixos).
		i_address : in  std_logic_vector (log2_exact(size_bytes) - 3 downto 0);
		-- Clock da memória; a borda de subida captura endereço, dado e habilitações.
		i_clk     : in  std_logic := '1';
		-- Habilita a leitura quando em '1'.
		i_rden    : in  std_logic := '1';
		-- Habilita a escrita quando em '1'.
		i_wren    : in  std_logic := '0';
		-- Dado de escrita.
		i_data    : in  std_logic_vector (31 downto 0) := (others => '0');
		-- Palavra lida.
		o_q       : out std_logic_vector (31 downto 0)
	);
end entity flash_mem;

architecture rtl of flash_mem is
begin

	u_altsyncram : altsyncram
	generic map (
		address_aclr_a => "NONE",
		clock_enable_input_a => "BYPASS",
		clock_enable_output_a => "BYPASS",
		init_file => "./init.mif",
		intended_device_family => "Cyclone V",
		lpm_hint => "ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=FLASH_MEM",
		lpm_type => "altsyncram",
		numwords_a => size_bytes / 4,
		operation_mode => "SINGLE_PORT",
		outdata_aclr_a => "NONE",
		outdata_reg_a => "UNREGISTERED",
		read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ",
		widthad_a => log2_exact(size_bytes) - 2,
		width_a => 32,
		width_byteena_a => 1
	)
	port map (
		address_a => i_address,
		clock0 => i_clk,
		rden_a => i_rden,
		wren_a => i_wren,
		data_a => i_data,
		q_a => o_q
	);

end architecture rtl;
