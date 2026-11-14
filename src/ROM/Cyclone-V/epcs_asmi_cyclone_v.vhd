-- =============================================================================
-- Interface do epcs_ctrl com a flash serial de configuração da Cyclone V
--
-- Liga os quatro sinais SPI do epcs_ctrl aos pinos dedicados da configuração ativa
-- serial pelo bloco ASMI da Cyclone V, o mesmo que o IP altera_asmi_parallel e o
-- altserial_flash_loader da Altera instanciam: o FPGA só alcança esses pinos por ele.
-- Vale para a DE0-CV (5CEBA4) e a DE10-Nano (5CSEBA6), cuja flash de configuração é uma
-- EPCS64. A ligação é a do altserial_flash_loader da Quartus 25.1 para a Cyclone V em
-- modo de uma linha: DATA0 leva o dado ao chip (ASDO), DATA1 traz o dado do chip, DATA2 e
-- DATA3 ficam em '1' (as linhas de proteção de escrita e de espera do chip) e o bloco fica
-- sempre habilitado (oe em '0').
--
-- O bloco só existe nessa família, e o Quartus o instancia por component (não tem
-- entidade visível ao VHDL). Não há lógica aqui. Não confirmado em placa.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity epcs_asmi_cyclone_v is
    port (
        -- SPI: clock, vai ao pino DCLK.
        i_sck  : in    std_logic;
        -- SPI: seleção do chip, ativa em '0', vai ao pino nCSO.
        i_cs_n : in    std_logic;
        -- SPI: dado para o chip, vai ao pino DATA0 (ASDO).
        i_mosi : in    std_logic;
        -- SPI: dado do chip, vem do pino DATA1.
        o_miso : out   std_logic
    );
end entity epcs_asmi_cyclone_v;

architecture rtl of epcs_asmi_cyclone_v is

    -- Bloco ASMI da Cyclone V (primitiva do Quartus, sem entidade visível).
    component cyclonev_asmiblock is
        port (
            dclk     : in  std_logic;
            sce      : in  std_logic;
            oe       : in  std_logic;
            data0out : in  std_logic;
            data1out : in  std_logic;
            data2out : in  std_logic;
            data3out : in  std_logic;
            data0oe  : in  std_logic;
            data1oe  : in  std_logic;
            data2oe  : in  std_logic;
            data3oe  : in  std_logic;
            data0in  : out std_logic;
            data1in  : out std_logic;
            data2in  : out std_logic;
            data3in  : out std_logic
        );
    end component cyclonev_asmiblock;

begin

    u_asmi : component cyclonev_asmiblock
        port map (
            dclk     => i_sck,
            sce      => i_cs_n,
            oe       => '0',
            data0out => i_mosi,
            data1out => '0',
            data2out => '1',
            data3out => '1',
            data0oe  => '1',
            data1oe  => '0',
            data2oe  => '1',
            data3oe  => '1',
            data0in  => open,
            data1in  => o_miso,
            data2in  => open,
            data3in  => open
        );

end architecture rtl;
