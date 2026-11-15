-- =============================================================================
-- Interface do epcs_ctrl com a flash serial de configuração da Cyclone IV E
--
-- Liga os quatro sinais SPI do epcs_ctrl aos pinos dedicados da configuração ativa
-- serial (DCLK, nCSO, ASDO e DATA0) pelo bloco ASMI da Cyclone IV E, o mesmo que o
-- IP altasmi_parallel e o altserial_flash_loader da Altera instanciam: o FPGA só
-- alcança esses pinos por ele. Vale para a DE0-Nano (EP4CE22) e a DE2-115 (EP4CE115),
-- cuja flash de configuração é uma EPCS64. A ligação é a do altserial_flash_loader da
-- Quartus 25.1 para a família Cyclone IV E: a seleção entra em nível baixo, o dado
-- do chip volta em data0out e o bloco fica sempre habilitado (oe em '0').
--
-- O bloco só existe nessa família, e o Quartus o instancia por component (não tem
-- entidade visível ao VHDL). Não há lógica aqui. Não confirmado em placa.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity epcs_asmi_cyclone_iv_e is
    port (
        -- SPI: clock, vai ao pino DCLK.
        i_sck  : in    std_logic;
        -- SPI: seleção do chip, ativa em '0', vai ao pino nCSO.
        i_cs_n : in    std_logic;
        -- SPI: dado para o chip, vai ao pino ASDO.
        i_mosi : in    std_logic;
        -- SPI: dado do chip, vem do pino DATA0.
        o_miso : out   std_logic
    );
end entity epcs_asmi_cyclone_iv_e;

architecture rtl of epcs_asmi_cyclone_iv_e is

    -- Bloco ASMI da Cyclone IV E (primitiva do Quartus, sem entidade visível).
    component cycloneii_asmiblock is
        port (
            dclkin   : in  std_logic;
            scein    : in  std_logic;
            sdoin    : in  std_logic;
            data0out : out std_logic;
            oe       : in  std_logic
        );
    end component cycloneii_asmiblock;

begin

    u_asmi : component cycloneii_asmiblock
        port map (
            dclkin   => i_sck,
            scein    => i_cs_n,
            sdoin    => i_mosi,
            data0out => o_miso,
            oe       => '0'
        );

end architecture rtl;
