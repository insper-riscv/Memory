-- =============================================================================
-- Banco de teste do controlador de FLASH NOR com o modelo do chip
--
-- Liga o nor_flash_ctrl ao nor_flash_model pelos pinos, com o tristate do
-- barramento de dados que o topo da placa faz: o controlador e o modelo dirigem o
-- mesmo fio, e quem não dirige solta em 'Z'. Os generics de tempo vão aos dois,
-- então o teste muda o chip e o relógio de uma vez. A violação do modelo derruba a
-- simulação (abort_on_violation) ou pulsa o_violation.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.utils_pkg.all;
use work.chip_timing_pkg.all;

entity nor_flash_ctrl_tb is
  generic (
    -- Período do clock, em ns.
    clk_period_ns      : positive := 20;
    -- Margem de pino, em ns.
    margin_ns          : natural  := 0;
    -- Tamanho do chip em bytes.
    size_bytes         : positive := 65536;
    -- Tamanho do setor em bytes.
    sector_bytes       : positive := 4096;
    -- Tamanho da página em bytes.
    page_bytes         : positive := 64;
    -- Endereço do chip no mapa do SoC.
    base_addr          : std_logic_vector(31 downto 0) := x"20000000";
    -- Acesso aleatório, em ns.
    t_acc_ns           : natural  := NOR_T_ACC_NS;
    -- Acesso de página, em ns.
    t_pacc_ns          : natural  := NOR_T_PACC_NS;
    -- Ciclo de escrita, em ns.
    t_wc_ns            : natural  := NOR_T_WC_NS;
    -- Pulso de WE#, em ns.
    t_wp_ns            : natural  := NOR_T_WP_NS;
    -- WE# alto, em ns.
    t_wph_ns           : natural  := NOR_T_WPH_NS;
    -- Dado antes da subida de WE#, em ns.
    t_ds_ns            : natural  := NOR_T_DS_NS;
    -- Endereço depois da descida de WE#, em ns.
    t_ah_ns            : natural  := NOR_T_AH_NS;
    -- Da subida de WE# à descida de RY#, em ns.
    t_busy_ns          : natural  := NOR_T_BUSY_NS;
    -- Pulso de RESET#, em ns.
    t_rp_ns            : natural  := NOR_T_RP_NS;
    -- Espera depois de RESET#, em ns.
    t_rh_ns            : natural  := NOR_T_RH_NS;
    -- Duração da gravação de um byte no modelo, em ns.
    t_prog_ns          : natural  := 2000;
    -- Duração do apagar de um setor no modelo, em ns.
    t_erase_ns         : natural  := 20000;
    -- Conteúdo inicial do chip todo em 0xFF.
    erased_init        : boolean  := false;
    -- Uma violação aborta a simulação.
    abort_on_violation : boolean  := true
  );
  port (
    -- Clock do sistema.
    i_clk         : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst         : in  std_logic;

    -- Leitura: endereço do pedido.
    i_addr        : in  std_logic_vector(31 downto 0);
    -- Leitura: pedido de leitura.
    i_rden        : in  std_logic;
    -- Leitura: pedido de linha.
    i_line        : in  std_logic;
    -- Leitura: o pedido foi consumido.
    i_advance     : in  std_logic;
    -- Leitura: pedido concluído.
    o_ready       : out std_logic;
    -- Leitura: o controlador espera o chip.
    o_busy        : out std_logic;
    -- Leitura: palavra pedida.
    o_rdata       : out std_logic_vector(31 downto 0);
    -- Leitura: palavras 1 a 3 da linha.
    o_rdata_x     : out std_logic_vector(95 downto 0);

    -- Comandos: pulso que entrega um comando.
    i_cmd_valid   : in  std_logic;
    -- Comandos: código do comando.
    i_cmd_op      : in  std_logic_vector(2 downto 0);
    -- Comandos: endereço de byte do comando.
    i_cmd_addr    : in  std_logic_vector(31 downto 0);
    -- Comandos: o controlador não aceita comando.
    o_cmd_busy    : out std_logic;
    -- Comandos: o latch de escrita está armado.
    o_wel         : out std_logic;
    -- Comandos: o último apagar ou gravar foi recusado.
    o_refused     : out std_logic;

    -- Buffer de página: escrita de uma palavra.
    i_buf_we      : in  std_logic;
    -- Buffer de página: índice da palavra escrita.
    i_buf_widx    : in  std_logic_vector(log2_exact(page_bytes) - 3 downto 0);
    -- Buffer de página: palavra escrita.
    i_buf_wdata   : in  std_logic_vector(31 downto 0);

    -- Pulso de invalidação no fim de um apagar ou gravar.
    o_inval_valid : out std_logic;
    -- Primeiro endereço de byte da região alterada.
    o_inval_first : out std_logic_vector(31 downto 0);
    -- Último endereço de byte da região alterada.
    o_inval_last  : out std_logic_vector(31 downto 0);

    -- Pulso de 1 ns a cada violação de tempo ou de uso que o modelo viu.
    o_violation   : out std_logic
  );
end entity nor_flash_ctrl_tb;

architecture rtl of nor_flash_ctrl_tb is

  -- Palavras de uma página.
  constant PAGE_WORDS : natural := page_bytes / 4;
  -- Tipo do buffer de página.
  type buf_t is array (0 to PAGE_WORDS - 1) of std_logic_vector(31 downto 0);
  -- Buffer de página de leitura registrada, que faz o papel do buffer do controlador de FLASH.
  signal buf          : buf_t := (others => (others => '1'));
  -- Índice lido do buffer.
  signal buf_idx      : std_logic_vector(log2_exact(page_bytes) - 3 downto 0);
  -- Palavra lida do buffer (registrada).
  signal buf_data     : std_logic_vector(31 downto 0) := (others => '0');

  -- Endereço do chip.
  signal fl_addr      : std_logic_vector(22 downto 0);
  -- Dado que o controlador dirige.
  signal ctrl_dq      : std_logic_vector(7 downto 0);
  -- O controlador dirige o barramento.
  signal ctrl_dq_oe   : std_logic;
  -- Dado que o chip dirige.
  signal chip_dq      : std_logic_vector(7 downto 0);
  -- O fio do barramento de dados, resolvido.
  signal fl_dq        : std_logic_vector(7 downto 0);
  -- Pinos de controle.
  signal ce_n, oe_n, we_n, rst_n, wp_n, ry : std_logic;

begin

  -- Tristate do barramento: o controlador dirige quando pede, e o chip dirige pela própria saída.
  fl_dq <= ctrl_dq when ctrl_dq_oe = '1' else (others => 'Z');
  fl_dq <= chip_dq;

  -- Buffer de página.
  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_buf_we = '1' then
        buf(to_integer(unsigned(i_buf_widx))) <= i_buf_wdata;
      end if;
      buf_data <= buf(to_integer(unsigned(buf_idx)));
    end if;
  end process;

  u_ctrl : entity work.nor_flash_ctrl
    generic map (
      clk_period_ns => clk_period_ns, margin_ns => margin_ns, size_bytes => size_bytes,
      sector_bytes => sector_bytes, page_bytes => page_bytes, base_addr => base_addr,
      t_acc_ns => t_acc_ns, t_pacc_ns => t_pacc_ns, t_wc_ns => t_wc_ns, t_wp_ns => t_wp_ns,
      t_wph_ns => t_wph_ns, t_ds_ns => t_ds_ns, t_ah_ns => t_ah_ns, t_busy_ns => t_busy_ns,
      t_rp_ns => t_rp_ns, t_rh_ns => t_rh_ns
    )
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_addr => i_addr, i_rden => i_rden, i_line => i_line, i_advance => i_advance,
      o_ready => o_ready, o_busy => o_busy, o_rdata => o_rdata, o_rdata_x => o_rdata_x,
      i_cmd_valid => i_cmd_valid, i_cmd_op => i_cmd_op, i_cmd_addr => i_cmd_addr,
      o_cmd_busy => o_cmd_busy, o_wel => o_wel, o_refused => o_refused,
      o_buf_idx => buf_idx, i_buf_data => buf_data,
      o_inval_valid => o_inval_valid, o_inval_first => o_inval_first, o_inval_last => o_inval_last,
      o_fl_addr => fl_addr, o_fl_dq => ctrl_dq, o_fl_dq_oe => ctrl_dq_oe, i_fl_dq => fl_dq,
      o_fl_ce_n => ce_n, o_fl_oe_n => oe_n, o_fl_we_n => we_n, o_fl_rst_n => rst_n,
      o_fl_wp_n => wp_n, i_fl_ry => ry
    );

  u_chip : entity work.nor_flash_model
    generic map (
      size_bytes => size_bytes, sector_bytes => sector_bytes,
      t_acc_ns => t_acc_ns, t_pacc_ns => t_pacc_ns, t_wc_ns => t_wc_ns, t_wp_ns => t_wp_ns,
      t_wph_ns => t_wph_ns, t_ds_ns => t_ds_ns, t_ah_ns => t_ah_ns, t_busy_ns => t_busy_ns,
      t_rp_ns => t_rp_ns, t_rh_ns => t_rh_ns, t_prog_ns => t_prog_ns, t_erase_ns => t_erase_ns,
      erased_init => erased_init, abort_on_violation => abort_on_violation
    )
    port map (
      i_fl_addr => fl_addr, i_fl_dq => fl_dq, o_fl_dq => chip_dq,
      i_fl_ce_n => ce_n, i_fl_oe_n => oe_n, i_fl_we_n => we_n, i_fl_rst_n => rst_n,
      i_fl_wp_n => wp_n, o_fl_ry => ry, o_violation => o_violation
    );

end architecture rtl;
