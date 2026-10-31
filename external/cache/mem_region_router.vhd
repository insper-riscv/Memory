-- =============================================================================
-- Roteador de região dos pedidos de uma cache
--
-- Leva o pedido de um mestre (o lado da memória de uma cache) para a SDRAM ou para
-- a FLASH conforme o bit 29 do endereço (1 = FLASH), e devolve o ready e o dado da
-- região escolhida. O contrato é o da ponte da SDRAM: o pedido fica no barramento
-- até ready, ready é um nível que só cai com advance, e o dado lido só muda no
-- pedido seguinte. A escolha é combinacional sobre o endereço, que o mestre
-- mantém estável durante o pedido.
--
-- Dois pedidos à FLASH não chegam ao chip. Um store (i_wren) é concluído aqui, sem
-- efeito, como num chip protegido contra escrita; e uma leitura fora da janela de 1 MB
-- (bits 25:20 do endereço diferentes de zero) devolve zero. Nos dois casos ready
-- sobe um clock depois do pedido e fica em nível até advance. O mestre baixa o
-- pedido na borda em que vê ready, como as caches fazem.
--
-- Para uma cache só de leitura, i_wren fica em '0' e o caso do store não ocorre.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mem_region_router is
  port (
    -- Clock do módulo.
    i_clk        : in  std_logic;
    -- Reset, ativo em '1'.
    i_rst        : in  std_logic;

    -- Mestre: endereço do pedido.
    i_addr       : in  std_logic_vector(31 downto 0);
    -- Mestre: dado de escrita (palavra 0).
    i_wdata      : in  std_logic_vector(31 downto 0);
    -- Mestre: habilita de bytes da escrita.
    i_byteena    : in  std_logic_vector(3 downto 0);
    -- Mestre: pedido de leitura ('1').
    i_rden       : in  std_logic;
    -- Mestre: pedido de escrita ('1').
    i_wren       : in  std_logic;
    -- Mestre: pedido de linha de quatro palavras ('1').
    i_line       : in  std_logic;
    -- Mestre: palavras 1 a 3 do dado de escrita da linha.
    i_wdata_x    : in  std_logic_vector(95 downto 0) := (others => '0');
    -- Mestre: o pedido foi consumido neste ciclo.
    i_advance    : in  std_logic;
    -- Mestre: pedido concluído, o dado lido é válido ('1').
    o_ready      : out std_logic;
    -- Mestre: palavra lida (a palavra 0 da linha).
    o_rdata      : out std_logic_vector(31 downto 0);
    -- Mestre: palavras 1 a 3 da linha lida.
    o_rdata_x    : out std_logic_vector(95 downto 0);

    -- SDRAM: endereço do pedido.
    o_s_addr     : out std_logic_vector(31 downto 0);
    -- SDRAM: dado de escrita (palavra 0).
    o_s_wdata    : out std_logic_vector(31 downto 0);
    -- SDRAM: habilita de bytes da escrita.
    o_s_byteena  : out std_logic_vector(3 downto 0);
    -- SDRAM: pedido de leitura ('1' só para endereços da SDRAM).
    o_s_rden     : out std_logic;
    -- SDRAM: pedido de escrita ('1' só para endereços da SDRAM).
    o_s_wren     : out std_logic;
    -- SDRAM: pedido de linha.
    o_s_line     : out std_logic;
    -- SDRAM: palavras 1 a 3 do dado de escrita da linha.
    o_s_wdata_x  : out std_logic_vector(95 downto 0);
    -- SDRAM: o pedido foi consumido (só para endereços da SDRAM).
    o_s_advance  : out std_logic;
    -- SDRAM: pedido concluído.
    i_s_ready    : in  std_logic;
    -- SDRAM: palavra lida.
    i_s_rdata    : in  std_logic_vector(31 downto 0);
    -- SDRAM: palavras 1 a 3 da linha lida.
    i_s_rdata_x  : in  std_logic_vector(95 downto 0) := (others => '0');

    -- FLASH: endereço do pedido.
    o_f_addr     : out std_logic_vector(31 downto 0);
    -- FLASH: pedido de leitura ('1' só para leituras da FLASH dentro da janela).
    o_f_rden     : out std_logic;
    -- FLASH: pedido de linha.
    o_f_line     : out std_logic;
    -- FLASH: o pedido foi consumido (só para endereços da FLASH).
    o_f_advance  : out std_logic;
    -- FLASH: pedido concluído.
    i_f_ready    : in  std_logic;
    -- FLASH: palavra lida.
    i_f_rdata    : in  std_logic_vector(31 downto 0);
    -- FLASH: palavras 1 a 3 da linha lida.
    i_f_rdata_x  : in  std_logic_vector(95 downto 0) := (others => '0')
  );
end entity mem_region_router;

architecture rtl of mem_region_router is

  -- O pedido é da FLASH.
  signal is_flash : std_logic;
  -- O pedido da FLASH é concluído aqui (store ou leitura fora da janela).
  signal is_local : std_logic;
  -- O pedido local já foi visto, ready sobe e fica até advance.
  signal local_ready : std_logic := '0';

begin

  is_flash <= i_addr(29);
  is_local <= is_flash and (i_wren or (i_rden and (i_addr(25) or i_addr(24) or i_addr(23)
                                                    or i_addr(22) or i_addr(21) or i_addr(20))));

  o_s_addr    <= i_addr;
  o_s_wdata   <= i_wdata;
  o_s_byteena <= i_byteena;
  o_s_rden    <= i_rden and not is_flash;
  o_s_wren    <= i_wren and not is_flash;
  o_s_line    <= i_line;
  o_s_wdata_x <= i_wdata_x;
  o_s_advance <= i_advance and not is_flash;

  o_f_addr    <= i_addr;
  o_f_rden    <= i_rden and is_flash and not is_local;
  o_f_line    <= i_line;
  o_f_advance <= i_advance and is_flash and not is_local;

  o_ready <= local_ready when is_local = '1' else
             i_f_ready   when is_flash = '1' else
             i_s_ready;
  o_rdata <= (others => '0') when is_local = '1' else
             i_f_rdata       when is_flash = '1' else
             i_s_rdata;
  o_rdata_x <= (others => '0') when is_local = '1' else
               i_f_rdata_x     when is_flash = '1' else
               i_s_rdata_x;

  process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        local_ready <= '0';
      elsif local_ready = '1' then
        if i_advance = '1' then
          local_ready <= '0';
        end if;
      elsif is_local = '1' then
        local_ready <= '1';
      end if;
    end if;
  end process;

end architecture rtl;
