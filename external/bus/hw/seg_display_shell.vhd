-- =============================================================================
-- Registrador do display com a sua instância do Virtual JTAG
--
-- Só para a placa: usa o sld_virtual_jtag da Intel e por isso não é analisado
-- na simulação, onde o testbench faz o papel da instância e dirige seg_display
-- direto. O hospedeiro vê a instância de índice 2, ao lado da porta de debug da
-- SDRAM (0) e da UART (1), com registrador de instrução de 2 bits; a instrução 1
-- seleciona o registrador de 25 bits de seg_display.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
library altera_mf;
use altera_mf.altera_mf_components.all;

entity seg_display_shell is
	port (
		-- Clock do módulo.
		i_clk   : in  std_logic;
		-- Reset, ativo em '1'.
		i_rst   : in  std_logic;
		-- Endereço do acesso.
		i_addr  : in  std_logic_vector(7 downto 0);
		-- Dado de escrita.
		i_wdata : in  std_logic_vector(31 downto 0);
		-- Escrita ('1') ou leitura ('0').
		i_we    : in  std_logic;
		-- Leitura ('1').
		i_re    : in  std_logic;
		-- Dado lido.
		o_rdata : out std_logic_vector(31 downto 0);
		-- Segmentos dos seis displays, HEX0 nos bits 6:0 e HEX5 nos bits 41:36 (nível baixo).
		o_hex   : out std_logic_vector(41 downto 0);
		-- Valor de 24 bits guardado no registrador do display.
		o_value : out std_logic_vector(23 downto 0)
	);
end entity seg_display_shell;

architecture rtl of seg_display_shell is

	-- Clock da cadeia JTAG.
	signal tck : std_logic;
	-- Dado serial vindo do hospedeiro.
	signal tdi : std_logic;
	-- Dado serial para o hospedeiro.
	signal tdo : std_logic;
	-- Registrador de instrução do Virtual JTAG.
	signal ir_in         : std_logic_vector(1 downto 0);
	-- Estado Capture-DR da cadeia virtual.
	signal st_cdr : std_logic;
	-- Estado Shift-DR da cadeia virtual.
	signal st_sdr : std_logic;
	-- Estado Update-DR da cadeia virtual.
	signal st_udr : std_logic;
	-- Estado Update-IR da cadeia virtual.
	signal st_uir : std_logic;
	-- Estado Exit1-DR, não usado.
	signal unused_e1dr : std_logic;
	-- Estado Pause-DR, não usado.
	signal unused_pdr : std_logic;
	-- Estado Exit2-DR, não usado.
	signal unused_e2dr : std_logic;
	-- Estado Capture-IR, não usado.
	signal unused_cir : std_logic;

begin

	u_vjtag : sld_virtual_jtag
		generic map (
			lpm_type => "sld_virtual_jtag",
			lpm_hint => "sld_instance_index=2",
			sld_auto_instance_index => "NO",
			sld_instance_index => 2,
			sld_ir_width => 2,
			sld_sim_n_scan => 0,
			sld_sim_total_length => 0,
			sld_sim_action => ""
		)
		port map (
			tdo => tdo, ir_out => (others => '0'),
			tck => tck, tdi => tdi, ir_in => ir_in,
			virtual_state_cdr => st_cdr, virtual_state_sdr => st_sdr,
			virtual_state_e1dr => unused_e1dr, virtual_state_pdr => unused_pdr,
			virtual_state_e2dr => unused_e2dr, virtual_state_udr => st_udr,
			virtual_state_cir => unused_cir, virtual_state_uir => st_uir
		);

	u_display : entity work.seg_display
		port map (
			i_clk => i_clk, i_rst => i_rst, i_addr => i_addr, i_wdata => i_wdata,
			i_we => i_we, i_re => i_re, o_rdata => o_rdata,
			i_tck => tck, i_tdi => tdi, o_tdo => tdo, i_ir_in => ir_in,
			i_state_cdr => st_cdr, i_state_sdr => st_sdr, i_state_udr => st_udr, i_state_uir => st_uir,
			o_value => o_value, o_hex => o_hex
		);

end architecture rtl;
