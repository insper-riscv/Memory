-- =============================================================================
-- Banco de teste do controlador de SRAM com o modelo do chip
--
-- Liga o sram_ctrl ao sram_model pelos pinos, com o tristate do barramento de
-- dados que o topo da placa faz. O modelo recebe só o que o controlador dirige,
-- para flagrar uma contenção, e o controlador lê o fio resolvido, onde o chip e o
-- controlador se encontram. Os generics de tempo vão aos dois, então o teste muda
-- o chip e o relógio de uma vez. A violação do modelo derruba a simulação
-- (abort_on_violation) ou pulsa o_violation.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.chip_timing_pkg.all;

entity sram_ctrl_tb is
  generic (
    -- Período do clock, em ns.
    clk_period_ns      : positive := 20;
    -- Margem de pino, em ns.
    margin_ns          : natural  := 0;
    -- Tamanho do chip em bytes.
    size_bytes         : positive := 65536;
    -- Onde o chip começa dentro dos 64 MB da região, em KiB. Origem: o espaço de endereços da região da memória que o Memory enxerga (26 bits baixos), não o mapa do Core.
    base_kib           : natural  := 0;
    -- Acesso por endereço, em ns.
    t_aa_ns            : natural  := SRAM_T_AA_NS;
    -- Ciclo de leitura, em ns.
    t_rc_ns            : natural  := SRAM_T_RC_NS;
    -- Ciclo de escrita, em ns.
    t_wc_ns            : natural  := SRAM_T_WC_NS;
    -- CE# até o fim da escrita, em ns.
    t_sce_ns           : natural  := SRAM_T_SCE_NS;
    -- Endereço até o fim da escrita, em ns.
    t_aw_ns            : natural  := SRAM_T_AW_NS;
    -- Pulso de WE#, em ns.
    t_pwe_ns           : natural  := SRAM_T_PWE_NS;
    -- Dado antes da subida de WE#, em ns.
    t_sd_ns            : natural  := SRAM_T_SD_NS;
    -- Endereço depois da subida de WE#, em ns.
    t_ha_ns            : natural  := SRAM_T_HA_NS;
    -- Dado depois da subida de WE#, em ns.
    t_hd_ns            : natural  := SRAM_T_HD_NS;
    -- Uma violação aborta a simulação.
    abort_on_violation : boolean  := true
  );
  port (
    -- Clock do sistema.
    i_clk       : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst       : in  std_logic;
    -- Endereço de byte do acesso.
    i_addr      : in  std_logic_vector(31 downto 0);
    -- Dado de escrita.
    i_wdata     : in  std_logic_vector(31 downto 0);
    -- Habilita de bytes da escrita.
    i_byteena   : in  std_logic_vector(3 downto 0);
    -- Pedido de leitura.
    i_rden      : in  std_logic;
    -- Pedido de escrita.
    i_wren      : in  std_logic;
    -- O pipeline avançou.
    i_advance   : in  std_logic;
    -- Acesso concluído.
    o_ready     : out std_logic;
    -- Dado lido.
    o_rdata     : out std_logic_vector(31 downto 0);
    -- Acesso de linha.
    i_line      : in  std_logic;
    -- Palavras 1 a 3 do dado de escrita.
    i_wdata_x   : in  std_logic_vector(95 downto 0);
    -- Habilita de bytes das palavras 1 a 3.
    i_byteena_x : in  std_logic_vector(11 downto 0);
    -- Palavras 1 a 3 do dado lido.
    o_rdata_x   : out std_logic_vector(95 downto 0);
    -- Pulso de 1 ns a cada violação que o modelo viu.
    o_violation : out std_logic
  );
end entity sram_ctrl_tb;

architecture rtl of sram_ctrl_tb is

  -- Endereço do chip.
  signal sram_addr : std_logic_vector(19 downto 0);
  -- Dado que o controlador quer dirigir.
  signal ctrl_dq   : std_logic_vector(15 downto 0);
  -- O controlador dirige o barramento.
  signal ctrl_oe   : std_logic;
  -- Dado que o controlador dirige no fio, 'Z' quando solto.
  signal ctrl_drv  : std_logic_vector(15 downto 0);
  -- Dado que o chip dirige no fio.
  signal chip_dq   : std_logic_vector(15 downto 0);
  -- O fio do barramento de dados, resolvido.
  signal dq_bus    : std_logic_vector(15 downto 0);
  -- Pinos de controle.
  signal ce_n, oe_n, we_n, lb_n, ub_n : std_logic;

begin

  ctrl_drv <= ctrl_dq when ctrl_oe = '1' else (others => 'Z');
  dq_bus   <= ctrl_drv;
  dq_bus   <= chip_dq;

  u_ctrl : entity work.sram_ctrl
    generic map (
      clk_period_ns => clk_period_ns, margin_ns => margin_ns, size_bytes => size_bytes, base_kib => base_kib,
      t_aa_ns => t_aa_ns, t_rc_ns => t_rc_ns, t_wc_ns => t_wc_ns, t_sce_ns => t_sce_ns, t_aw_ns => t_aw_ns,
      t_pwe_ns => t_pwe_ns, t_sd_ns => t_sd_ns, t_ha_ns => t_ha_ns, t_hd_ns => t_hd_ns
    )
    port map (
      i_clk => i_clk, i_rst => i_rst, i_addr => i_addr, i_wdata => i_wdata, i_byteena => i_byteena,
      i_rden => i_rden, i_wren => i_wren, i_advance => i_advance, o_ready => o_ready, o_rdata => o_rdata,
      i_line => i_line, i_wdata_x => i_wdata_x, i_byteena_x => i_byteena_x, o_rdata_x => o_rdata_x,
      o_sram_addr => sram_addr, o_sram_dq => ctrl_dq, o_sram_dq_oe => ctrl_oe, i_sram_dq => dq_bus,
      o_sram_ce_n => ce_n, o_sram_oe_n => oe_n, o_sram_we_n => we_n, o_sram_lb_n => lb_n, o_sram_ub_n => ub_n
    );

  u_chip : entity work.sram_model
    generic map (
      size_bytes => size_bytes, t_aa_ns => t_aa_ns, t_rc_ns => t_rc_ns, t_wc_ns => t_wc_ns, t_sce_ns => t_sce_ns,
      t_aw_ns => t_aw_ns, t_pwe_ns => t_pwe_ns, t_sd_ns => t_sd_ns, t_ha_ns => t_ha_ns, t_hd_ns => t_hd_ns,
      abort_on_violation => abort_on_violation
    )
    port map (
      i_sram_addr => sram_addr, i_sram_dq => ctrl_drv, o_sram_dq => chip_dq, i_sram_ce_n => ce_n,
      i_sram_oe_n => oe_n, i_sram_we_n => we_n, i_sram_lb_n => lb_n, i_sram_ub_n => ub_n, o_violation => o_violation
    );

end architecture rtl;
