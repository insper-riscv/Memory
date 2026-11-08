-- =============================================================================
-- Armazenamento da FLASH externa (instância de uma porta da block_ram, 256 KB por padrão)
--
-- Bloco de RAM da FPGA que guarda o conteúdo atrás do flash_chip, na região da FLASH
-- externa. Não é um modelo de chip: o handshake e a latência de leitura ficam no
-- flash_chip, que apenas comanda esta memória.
--
-- Inicializada pelo init_file "./flash_init.mif" e regravada pela JTAG a cada teste
-- pelo In-System Memory Content Editor (INSTANCE_NAME=FLASH).
--
-- Leitura síncrona sem registrador de saída: o endereço é capturado na borda de
-- i_clk e a palavra aparece em o_q logo depois dela (um ciclo de latência).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

library work;
use work.utils_pkg.all;

entity flash_store is
	generic (
		-- Tamanho da memória em bytes, uma potência de dois: é o que ela ocupa na FPGA.
		size_bytes : positive := 262144
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
end entity flash_store;

architecture rtl of flash_store is
begin

	u_block_ram : entity work.block_ram
	generic map (
		operation_mode => "SINGLE_PORT",
		word_count => size_bytes / 4,
		address_width => log2_exact(size_bytes) - 2,
		init_file => "./flash_init.mif",
		instance_name => "FLASH"
	)
	port map (
		i_clk_a => i_clk,
		i_address_a => i_address,
		i_data_a => i_data,
		i_rden_a => i_rden,
		i_wren_a => i_wren,
		o_q_a => o_q
	);

end architecture rtl;
