-- =============================================================================
-- Porta JTAG da depuração da SDRAM
--
-- Lógica atrás de uma instância do Virtual JTAG (sld_virtual_jtag no topo da
-- placa, conduzida pelo testbench em simulação), no clock JTAG tck, e a entrega
-- dos comandos ao sdram_dbg_master, que roda em outro clock.
--
-- O Virtual JTAG tem um registrador de instrução (aqui de 2 bits) e um
-- registrador de dados por instrução. A instrução 1 seleciona o registrador
-- DEBUG de 64 bits; qualquer outra deixa um bypass de 1 bit. Um deslocamento do
-- registrador DEBUG traz um comando e envia o estado do último:
--
--   entra   [63:60] op   [59:56] habilita de bytes   [55:32] endereço de palavra   [31:0] dado
--   sai     [63:56] status   [55:32] última palavra acessada   [31:0] dado lido
--
--   bit 0 do status  ocupado: o comando anterior não terminou (dado e palavra ainda inválidos)
--   bit 1 do status  erro: o controlador não respondeu
--   bit 2 do status  a SDRAM está inicializada
--   bit 3 do status  sobrecarga: um comando chegou com o mestre ocupado e foi descartado (limpa no comando seguinte)
--
-- O comando sai quando o deslocamento termina (estado update). Os comandos são
-- os do sdram_dbg_master, exceto op 0, que não envia nada: um deslocamento com
-- op 0 só lê o status. O status de um comando só está atualizado alguns clocks
-- JTAG depois do envio, então o primeiro deslocamento após um comando ainda pode
-- mostrar ocupado e o seguinte não. cmd_tog, op, be, addr e data ficam estáveis
-- até o próximo comando aceito; done_tog e rsp_* são lidos por um sincronizador
-- em tck.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_jtag_core is
  port (
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

    -- Alternância que pede um comando ao mestre de debug.
    o_cmd_tog    : out std_logic;
    -- Operação do comando de debug.
    o_op         : out std_logic_vector(3 downto 0);
    -- Habilita de bytes do comando.
    o_be         : out std_logic_vector(3 downto 0);
    -- Endereço do acesso.
    o_addr       : out std_logic_vector(23 downto 0);
    -- Dado lido.
    o_data       : out std_logic_vector(31 downto 0);
    -- Alternância que confirma o comando concluído.
    i_done_tog   : in  std_logic;
    -- Endereço da resposta do comando.
    i_rsp_addr   : in  std_logic_vector(23 downto 0);
    -- Dado da resposta do comando.
    i_rsp_data   : in  std_logic_vector(31 downto 0);
    -- Status da resposta do comando.
    i_rsp_status : in  std_logic_vector(7 downto 0)
  );
end entity sdram_jtag_core;

architecture rtl of sdram_jtag_core is

  -- Registrador de instrução do Virtual JTAG.
  signal ir       : std_logic_vector(1 downto 0) := (others => '0');
  -- Registrador de deslocamento do DEBUG de 64 bits.
  signal sr       : std_logic_vector(63 downto 0) := (others => '0');
  -- Registrador de bypass de 1 bit.
  signal bypass   : std_logic := '0';
  -- Toggle de comando ao mestre de debug (registrado).
  signal cmd_i    : std_logic := '0';
  -- Sincronizador de dois estágios de done_tog em tck.
  signal done_s   : std_logic_vector(1 downto 0) := "00";
  -- Um comando chegou com o mestre ocupado e foi descartado.
  signal overrun  : std_logic := '0';
  -- O comando anterior ainda não terminou.
  signal busy     : std_logic;
  -- Operação do comando enviado (registrada).
  signal op_r     : std_logic_vector(3 downto 0) := (others => '0');
  -- Habilita de bytes do comando enviado (registrado).
  signal be_r     : std_logic_vector(3 downto 0) := (others => '0');
  -- Endereço do comando enviado (registrado).
  signal addr_r   : std_logic_vector(23 downto 0) := (others => '0');
  -- Dado do comando enviado (registrado).
  signal data_r   : std_logic_vector(31 downto 0) := (others => '0');

begin

  busy    <= '1' when cmd_i /= done_s(1) else '0';
  o_cmd_tog <= cmd_i;
  o_op      <= op_r;
  o_be      <= be_r;
  o_addr    <= addr_r;
  o_data    <= data_r;
  o_tdo     <= sr(0) when ir = "01" else bypass;

  process (i_tck)
  begin
    if rising_edge(i_tck) then
      done_s <= done_s(0) & i_done_tog;

      if i_state_uir = '1' then
        ir <= i_ir_in;
      end if;

      if i_state_cdr = '1' then
        if ir = "01" then
          sr <= ("0000" & overrun & i_rsp_status(2 downto 1) & busy) & i_rsp_addr & i_rsp_data;
        end if;
      elsif i_state_sdr = '1' then
        if ir = "01" then
          sr <= i_tdi & sr(63 downto 1);
        else
          bypass <= i_tdi;
        end if;
      elsif i_state_udr = '1' then
        -- op 0 é só um jeito de ler o status: não envia nada
        if ir = "01" and sr(63 downto 60) /= "0000" then
          if busy = '1' then
            overrun <= '1';
          else
            overrun <= '0';
            op_r    <= sr(63 downto 60);
            be_r    <= sr(59 downto 56);
            addr_r  <= sr(55 downto 32);
            data_r  <= sr(31 downto 0);
            cmd_i   <= not cmd_i;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
