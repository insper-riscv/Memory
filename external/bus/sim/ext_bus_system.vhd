-- =============================================================================
-- Topo de simulação do interconector com a UART sobre JTAG
--
-- O interconector com a jtag_uart no slot de periférico 4. A porta do core e o
-- lado da memória (m_*) ficam expostos para que o testbench faça o papel do core
-- e da memória; jtag_* representam uma instância do Virtual JTAG (veja
-- jtag_uart).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity ext_bus_system is
  port (
    -- Clock do módulo.
    i_clk         : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst         : in  std_logic;

    -- Endereço do acesso.
    i_addr        : in  std_logic_vector(31 downto 0);
    -- Dado de escrita.
    i_wdata       : in  std_logic_vector(31 downto 0);
    -- Habilita de bytes da escrita, um bit por byte.
    i_byteena     : in  std_logic_vector(3 downto 0);
    -- Pedido de leitura ('1' = lê).
    i_rden        : in  std_logic;
    -- Pedido de escrita ('1' = escreve).
    i_wren        : in  std_logic;
    -- O pipeline avançou neste ciclo, o acesso em andamento pode ser concluído.
    i_mem_advance : in  std_logic;
    -- Acesso concluído, o dado lido é válido ('1').
    o_ready       : out std_logic;
    -- Dado lido.
    o_rdata       : out std_logic_vector(31 downto 0);

    -- Lado da memória com ready próprio: endereço do acesso.
    o_m_addr      : out std_logic_vector(31 downto 0);
    -- Lado da memória com ready próprio: dado de escrita.
    o_m_wdata     : out std_logic_vector(31 downto 0);
    -- Lado da memória com ready próprio: habilita de bytes da escrita.
    o_m_byteena   : out std_logic_vector(3 downto 0);
    -- Lado da memória com ready próprio: pedido de leitura, retido enquanto outro escravo está selecionado.
    o_m_rden      : out std_logic;
    -- Lado da memória com ready próprio: pedido de escrita, retido enquanto outro escravo está selecionado.
    o_m_wren      : out std_logic;
    -- Lado da memória com ready próprio: acesso concluído ('1').
    i_m_ready     : in  std_logic;
    -- Lado da memória com ready próprio: dado lido.
    i_m_rdata     : in  std_logic_vector(31 downto 0);

    -- Clock da cadeia JTAG.
    i_jtag_tck        : in  std_logic := '0';
    -- Dado serial vindo do hospedeiro.
    i_jtag_tdi        : in  std_logic := '0';
    -- Dado serial para o hospedeiro.
    o_jtag_tdo        : out std_logic;
    -- Registrador de instrução do Virtual JTAG.
    i_jtag_ir_in      : in  std_logic_vector(1 downto 0) := "00";
    -- Estado Capture-DR da cadeia virtual.
    i_jtag_state_cdr  : in  std_logic := '0';
    -- Estado Shift-DR da cadeia virtual.
    i_jtag_state_sdr  : in  std_logic := '0';
    -- Estado Update-DR da cadeia virtual.
    i_jtag_state_udr  : in  std_logic := '0';
    -- Estado Update-IR da cadeia virtual.
    i_jtag_state_uir  : in  std_logic := '0'
  );
end entity ext_bus_system;

architecture rtl of ext_bus_system is
  -- Deslocamento de palavra dentro do periférico.
  signal p_addr   : std_logic_vector(7 downto 0);
  -- Dado de escrita aos periféricos.
  signal p_wdata  : std_logic_vector(31 downto 0);
  -- Habilita de bytes da escrita aos periféricos.
  signal p_byteena : std_logic_vector(3 downto 0);
  -- Pulso de escrita, um bit por periférico.
  signal p_we : std_logic_vector(7 downto 0);
  -- Pulso de leitura, um bit por periférico.
  signal p_re : std_logic_vector(7 downto 0);
  -- Dados lidos dos periféricos, 32 bits por slot.
  signal p_rdata  : std_logic_vector(8 * 32 - 1 downto 0) := (others => '0');
begin

  u_ic : entity work.ext_interconnect
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_addr => i_addr, i_wdata => i_wdata, i_byteena => i_byteena, i_rden => i_rden, i_wren => i_wren,
      i_mem_advance => i_mem_advance, o_ready => o_ready, o_rdata => o_rdata,
      o_m_addr => o_m_addr, o_m_wdata => o_m_wdata, o_m_byteena => o_m_byteena, o_m_rden => o_m_rden,
      o_m_wren => o_m_wren, i_m_ready => i_m_ready, i_m_rdata => i_m_rdata,
      o_p_addr => p_addr, o_p_wdata => p_wdata, o_p_byteena => p_byteena, o_p_we => p_we, o_p_re => p_re,
      i_p_rdata => p_rdata
    );

  u_uart : entity work.jtag_uart
    port map (
      i_clk => i_clk, i_rst => i_rst, i_addr => p_addr, i_wdata => p_wdata, i_we => p_we(4), i_re => p_re(4),
      o_rdata => p_rdata(32 * 4 + 31 downto 32 * 4),
      i_tck => i_jtag_tck, i_tdi => i_jtag_tdi, o_tdo => o_jtag_tdo, i_ir_in => i_jtag_ir_in,
      i_state_cdr => i_jtag_state_cdr, i_state_sdr => i_jtag_state_sdr,
      i_state_udr => i_jtag_state_udr, i_state_uir => i_jtag_state_uir
    );

end architecture rtl;
