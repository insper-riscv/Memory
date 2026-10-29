-- =============================================================================
-- Modelo comportamental da SDRAM SDR de 32M x 16 (somente simulação)
--
-- Guarda os dados escritos numa tabela esparsa e FAZ A SIMULAÇÃO FALHAR quando o
-- controlador quebra uma regra do chip: ordem dos comandos, os tempos do
-- sdram_pkg, a sequência de energização, o registrador de modo, o intervalo de
-- refresh, uma leitura ou escrita em um banco que não está aberto e dois
-- comandos que se sobrepõem em uma rajada.
--
-- init_file (opcional): imagem de programa gravada no chip no instante zero, uma
-- palavra de 32 bits por linha em hexadecimal, a partir do endereço de palavra 0
-- (a base da SDRAM). Representa o hospedeiro carregando o chip pela porta de
-- debug antes de o core ser liberado, de modo que uma simulação pode começar de
-- código que mora na SDRAM.
--
-- A porta de debug por palavra lê o conteúdo armazenado direto do modelo (a
-- palavra de 32 bits de um endereço de palavra), e um pulso em dbg_flip inverte
-- um bit de uma palavra armazenada, para provar que uma verificação nota uma
-- memória corrompida.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sdram_pkg.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity sdram_model is
  generic (
    -- Período do clock em picossegundos.
    tck_ps    : natural := T_CK_PS;
    -- Arquivo com a imagem inicial do chip (vazio: chip zerado).
    init_file : string  := ""
  );
  port (
    -- Clock do módulo.
    i_clk    : in    std_logic;
    -- Habilita de clock (CKE) do chip.
    i_cke    : in    std_logic;
    -- Seleção do chip, ativa em '0'.
    i_cs_n   : in    std_logic;
    -- Strobe de endereço de linha, ativo em '0'.
    i_ras_n  : in    std_logic;
    -- Strobe de endereço de coluna, ativo em '0'.
    i_cas_n  : in    std_logic;
    -- Habilita de escrita, ativo em '0'.
    i_we_n   : in    std_logic;
    -- Seleção do banco.
    i_ba     : in    std_logic_vector(1 downto 0);
    -- Endereço de linha ou de coluna.
    i_a      : in    std_logic_vector(12 downto 0);
    -- Máscara de bytes dos dados.
    i_dqm    : in    std_logic_vector(1 downto 0);
    -- Pinos de dados DQ.
    io_dq     : inout std_logic_vector(15 downto 0);
    -- Em '1' enquanto o controlador está em reset: o chip começa uma nova sequência de energização (espera, PRECHARGE ALL, refreshes e registrador de modo).
    i_reinit : in    std_logic;

    -- Endereço de palavra lido diretamente do modelo do chip, para depuração.
    i_dbg_word_addr   : in  std_logic_vector(23 downto 0);
    -- Palavra do modelo do chip no endereço de dbg_word_addr.
    o_dbg_word_data   : out std_logic_vector(31 downto 0);
    -- Pulso que inverte um bit de uma palavra armazenada, para provar que uma verificação nota a corrupção.
    i_dbg_flip        : in  std_logic;
    -- Endereço de palavra cujo bit é invertido.
    i_dbg_flip_addr   : in  std_logic_vector(23 downto 0);
    -- Posição do bit invertido na palavra.
    i_dbg_flip_bit    : in  std_logic_vector(4 downto 0);
    -- Contagem de comandos AUTO REFRESH recebidos pelo chip.
    o_dbg_refreshes   : out std_logic_vector(31 downto 0);
    -- A sequência de inicialização do chip foi aceita ('1').
    o_dbg_init_ok     : out std_logic
  );
end entity sdram_model;

architecture rtl of sdram_model is

  -- Nó da lista encadeada de um balde da tabela esparsa.
  type node_t;
  -- Ponteiro para um nó da tabela.
  type node_ptr is access node_t;
  -- Nó da lista encadeada de um balde da tabela esparsa.
  type node_t is record
    key  : natural;
    val  : std_logic_vector(15 downto 0);
    next_node : node_ptr;
  end record;
  -- Vetor de baldes da tabela esparsa.
  type bucket_array is array (0 to 65535) of node_ptr;

  -- Tabela esparsa de meias-palavras de 16 bits, indexada por linha, banco e coluna.
  type sparse_t is protected
    procedure write (key : natural; val : std_logic_vector(15 downto 0));
    impure function read (key : natural) return std_logic_vector;
  end protected sparse_t;

  -- Tabela esparsa de meias-palavras de 16 bits, indexada por linha, banco e coluna.
  type sparse_t is protected body
    -- Baldes da tabela esparsa.
    variable buckets : bucket_array := (others => null);

    procedure write (key : natural; val : std_logic_vector(15 downto 0)) is
      -- Nó corrente na busca da tabela.
      variable p : node_ptr := buckets(key mod 65536);
    begin
      while p /= null loop
        if p.key = key then
          p.val := val;
          return;
        end if;
        p := p.next_node;
      end loop;
      p := new node_t'(key => key, val => val, next_node => buckets(key mod 65536));
      buckets(key mod 65536) := p;
    end procedure;

    impure function read (key : natural) return std_logic_vector is
      -- Nó corrente na busca da tabela.
      variable p : node_ptr := buckets(key mod 65536);
    begin
      while p /= null loop
        if p.key = key then
          return p.val;
        end if;
        p := p.next_node;
      end loop;
      return x"0000";
    end function;
  end protected body sparse_t;

  -- Conteúdo do chip.
  shared variable mem : sparse_t;

  -- Período do clock como tempo de simulação.
  constant TCK : time := tck_ps * 1 ps;

  -- Um tempo por banco.
  type time_arr  is array (0 to 3) of time;
  -- Um booleano por banco.
  type bool_arr  is array (0 to 3) of boolean;
  -- Uma linha aberta por banco.
  type row_arr   is array (0 to 3) of natural;

  -- Posição do pipeline de leitura: validade e dado de 16 bits.
  type rd_slot_t is record
    valid : boolean;
    data  : std_logic_vector(15 downto 0);
  end record;
  -- Pipeline que atrasa o dado lido pela latência CAS.
  type rd_pipe_t is array (1 to 6) of rd_slot_t;

  -- Valor que o chip coloca nos pinos DQ.
  signal dq_drv : std_logic_vector(15 downto 0) := (others => 'Z');
  -- O chip dirige os pinos DQ.
  signal dq_oe  : std_logic := '0';
  -- Contagem dos comandos AUTO REFRESH recebidos.
  signal refresh_count : natural := 0;
  -- A sequência de energização foi aceita.
  signal init_ok       : std_logic := '0';

  function key_of (row : natural; bank : natural; col : natural) return natural is
  begin
    return (row * 4 + bank) * 1024 + col;
  end function;

begin

  io_dq <= dq_drv when dq_oe = '1' else (others => 'Z');

  load_image : process
    file f      : text;
    -- Linha lida do arquivo de imagem.
    variable l  : line;
    -- Palavra lida do arquivo ou índice de palavra.
    variable w  : std_logic_vector(31 downto 0);
    -- A leitura da linha teve sucesso.
    variable ok : boolean;
    -- Índice da palavra gravada.
    variable idx : natural := 0;
  begin
    if init_file'length > 0 then
      file_open(f, init_file, read_mode);
      while not endfile(f) loop
        readline(f, l);
        if l'length >= 8 then
          hread(l, w, ok);
          if ok then
            mem.write(2 * idx, w(15 downto 0));
            mem.write(2 * idx + 1, w(31 downto 16));
          end if;
          idx := idx + 1;
        end if;
      end loop;
      file_close(f);
    end if;
    wait;
  end process;

  o_dbg_refreshes <= std_logic_vector(to_unsigned(refresh_count, 32));
  o_dbg_init_ok   <= init_ok;

  dbg_read : process (i_clk)
    -- Palavra lida do arquivo ou índice de palavra.
    variable w : natural;
  begin
    if rising_edge(i_clk) then
      w := to_integer(unsigned(i_dbg_word_addr));
      o_dbg_word_data <= mem.read(2 * w + 1) & mem.read(2 * w);
    end if;
  end process;

  dbg_flipper : process (i_dbg_flip)
    -- Palavra lida do arquivo ou índice de palavra.
    variable w : natural;
    -- Índice da meia-palavra.
    variable k : natural;
    -- Meia-palavra lida da tabela.
    variable v    : std_logic_vector(15 downto 0);
  begin
    if rising_edge(i_dbg_flip) then
      w := to_integer(unsigned(i_dbg_flip_addr));
      k := to_integer(unsigned(i_dbg_flip_bit));
      v := mem.read(2 * w + k / 16);
      v(k mod 16) := not v(k mod 16);
      mem.write(2 * w + k / 16, v);
    end if;
  end process;

  chip : process (i_clk)
    -- Comando de quatro bits (cs_n & ras_n & cas_n & we_n) visto neste clock.
    variable cmd         : std_logic_vector(3 downto 0);
    -- Instante do início da energização.
    variable power_up    : time := 0 ns;
    -- Algum comando já foi visto.
    variable seen_cmd    : boolean := false;
    -- O PRECHARGE ALL da energização ocorreu.
    variable pre_all_ok  : boolean := false;
    -- Refreshes vistos na energização.
    variable n_refresh   : natural := 0;
    -- O registrador de modo foi carregado.
    variable mrs_done    : boolean := false;
    -- Instante até o qual o registrador de modo ainda está sendo carregado.
    variable mrs_until   : time := 0 ns;
    -- Instante até o qual um refresh ainda está em andamento.
    variable ref_until   : time := 0 ns;
    -- Instante do último refresh.
    variable last_ref    : time := 0 ns;
    -- A verificação do intervalo de refresh está ativa.
    variable ref_check   : boolean := false;
    -- Instante até o qual uma rajada ocupa o barramento.
    variable burst_until : time := 0 ns;

    -- Banco aberto por ACTIVE.
    variable bank_open   : bool_arr := (others => false);
    -- Linha aberta em cada banco.
    variable bank_row    : row_arr  := (others => 0);
    -- Instante do último ACTIVE de cada banco.
    variable act_time    : time_arr := (others => 0 ns);
    -- Instante em que cada banco ficou ocioso.
    variable idle_time   : time_arr := (others => 0 ns);
    -- Instante do fim do último dado de escrita de cada banco.
    variable last_wr_end : time_arr := (others => 0 ns);

    -- Pipeline do dado lido.
    variable rd_pipe     : rd_pipe_t := (others => (valid => false, data => (others => '0')));
    -- Há uma escrita de rajada em andamento.
    variable wr_pending  : boolean := false;
    -- Chave da meia-palavra da escrita em andamento.
    variable wr_key      : natural := 0;
    -- Banco da escrita em andamento.
    variable wr_bank     : natural := 0;

    -- Banco do comando.
    variable b : natural;
    -- Linha do comando.
    variable row : natural;
    -- Coluna do comando.
    variable col : natural;
    -- Chave da tabela (linha, banco e coluna).
    variable key : natural;
    -- Instante em que o PRECHARGE começa.
    variable pre_start   : time;
    -- O comando usa auto-precharge.
    variable ap          : boolean;
    -- Valor antigo da meia-palavra.
    variable old : std_logic_vector(15 downto 0);
    -- Valor novo depois de aplicar a máscara de bytes.
    variable merged : std_logic_vector(15 downto 0);
  begin
    if rising_edge(i_clk) then

      if i_reinit = '1' then
        power_up   := now;
        seen_cmd   := false;
        pre_all_ok := false;
        n_refresh  := 0;
        mrs_done   := false;
        ref_check  := false;
        for i in 0 to 3 loop
          bank_open(i) := false;
          idle_time(i) := now;
        end loop;
        wr_pending := false;
        init_ok    <= '0';
      end if;

      -- 1. dados nos pinos: lança o que o pipeline de leitura guarda para esta borda
      if rd_pipe(1).valid then
        dq_drv <= rd_pipe(1).data;
        dq_oe  <= '1';
      else
        dq_oe  <= '0';
      end if;
      for i in 1 to 5 loop
        rd_pipe(i) := rd_pipe(i + 1);
      end loop;
      rd_pipe(6).valid := false;

      -- 2. o segundo beat de uma escrita comandada na borda anterior
      if wr_pending then
        old    := mem.read(wr_key);
        merged := old;
        if i_dqm(0) = '0' then merged(7 downto 0)  := io_dq(7 downto 0);  end if;
        if i_dqm(1) = '0' then merged(15 downto 8) := io_dq(15 downto 8); end if;
        mem.write(wr_key, merged);
        last_wr_end(wr_bank) := now;
        wr_pending := false;
      end if;

      -- 3. intervalo de refresh: depois de o registrador de modo ser carregado, um refresh pelo menos a cada tREFI
      if ref_check then
        assert (now - last_ref) <= T_REFI_PS * 1 ps
          report "SDRAM model: no AUTO REFRESH within tREFI" severity failure;
      end if;

      -- um comando que o controlador emite na borda do seu próprio reset pertence à execução anterior
      if i_cke = '1' and i_cs_n = '0' and i_reinit = '0' then
        cmd := i_cs_n & i_ras_n & i_cas_n & i_we_n;

        if cmd /= CMD_NOP then
          if not seen_cmd then
            seen_cmd := true;
            assert now - power_up >= T_INIT_PS * 1 ps
              report "SDRAM model: first command before the power-up wait" severity failure;
          end if;
        end if;

        b   := to_integer(unsigned(i_ba));
        row := to_integer(unsigned(i_a));
        col := to_integer(unsigned(i_a(9 downto 0)));
        ap  := i_a(10) = '1';

        if cmd = CMD_LOAD_MODE then
          assert pre_all_ok and n_refresh >= 2
            report "SDRAM model: LOAD MODE REGISTER before PRECHARGE ALL and two refreshes" severity failure;
          assert now >= ref_until report "SDRAM model: LOAD MODE REGISTER inside tRFC" severity failure;
          assert i_a = MODE_REG
            report "SDRAM model: unexpected mode register value" severity failure;
          mrs_done  := true;
          mrs_until := now + T_MRD_CK * TCK;
          last_ref  := now;
          ref_check := true;
          init_ok   <= '1';

        elsif cmd = CMD_PRECHARGE then
          assert now >= ref_until report "SDRAM model: PRECHARGE inside tRFC" severity failure;
          if ap then
            for i in 0 to 3 loop
              if bank_open(i) then
                assert now - act_time(i) >= T_RAS_PS * 1 ps
                  report "SDRAM model: PRECHARGE before tRAS" severity failure;
              end if;
              bank_open(i) := false;
              idle_time(i) := now + T_RP_PS * 1 ps;
            end loop;
            pre_all_ok := true;
          else
            if bank_open(b) then
              assert now - act_time(b) >= T_RAS_PS * 1 ps
                report "SDRAM model: PRECHARGE before tRAS" severity failure;
              assert now - last_wr_end(b) >= T_WR_PS * 1 ps
                report "SDRAM model: PRECHARGE before tWR" severity failure;
            end if;
            bank_open(b) := false;
            idle_time(b) := now + T_RP_PS * 1 ps;
          end if;

        elsif cmd = CMD_REFRESH then
          for i in 0 to 3 loop
            assert not bank_open(i) and now >= idle_time(i)
              report "SDRAM model: AUTO REFRESH with i_a bank not idle" severity failure;
          end loop;
          assert now >= ref_until report "SDRAM model: AUTO REFRESH inside tRFC" severity failure;
          assert pre_all_ok report "SDRAM model: AUTO REFRESH before PRECHARGE ALL" severity failure;
          ref_until := now + T_RFC_PS * 1 ps;
          if mrs_done then
            last_ref := now;
          end if;
          n_refresh := n_refresh + 1;
          refresh_count <= refresh_count + 1;

        elsif cmd = CMD_ACTIVE then
          assert mrs_done report "SDRAM model: ACTIVE before the mode register is set" severity failure;
          assert now >= mrs_until report "SDRAM model: ACTIVE inside tMRD" severity failure;
          assert now >= ref_until report "SDRAM model: ACTIVE inside tRFC" severity failure;
          assert not bank_open(b) report "SDRAM model: ACTIVE on an open bank" severity failure;
          assert now >= idle_time(b) report "SDRAM model: ACTIVE inside tRP" severity failure;
          assert now - act_time(b) >= T_RC_PS * 1 ps or act_time(b) = 0 ns
            report "SDRAM model: ACTIVE inside tRC" severity failure;
          bank_open(b) := true;
          bank_row(b)  := row;
          act_time(b)  := now;

        elsif cmd = CMD_READ or cmd = CMD_WRITE then
          assert mrs_done report "SDRAM model: read/write before the mode register is set" severity failure;
          assert bank_open(b) report "SDRAM model: read/write on i_a bank that is not open" severity failure;
          assert now - act_time(b) >= T_RCD_PS * 1 ps
            report "SDRAM model: read/write inside tRCD" severity failure;
          assert now >= burst_until report "SDRAM model: read/write overlaps i_a burst" severity failure;
          assert col mod 2 = 0 report "SDRAM model: burst of 2 must start on an even column" severity failure;
          key := key_of(bank_row(b), b, col);

          if cmd = CMD_READ then
            -- primeiro beat lançado CL bordas depois desta, segundo beat uma borda depois
            rd_pipe(CAS_LATENCY).valid := true;
            rd_pipe(CAS_LATENCY).data  := mem.read(key);
            rd_pipe(CAS_LATENCY + 1).valid := true;
            rd_pipe(CAS_LATENCY + 1).data  := mem.read(key + 1);
            burst_until := now + 2 * TCK;
            if ap then
              pre_start := now + 2 * TCK;
              if act_time(b) + T_RAS_PS * 1 ps > pre_start then
                pre_start := act_time(b) + T_RAS_PS * 1 ps;
              end if;
              bank_open(b) := false;
              idle_time(b) := pre_start + T_RP_PS * 1 ps;
            end if;
          else
            old    := mem.read(key);
            merged := old;
            if i_dqm(0) = '0' then merged(7 downto 0)  := io_dq(7 downto 0);  end if;
            if i_dqm(1) = '0' then merged(15 downto 8) := io_dq(15 downto 8); end if;
            mem.write(key, merged);
            wr_pending := true;
            wr_key     := key + 1;
            wr_bank    := b;
            burst_until := now + 2 * TCK;
            last_wr_end(b) := now + TCK;
            if ap then
              pre_start := now + TCK + T_WR_PS * 1 ps;
              if act_time(b) + T_RAS_PS * 1 ps > pre_start then
                pre_start := act_time(b) + T_RAS_PS * 1 ps;
              end if;
              bank_open(b) := false;
              idle_time(b) := pre_start + T_RP_PS * 1 ps;
            end if;
          end if;

        end if;
      end if;
    end if;
  end process chip;

end architecture rtl;
