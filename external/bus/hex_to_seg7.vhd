-- =============================================================================
-- Conversor de um dígito hexadecimal para sete segmentos
--
-- Converte um dígito de 4 bits para os sete segmentos de um display da DE0-CV.
-- Os segmentos da placa acendem em nível baixo; o vetor de saída segue a ordem
-- "gfedcba" (bit 0 é o segmento a, bit 6 é o segmento g).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity hex_to_seg7 is
	port (
		-- Dígito hexadecimal a mostrar.
		i_digit : in  std_logic_vector(3 downto 0);
		-- Segmentos g..a em nível baixo ('0' = aceso).
		o_seg   : out std_logic_vector(6 downto 0)
	);
end entity hex_to_seg7;

architecture rtl of hex_to_seg7 is
begin

	with i_digit select o_seg <=
		"1000000" when "0000",
		"1111001" when "0001",
		"0100100" when "0010",
		"0110000" when "0011",
		"0011001" when "0100",
		"0010010" when "0101",
		"0000010" when "0110",
		"1111000" when "0111",
		"0000000" when "1000",
		"0010000" when "1001",
		"0001000" when "1010",
		"0000011" when "1011",
		"1000110" when "1100",
		"0100001" when "1101",
		"0000110" when "1110",
		"0001110" when others;

end architecture rtl;
