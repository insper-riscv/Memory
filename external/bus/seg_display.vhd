-- =============================================================================
-- Registrador do display de sete segmentos com acesso do core e do hospedeiro
--
-- Guarda 24 bits que os seis displays HEX5 a HEX0 mostram em hexadecimal
-- (HEX5 é o dígito mais significativo). O valor fica no registrador entre dois
-- programas, de modo que o display não pisca durante a troca.
--
-- Lado do core (clock i_clk), um acesso por pulso de i_we ou i_re:
--   palavra 0  leitura: o valor de 24 bits; escrita: grava os 24 bits baixos
--   outras     leitura: 0; escrita: ignorada
--
-- Lado do hospedeiro: a lógica de uma instância do Virtual JTAG (tck). A
-- instrução 1 seleciona um registrador de 25 bits:
--   entrada   [23:0] valor novo; [24] 1 = grava o valor, 0 = só lê
--   saída     [23:0] valor do registrador no início da varredura
-- A instrução 2 seleciona o registrador de 2 bits da bandeira de falha:
--   entrada   [0] valor novo; [1] 1 = grava a bandeira, 0 = só lê
--   saída     [0] valor da bandeira no início da varredura
-- A bandeira não passa pelo core: o hospedeiro a liga quando um programa falha,
-- e o topo da placa a mostra em um LED. Só o hospedeiro e a reconfiguração da
-- FPGA a alteram.
-- A gravação do hospedeiro atravessa para i_clk com um toggle e dois
-- flip-flops; o valor fica parado até a varredura seguinte. Se o core grava no
-- mesmo ciclo em que a gravação do hospedeiro chega, vale o core.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity seg_display is
	port (
		-- Clock do core.
		i_clk       : in  std_logic;
		-- Reset síncrono, ativo em nível alto.
		i_rst       : in  std_logic;
		-- Deslocamento de palavra dentro da janela do periférico.
		i_addr      : in  std_logic_vector(7 downto 0);
		-- Dado escrito pelo core.
		i_wdata     : in  std_logic_vector(31 downto 0);
		-- Pulso de escrita do core ('1' = escreve).
		i_we        : in  std_logic;
		-- Pulso de leitura do core ('1' = lê).
		i_re        : in  std_logic;
		-- Dado lido pelo core, válido no ciclo do pulso.
		o_rdata     : out std_logic_vector(31 downto 0);
		-- Clock da cadeia JTAG.
		i_tck       : in  std_logic;
		-- Dado serial vindo do hospedeiro.
		i_tdi       : in  std_logic;
		-- Dado serial para o hospedeiro.
		o_tdo       : out std_logic;
		-- Registrador de instrução do Virtual JTAG.
		i_ir_in     : in  std_logic_vector(1 downto 0);
		-- Estado Capture-DR da cadeia virtual.
		i_state_cdr : in  std_logic;
		-- Estado Shift-DR da cadeia virtual.
		i_state_sdr : in  std_logic;
		-- Estado Update-DR da cadeia virtual.
		i_state_udr : in  std_logic;
		-- Estado Update-IR da cadeia virtual.
		i_state_uir : in  std_logic;
		-- Valor guardado no registrador.
		o_value     : out std_logic_vector(23 downto 0);
		-- Bandeira de falha gravada pelo hospedeiro ('1' = houve falha).
		o_fail      : out std_logic;
		-- Segmentos dos seis displays, HEX0 nos bits 6:0 e HEX5 nos bits 41:36 (nível baixo).
		o_hex       : out std_logic_vector(41 downto 0)
	);
end entity seg_display;

architecture rtl of seg_display is

	-- Valor guardado, no domínio de i_clk.
	signal value    : std_logic_vector(23 downto 0) := (others => '0');
	-- Toggle do hospedeiro sincronizado com i_clk.
	signal tog_sync : std_logic_vector(0 downto 0);
	-- Último valor do toggle já aplicado em i_clk.
	signal tog_seen : std_logic := '0';

	-- Instrução ativa do Virtual JTAG, no domínio de tck.
	signal ir       : std_logic_vector(1 downto 0) := (others => '0');
	-- Registrador de deslocamento de 25 bits, no domínio de tck.
	signal sr       : std_logic_vector(24 downto 0) := (others => '0');
	-- Registrador de deslocamento de 2 bits da bandeira de falha, no domínio de tck.
	signal fsr      : std_logic_vector(1 downto 0) := (others => '0');
	-- Bandeira de falha, no domínio de tck.
	signal fail_flag : std_logic := '0';
	-- Bit de passagem para instruções não usadas.
	signal bypass   : std_logic := '0';
	-- Valor da gravação do hospedeiro, parado até a próxima varredura.
	signal host_val : std_logic_vector(23 downto 0) := (others => '0');
	-- Toggle que sinaliza uma gravação do hospedeiro, no domínio de tck.
	signal host_tog : std_logic := '0';

begin

	-- Leva o toggle de gravação do domínio de tck ao de i_clk.
	u_sync_tog : entity work.synchronizer
		port map (
			i_clk  => i_clk,
			i_d(0) => host_tog,
			o_d    => tog_sync
		);

	o_value <= value;

	-- Leitura do core: só a palavra 0 tem conteúdo.
	process (i_addr, value)
	begin
		o_rdata <= (others => '0');
		if to_integer(unsigned(i_addr)) = 0 then
			o_rdata(23 downto 0) <= value;
		end if;
	end process;

	-- Registrador no domínio de i_clk: o core tem prioridade sobre o hospedeiro.
	process (i_clk)
	begin
		if rising_edge(i_clk) then
			if i_rst = '1' then
				value    <= (others => '0');
				tog_seen <= tog_sync(0);
			elsif i_we = '1' and to_integer(unsigned(i_addr)) = 0 then
				value <= i_wdata(23 downto 0);
			elsif tog_sync(0) /= tog_seen then
				tog_seen <= tog_sync(0);
				value    <= host_val;
			end if;
		end if;
	end process;

	o_fail <= fail_flag;

	o_tdo <= sr(0) when ir = "01" else
	         fsr(0) when ir = "10" else
	         bypass;

	-- Lado do hospedeiro, no domínio de tck.
	process (i_tck)
	begin
		if rising_edge(i_tck) then
			bypass <= i_tdi;
			if i_state_uir = '1' then
				ir <= i_ir_in;
			end if;
			if i_state_cdr = '1' then
				sr  <= '0' & value;
				fsr <= '0' & fail_flag;
			elsif i_state_sdr = '1' then
				sr  <= i_tdi & sr(24 downto 1);
				fsr <= i_tdi & fsr(1);
			elsif i_state_udr = '1' and ir = "01" and sr(24) = '1' then
				host_val <= sr(23 downto 0);
				host_tog <= not host_tog;
			elsif i_state_udr = '1' and ir = "10" and fsr(1) = '1' then
				fail_flag <= fsr(0);
			end if;
		end if;
	end process;

	gen_digits : for n in 0 to 5 generate
		u_digit : entity work.hex_to_seg7
			port map (
				i_digit => value(4 * n + 3 downto 4 * n),
				o_seg   => o_hex(7 * n + 6 downto 7 * n)
			);
	end generate gen_digits;

end architecture rtl;
