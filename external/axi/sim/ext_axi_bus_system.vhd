-- =============================================================================
-- Topo de simulação do barramento externo AXI4
--
-- A contrapartida do ext_bus_system: a porta do core sobre o
-- ext_axi_interconnect, a UART sobre JTAG no slot de periférico 4 e, atrás da
-- porta escravo da SDRAM, uma memória de palavras pequena (4096 palavras, dois
-- clocks para responder) com o valor 0x12345678 em 0x40000100. jtag_*
-- representam uma instância do Virtual JTAG (veja jtag_uart).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ext_axi_bus_system is
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

    -- Pede a escrita de todas as linhas sujas na memória ('1').
    i_flush       : in  std_logic := '0';
    -- A escrita das linhas sujas terminou ('1').
    o_flush_done  : out std_logic;
    -- O módulo está ocupado ('1').
    o_busy        : out std_logic;

    -- Endereço de palavra lido diretamente do modelo do chip, para depuração.
    i_dbg_word_addr : in  std_logic_vector(11 downto 0) := (others => '0');
    -- Palavra do modelo do chip no endereço de dbg_word_addr.
    o_dbg_word_data : out std_logic_vector(31 downto 0);

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
end entity ext_axi_bus_system;

architecture rtl of ext_axi_bus_system is
  -- Barramento AXI4, canal de endereço de escrita: validade da transferência ('1' = válida).
  signal awvalid : std_logic;
  -- Barramento AXI4, canal de endereço de escrita: destino pronto para aceitar a transferência ('1').
  signal awready : std_logic;
  -- Barramento AXI4, canal de dados de escrita: validade da transferência ('1' = válida).
  signal wvalid : std_logic;
  -- Barramento AXI4, canal de dados de escrita: destino pronto para aceitar a transferência ('1').
  signal wready : std_logic;
  -- Barramento AXI4, canal de resposta de escrita: validade da transferência ('1' = válida).
  signal bvalid : std_logic;
  -- Barramento AXI4, canal de resposta de escrita: destino pronto para aceitar a transferência ('1').
  signal bready : std_logic;
  -- Barramento AXI4, canal de endereço de leitura: validade da transferência ('1' = válida).
  signal arvalid : std_logic;
  -- Barramento AXI4, canal de endereço de leitura: destino pronto para aceitar a transferência ('1').
  signal arready : std_logic;
  -- Barramento AXI4, canal de dados de leitura: validade da transferência ('1' = válida).
  signal rvalid : std_logic;
  -- Barramento AXI4, canal de dados de leitura: destino pronto para aceitar a transferência ('1').
  signal rready : std_logic;
  -- Barramento AXI4, canal de dados de escrita: último beat da rajada ('1').
  signal wlast : std_logic;
  -- Barramento AXI4, canal de dados de leitura: último beat da rajada ('1').
  signal rlast : std_logic;
  -- Barramento AXI4, canal de endereço de escrita: endereço do primeiro beat.
  signal awaddr : std_logic_vector(31 downto 0);
  -- Barramento AXI4, canal de dados de escrita: dados.
  signal wdata_a : std_logic_vector(31 downto 0);
  -- Barramento AXI4, canal de endereço de leitura: endereço do primeiro beat.
  signal araddr : std_logic_vector(31 downto 0);
  -- Barramento AXI4, canal de dados de leitura: dados.
  signal rdata_a : std_logic_vector(31 downto 0);
  -- Barramento AXI4, canal de endereço de escrita: número de beats da rajada menos um.
  signal awlen : std_logic_vector(7 downto 0);
  -- Barramento AXI4, canal de endereço de leitura: número de beats da rajada menos um.
  signal arlen : std_logic_vector(7 downto 0);
  -- Barramento AXI4, canal de endereço de escrita: log2 do número de bytes por beat.
  signal awsize : std_logic_vector(2 downto 0);
  -- Barramento AXI4, canal de endereço de leitura: log2 do número de bytes por beat.
  signal arsize : std_logic_vector(2 downto 0);
  -- Barramento AXI4, canal de endereço de escrita: tipo de rajada (1 = INCR).
  signal awburst : std_logic_vector(1 downto 0);
  -- Barramento AXI4, canal de endereço de leitura: tipo de rajada (1 = INCR).
  signal arburst : std_logic_vector(1 downto 0);
  -- Barramento AXI4, canal de dados de escrita: habilita de bytes.
  signal wstrb : std_logic_vector(3 downto 0);
  -- Barramento AXI4, canal de resposta de escrita: resposta (0 = OKAY, 2 = SLVERR).
  signal bresp : std_logic_vector(1 downto 0);
  -- Barramento AXI4, canal de dados de leitura: resposta (0 = OKAY, 2 = SLVERR).
  signal rresp : std_logic_vector(1 downto 0);

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

  -- Lado da palavra da ponte escrava AXI4: endereço.
  signal m_addr : std_logic_vector(31 downto 0) := (others => '0');
  -- Lado da palavra da ponte escrava AXI4: dado de escrita.
  signal m_wdata : std_logic_vector(31 downto 0) := (others => '0');
  -- Lado da palavra da ponte escrava AXI4: dado lido.
  signal m_rdata : std_logic_vector(31 downto 0) := (others => '0');
  -- Lado da palavra da ponte escrava AXI4: habilita de bytes.
  signal m_be : std_logic_vector(3 downto 0);
  -- Lado da palavra da ponte escrava AXI4: pedido de leitura.
  signal m_rden : std_logic;
  -- Lado da palavra da ponte escrava AXI4: pedido de escrita.
  signal m_wren : std_logic;
  -- Lado da palavra da ponte escrava AXI4: avanço do acesso.
  signal m_adv : std_logic;
  -- Lado da palavra da ponte escrava AXI4: acesso concluído.
  signal m_ready : std_logic;
  -- Lado da palavra da ponte escrava AXI4: acesso de linha.
  signal m_line : std_logic;
  -- Lado da palavra da ponte escrava AXI4: palavras 1 a 3 da escrita de linha.
  signal m_wdx : std_logic_vector(95 downto 0) := (others => '0');
  -- Lado da palavra da ponte escrava AXI4: palavras 1 a 3 da leitura de linha.
  signal m_rdx : std_logic_vector(95 downto 0) := (others => '0');
  -- Lado da palavra da ponte escrava AXI4: habilita de bytes das palavras 1 a 3.
  signal m_bex : std_logic_vector(11 downto 0);

  -- Memória de 4096 palavras.
  type mem_t is array (0 to 4095) of std_logic_vector(31 downto 0);
  -- Conteúdo da memória atrás do escravo AXI4.
  signal mem : mem_t := (16#40# => x"12345678", others => (others => '0'));
  -- Clocks restantes para a memória responder.
  signal lat : natural range 0 to 3 := 0;
  -- Acesso concluído (registrado).
  signal ready_i : std_logic := '0';
begin

  u_ic : entity work.ext_axi_interconnect
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_addr => i_addr, i_wdata => i_wdata, i_byteena => i_byteena, i_rden => i_rden, i_wren => i_wren,
      i_mem_advance => i_mem_advance, o_ready => o_ready, o_rdata => o_rdata,
      i_flush => i_flush, o_flush_done => o_flush_done, o_busy => o_busy,
      o_m0_awvalid => awvalid, i_m0_awready => awready, o_m0_awaddr => awaddr, o_m0_awlen => awlen,
      o_m0_awsize => awsize, o_m0_awburst => awburst,
      o_m0_wvalid => wvalid, i_m0_wready => wready, o_m0_wdata => wdata_a, o_m0_wstrb => wstrb, o_m0_wlast => wlast,
      i_m0_bvalid => bvalid, o_m0_bready => bready, i_m0_bresp => bresp,
      o_m0_arvalid => arvalid, i_m0_arready => arready, o_m0_araddr => araddr, o_m0_arlen => arlen,
      o_m0_arsize => arsize, o_m0_arburst => arburst,
      i_m0_rvalid => rvalid, o_m0_rready => rready, i_m0_rdata => rdata_a, i_m0_rresp => rresp, i_m0_rlast => rlast,
      o_p_addr => p_addr, o_p_wdata => p_wdata, o_p_byteena => p_byteena, o_p_we => p_we, o_p_re => p_re,
      i_p_rdata => p_rdata
    );

  u_slave : entity work.axi_slave_word_bridge
    port map (
      i_clk => i_clk, i_rst => i_rst,
      i_s_awvalid => awvalid, o_s_awready => awready, i_s_awaddr => awaddr, i_s_awlen => awlen,
      i_s_awsize => awsize, i_s_awburst => awburst,
      i_s_wvalid => wvalid, o_s_wready => wready, i_s_wdata => wdata_a, i_s_wstrb => wstrb, i_s_wlast => wlast,
      o_s_bvalid => bvalid, i_s_bready => bready, o_s_bresp => bresp,
      i_s_arvalid => arvalid, o_s_arready => arready, i_s_araddr => araddr, i_s_arlen => arlen,
      i_s_arsize => arsize, i_s_arburst => arburst,
      o_s_rvalid => rvalid, i_s_rready => rready, o_s_rdata => rdata_a, o_s_rresp => rresp, o_s_rlast => rlast,
      o_addr => m_addr, o_wdata => m_wdata, o_byteena => m_be, o_rden => m_rden, o_wren => m_wren,
      o_mem_advance => m_adv, i_ready => m_ready, i_rdata => m_rdata,
      o_line => m_line, o_wdata_x => m_wdx, o_byteena_x => m_bex, i_rdata_x => m_rdx
    );

  -- a memória: ready dois clocks depois de o acesso começar, em nível até mem_advance; o dado
  -- lido muda na borda de mem_advance. Um acesso de linha move as quatro palavras da linha.
  m_ready <= ready_i;
  o_dbg_word_data <= mem(to_integer(unsigned(i_dbg_word_addr)));
  process (i_clk)
    -- Índice do laço de carga.
    variable i : integer;
  begin
    if rising_edge(i_clk) then
      i := to_integer(unsigned(m_addr(13 downto 2)));
      if i_rst = '1' then
        ready_i <= '0';
        lat     <= 0;
      elsif m_adv = '1' then
        ready_i <= '0';
        lat     <= 0;
        if m_rden = '1' then
          m_rdata <= mem(i);
          if m_line = '1' then
            m_rdx <= mem(i + 3) & mem(i + 2) & mem(i + 1);
          end if;
        end if;
      elsif (m_rden = '1' or m_wren = '1') and ready_i = '0' then
        if lat = 1 then
          ready_i <= '1';
          if m_wren = '1' then
            for b in 0 to 3 loop
              if m_be(b) = '1' then
                mem(i)(8 * b + 7 downto 8 * b) <= m_wdata(8 * b + 7 downto 8 * b);
              end if;
            end loop;
            if m_line = '1' then
              for w in 1 to 3 loop
                for b in 0 to 3 loop
                  if m_bex(4 * (w - 1) + b) = '1' then
                    mem(i + w)(8 * b + 7 downto 8 * b) <= m_wdx(32 * (w - 1) + 8 * b + 7 downto 32 * (w - 1) + 8 * b);
                  end if;
                end loop;
              end loop;
            end if;
          end if;
        else
          lat <= lat + 1;
        end if;
      end if;
    end if;
  end process;

  u_uart : entity work.jtag_uart
    port map (
      i_clk => i_clk, i_rst => i_rst, i_addr => p_addr, i_wdata => p_wdata, i_we => p_we(4), i_re => p_re(4),
      o_rdata => p_rdata(32 * 4 + 31 downto 32 * 4),
      i_tck => i_jtag_tck, i_tdi => i_jtag_tdi, o_tdo => o_jtag_tdo, i_ir_in => i_jtag_ir_in,
      i_state_cdr => i_jtag_state_cdr, i_state_sdr => i_jtag_state_sdr,
      i_state_udr => i_jtag_state_udr, i_state_uir => i_jtag_state_uir
    );

end architecture rtl;
