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
		-- Clock do core.
		i_clk   : in  std_logic;
		-- Reset síncrono, ativo em nível alto.
		i_rst   : in  std_logic;
		-- Deslocamento de palavra dentro da janela do periférico.
		i_addr  : in  std_logic_vector(7 downto 0);
		-- Dado escrito pelo core.
		i_wdata : in  std_logic_vector(31 downto 0);
		-- Pulso de escrita do core.
		i_we    : in  std_logic;
		-- Pulso de leitura do core.
		i_re    : in  std_logic;
		-- Dado lido pelo core.
		o_rdata : out std_logic_vector(31 downto 0);
		-- Segmentos dos seis displays (nível baixo), HEX0 nos bits 6:0.
		o_hex   : out std_logic_vector(41 downto 0);
		-- Valor guardado, para os LEDs.
		o_value : out std_logic_vector(23 downto 0)
	);
end entity seg_display_shell;

architecture rtl of seg_display_shell is

	-- Sinais da instância do Virtual JTAG.
	signal tck, tdi, tdo : std_logic;
	signal ir_in         : std_logic_vector(1 downto 0);
	signal st_cdr, st_sdr, st_udr, st_uir : std_logic;
	signal unused_e1dr, unused_pdr, unused_e2dr, unused_cir : std_logic;

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
