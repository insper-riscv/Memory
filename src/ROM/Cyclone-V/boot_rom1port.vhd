-- ============================================================================
-- Memória da BOOT_ROM (IP altsyncram de uma porta, 2 KB por padrão)
-- ============================================================================
-- Memória do carregador de partida, fixo e genérico. É gravada uma vez, na
-- compilação completa do Quartus, com o init_file "./boot_rom_init.mif", e
-- não tem acesso pela JTAG: o IP não declara ENABLE_RUNTIME_MOD, então o
-- In-System Memory Content Editor não a enxerga, e só a FLASH é regravada a
-- cada teste. O tamanho precisa concordar com o da BOOT_ROM no core e no
-- config.yaml da plataforma (2 KB são 512 palavras e 9 bits de endereço).
-- ============================================================================
LIBRARY ieee;
USE ieee.std_logic_1164.all;

LIBRARY altera_mf;
USE altera_mf.altera_mf_components.all;

LIBRARY work;
USE work.utils_pkg.all;

ENTITY boot_rom1port IS
	GENERIC
	(
		-- Tamanho da memória em bytes, uma potência de dois: é o que ela ocupa na FPGA.
		size_bytes : POSITIVE := 2048
	);
	PORT
	(
		address		: IN STD_LOGIC_VECTOR (log2_exact(size_bytes) - 3 DOWNTO 0);
		clock		: IN STD_LOGIC  := '1';
		rden		: IN STD_LOGIC  := '1';
		wren		: IN STD_LOGIC  := '0';
		data		: IN STD_LOGIC_VECTOR (31 DOWNTO 0) := (OTHERS => '0');
		q		: OUT STD_LOGIC_VECTOR (31 DOWNTO 0)
	);
END boot_rom1port;

ARCHITECTURE SYN OF boot_rom1port IS

	SIGNAL sub_wire0	: STD_LOGIC_VECTOR (31 DOWNTO 0);

BEGIN
	q    <= sub_wire0(31 DOWNTO 0);

	altsyncram_component : altsyncram
	GENERIC MAP (
		address_aclr_a => "NONE",
		clock_enable_input_a => "BYPASS",
		clock_enable_output_a => "BYPASS",
		init_file => "./boot_rom_init.mif",
		intended_device_family => "Cyclone V",
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
	PORT MAP (
		address_a => address,
		clock0 => clock,
		rden_a => rden,
		wren_a => wren,
		data_a => data,
		q_a => sub_wire0
	);

END SYN;
