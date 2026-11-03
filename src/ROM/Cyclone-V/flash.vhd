-- =============================================================================
-- FLASH interna lida pelo estágio de busca (IP altsyncram de uma porta, 32 KB)
--
-- Guarda o firmware do teste (trampolim .flash_entry e .text), inicializado pelo
-- init_file "./init.mif" e regravado pela JTAG a cada teste pelo In-System Memory
-- Content Editor (INSTANCE_NAME=FLASH).
--
-- O decodificador do estágio IF usa o endereço sem subtrair a base, então o IP é
-- dimensionado para cobrir todo o intervalo de zero até o início da RAM, e não só a
-- faixa lógica da FLASH. A imagem de cada teste é preenchida à esquerda com zeros
-- até a base da FLASH antes de virar .mif.
--
-- Leitura síncrona sem registrador de saída: o endereço é capturado na borda de
-- i_clk e a palavra aparece em o_q logo depois dela (um ciclo de latência).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

library altera_mf;
use altera_mf.altera_mf_components.all;

library work;
use work.utils_pkg.all;

entity flash is
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
end entity flash;

architecture rtl of flash is
begin

	u_altsyncram : altsyncram
	generic map (
		address_aclr_a => "NONE",
		clock_enable_input_a => "BYPASS",
		clock_enable_output_a => "BYPASS",
		init_file => "./init.mif",
		intended_device_family => "Cyclone V",
		lpm_hint => "ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=FLASH",
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
