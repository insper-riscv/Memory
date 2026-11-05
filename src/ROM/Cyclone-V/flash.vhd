-- =============================================================================
-- FLASH interna em uma só cópia (IP altsyncram de duas portas verdadeiras)
--
-- Guarda o firmware do teste (trampolim .flash_entry e .text), inicializado pelo
-- init_file "./init.mif". A porta A é lida pelo estágio de busca (IF) e a porta
-- B, pelo estágio MEM como dado e pelo carregador (flash_loader) como escrita. O
-- núcleo só lê: a escrita existe apenas na porta B, e o flash_loader a habilita
-- só com o núcleo parado. O IP não usa ENABLE_RUNTIME_MOD (o Quartus Lite não o
-- aceita em duas portas), então a regravação não passa pelo Memory Content Editor.
--
-- O decodificador do estágio IF usa o endereço sem subtrair a base, então o IP é
-- dimensionado para cobrir todo o intervalo de zero até o início da RAM, e não só a
-- faixa lógica da FLASH. A imagem de cada teste é preenchida à esquerda com zeros
-- até a base da FLASH antes de virar .mif.
--
-- Leitura síncrona sem registrador de saída nas duas portas: o endereço é
-- capturado na borda do clock da porta e a palavra aparece na saída logo depois
-- dela (um ciclo de latência). O parâmetro maximum_depth fixa 2048 palavras por
-- bloco, o que faz o Quartus usar o modo 2048x5 do M10K, o mais denso em duas
-- portas verdadeiras para 32 bits de largura.
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
		-- Clock da porta A; a borda de subida captura o endereço e a habilitação.
		i_clk_a     : in  std_logic := '1';
		-- Índice da palavra lida pela porta A (endereço de byte sem os dois bits baixos).
		i_address_a : in  std_logic_vector (log2_exact(size_bytes) - 3 downto 0);
		-- Habilita a leitura da porta A quando em '1'.
		i_rden_a    : in  std_logic := '1';
		-- Palavra lida pela porta A.
		o_q_a       : out std_logic_vector (31 downto 0);
		-- Clock da porta B; a borda de subida captura endereço, dado e habilitações.
		i_clk_b     : in  std_logic := '1';
		-- Índice da palavra acessada pela porta B.
		i_address_b : in  std_logic_vector (log2_exact(size_bytes) - 3 downto 0);
		-- Habilita a leitura da porta B quando em '1'.
		i_rden_b    : in  std_logic := '1';
		-- Habilita a escrita da porta B quando em '1'.
		i_wren_b    : in  std_logic := '0';
		-- Dado de escrita da porta B.
		i_data_b    : in  std_logic_vector (31 downto 0) := (others => '0');
		-- Palavra lida pela porta B.
		o_q_b       : out std_logic_vector (31 downto 0)
	);
end entity flash;

architecture rtl of flash is

	-- Palavras por bloco de memória, o que seleciona o modo 2048x5 do M10K.
	constant BLOCK_DEPTH : positive := 2048;

begin

	u_altsyncram : altsyncram
	generic map (
		address_reg_b => "CLOCK1",
		clock_enable_input_a => "BYPASS",
		clock_enable_input_b => "BYPASS",
		clock_enable_output_a => "BYPASS",
		clock_enable_output_b => "BYPASS",
		init_file => "./init.mif",
		intended_device_family => "Cyclone V",
		lpm_type => "altsyncram",
		maximum_depth => BLOCK_DEPTH,
		numwords_a => size_bytes / 4,
		numwords_b => size_bytes / 4,
		operation_mode => "BIDIR_DUAL_PORT",
		outdata_aclr_a => "NONE",
		outdata_aclr_b => "NONE",
		outdata_reg_a => "UNREGISTERED",
		outdata_reg_b => "UNREGISTERED",
		power_up_uninitialized => "FALSE",
		read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ",
		read_during_write_mode_port_b => "NEW_DATA_NO_NBE_READ",
		widthad_a => log2_exact(size_bytes) - 2,
		widthad_b => log2_exact(size_bytes) - 2,
		width_a => 32,
		width_b => 32,
		width_byteena_a => 1,
		width_byteena_b => 1,
		wrcontrol_wraddress_reg_b => "CLOCK1"
	)
	port map (
		address_a => i_address_a,
		address_b => i_address_b,
		clock0 => i_clk_a,
		clock1 => i_clk_b,
		data_a => (others => '0'),
		data_b => i_data_b,
		rden_a => i_rden_a,
		rden_b => i_rden_b,
		wren_a => '0',
		wren_b => i_wren_b,
		q_a => o_q_a,
		q_b => o_q_b
	);

end architecture rtl;
