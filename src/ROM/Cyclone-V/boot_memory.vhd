-- =============================================================================
-- Memória da BOOT_MEMORY (instância de uma porta da block_ram, 4 KB por padrão)
--
-- Memória do carregador de partida, fixo e genérico. É gravada uma vez, na
-- compilação completa do Quartus, com o init_file "./boot_memory_init.mif", e não tem
-- acesso pela JTAG: a instância não dá instance_name (sem ENABLE_RUNTIME_MOD), então o In-System Memory
-- Content Editor não a enxerga, e só a FLASH é regravada a cada teste. O tamanho
-- precisa concordar com o da BOOT_MEMORY no core e no config.yaml da plataforma (4 KB
-- são 1024 palavras e 10 bits de endereço).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

library work;
use work.utils_pkg.all;

entity boot_memory is
	generic (
		-- Tamanho da memória em bytes, uma potência de dois: é o que ela ocupa na FPGA.
		size_bytes : positive := 4096
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
end entity boot_memory;

architecture rtl of boot_memory is
begin

	u_block_ram : entity work.block_ram
	generic map (
		operation_mode => "SINGLE_PORT",
		word_count => size_bytes / 4,
		address_width => log2_exact(size_bytes) - 2,
		init_file => "./boot_memory_init.mif"
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
