-- =============================================================================
-- Árbitro de dois mestres para o chip de FLASH
--
-- O chip atende um pedido por vez. O mestre A (cache de instruções) e o mestre B
-- (cache de dados) pedem leitura com o contrato do chip: o pedido fica no
-- barramento até ready, ready é um nível até advance. Com o chip livre e os dois
-- pedindo, ganha o mestre que não foi atendido por último (A na primeira vez). A
-- concessão é registrada e fica com o mestre escolhido até o advance dele, então
-- um pedido em andamento nunca é interrompido; no clock seguinte ao advance o
-- árbitro escolhe de novo. Nenhum mestre espera mais que um pedido do outro.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity flash_arbiter is
  port (
    -- Clock do módulo.
    i_clk        : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst        : in  std_logic;

    -- Mestre A: endereço do pedido.
    i_a_addr     : in  std_logic_vector(31 downto 0);
    -- Mestre A: pedido de leitura ('1').
    i_a_rden     : in  std_logic;
    -- Mestre A: pedido de linha de quatro palavras ('1').
    i_a_line     : in  std_logic;
    -- Mestre A: o pedido foi consumido neste ciclo.
    i_a_advance  : in  std_logic;
    -- Mestre A: pedido concluído.
    o_a_ready    : out std_logic;
    -- Mestre A: palavra lida.
    o_a_rdata    : out std_logic_vector(31 downto 0);
    -- Mestre A: palavras 1 a 3 da linha lida.
    o_a_rdata_x  : out std_logic_vector(95 downto 0);

    -- Mestre B: endereço do pedido.
    i_b_addr     : in  std_logic_vector(31 downto 0);
    -- Mestre B: pedido de leitura ('1').
    i_b_rden     : in  std_logic;
    -- Mestre B: pedido de linha de quatro palavras ('1').
    i_b_line     : in  std_logic;
    -- Mestre B: o pedido foi consumido neste ciclo.
    i_b_advance  : in  std_logic;
    -- Mestre B: pedido concluído.
    o_b_ready    : out std_logic;
    -- Mestre B: palavra lida.
    o_b_rdata    : out std_logic_vector(31 downto 0);
    -- Mestre B: palavras 1 a 3 da linha lida.
    o_b_rdata_x  : out std_logic_vector(95 downto 0);

    -- Chip: endereço do pedido.
    o_addr       : out std_logic_vector(31 downto 0);
    -- Chip: pedido de leitura.
    o_rden       : out std_logic;
    -- Chip: pedido de linha.
    o_line       : out std_logic;
    -- Chip: o pedido foi consumido.
    o_advance    : out std_logic;
    -- Chip: pedido concluído.
    i_ready      : in  std_logic;
    -- Chip: palavra lida.
    i_rdata      : in  std_logic_vector(31 downto 0);
    -- Chip: palavras 1 a 3 da linha lida.
    i_rdata_x    : in  std_logic_vector(95 downto 0)
  );
end entity flash_arbiter;

architecture rtl of flash_arbiter is

  -- Dono atual do chip: nenhum, A ou B.
  type owner_t is (O_NONE, O_A, O_B);
  signal owner : owner_t := O_NONE;
  -- O último mestre atendido foi o A ('1') ou o B ('0').
  signal last_a : std_logic := '0';

begin

  o_addr    <= i_a_addr    when owner = O_A else i_b_addr;
  o_line    <= i_a_line    when owner = O_A else i_b_line;
  o_rden    <= i_a_rden    when owner = O_A else
               i_b_rden    when owner = O_B else '0';
  o_advance <= i_a_advance when owner = O_A else
               i_b_advance when owner = O_B else '0';

  o_a_ready   <= i_ready when owner = O_A else '0';
  o_b_ready   <= i_ready when owner = O_B else '0';
  o_a_rdata   <= i_rdata;
  o_b_rdata   <= i_rdata;
  o_a_rdata_x <= i_rdata_x;
  o_b_rdata_x <= i_rdata_x;

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        owner  <= O_NONE;
        last_a <= '0';
      else
        case owner is
          when O_NONE =>
            if i_a_rden = '1' and (i_b_rden = '0' or last_a = '0') then
              owner <= O_A;
            elsif i_b_rden = '1' then
              owner <= O_B;
            end if;
          when O_A =>
            last_a <= '1';
            if i_a_advance = '1' and i_ready = '1' then
              owner <= O_NONE;
            end if;
          when O_B =>
            last_a <= '0';
            if i_b_advance = '1' and i_ready = '1' then
              owner <= O_NONE;
            end if;
        end case;
      end if;
    end if;
  end process;

end architecture rtl;
