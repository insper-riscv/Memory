# sdram_ctrl

## 1. Função do componente no SoC

Controlador da SDRAM SDR. O padrão dos generics é o chip de 32M x 16 (64 MB) da placa DE0-CV, e a largura do barramento de dados e as larguras de linha, banco e coluna são generics, o que cobre também o chip de 32 bits da DE2-115. Recebe pedidos de uma palavra de 32 bits, ou de uma linha de quatro palavras (16 bytes), por um handshake de alternância e gera a sequência de comandos do chip. A política é de página fechada. Todo acesso ativa a sua linha e lê ou escreve com auto-precharge, de modo que nenhuma linha fica aberta e a ordem dos comandos não depende do acesso anterior. O controlador também executa a sequência de energização e emite os refreshes periódicos.

Os tempos do chip vêm de [sdram_pkg](sdram_pkg.md) e estão comparados com o datasheet em [sdram_timings.md](sdram_timings.md). O pedido de linha está descrito do ponto de vista do sistema em [sdram_line.md](sdram_line.md).

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `tck_ps` | natural | `T_CK_PS` (7000) | período do clock em ps, base da conversão dos tempos do chip em ciclos |
| `init_cycles` | natural | `cycles(T_INIT_PS, T_CK_PS)` (28572) | ciclos de espera após o reset antes do primeiro comando |
| `refresh_cycles` | natural | `cycles(T_REFI_PS, T_CK_PS) * 9 / 10` (1005) | contagem do intervalo entre dois refreshes |
| `capture_extra` | natural | 0 | clocks extras antes de amostrar o dado lido, para compensar a fase da placa |
| `sync_req` | boolean | verdadeiro | verdadeiro passa o toggle de pedido por um sincronizador, falso o usa direto porque ele vem deste clock |
| `dq_width` | natural | 16 | largura do barramento de dados do chip em bits, 16 ou 32, que define a rajada de $B = 32 / \text{dq\_width}$ beats por palavra |
| `row_bits` | natural | 13 | bits do endereço de linha do chip |
| `bank_bits` | natural | 2 | bits do endereço de banco do chip |
| `col_bits` | natural | 10 | bits do endereço de coluna do chip, no máximo 10 porque o bit 10 de `o_dram_addr` é o auto-precharge |

### 2.2. Portas de pedido

| Porta | Dir. | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | clock do controlador |
| `i_rst` | entrada | 1 | reset síncrono, ativo em `'1'` |
| `i_req_tog` | entrada | 1 | cada inversão é um pedido novo |
| `o_ack_tog` | saída | 1 | fica igual a `i_req_tog` quando o pedido foi atendido |
| `o_init_done` | saída | 1 | `'1'` depois que a energização terminou |
| `i_we` | entrada | 1 | escrita (`'1'`) ou leitura (`'0'`) |
| `i_addr` | entrada | $AW$ | endereço de palavra de 32 bits, com $AW$ definido na seção 3.2 (24 no padrão) |
| `i_wdata` | entrada | 32 | dado de escrita (palavra 0) |
| `i_be` | entrada | 4 | habilita de bytes da palavra 0, um bit por byte |
| `o_rdata` | saída | 32 | dado lido (palavra 0) |
| `i_line` | entrada | 1 | `'1'` pede uma linha de quatro palavras (padrão `'0'`) |
| `i_wdata_x` | entrada | 96 | palavras 1 a 3 do dado de escrita, a palavra 1 nos bits mais baixos (padrão zero) |
| `i_be_x` | entrada | 12 | habilita de bytes das palavras 1 a 3 (padrão zero) |
| `o_rdata_x` | saída | 96 | palavras 1 a 3 do dado lido |

### 2.3. Portas do chip

| Porta | Dir. | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `o_dram_cke` | saída | 1 | habilita de clock do chip, fixo em `'1'` |
| `o_dram_cs_n` | saída | 1 | seleção do chip, ativa em `'0'` |
| `o_dram_ras_n` | saída | 1 | strobe de endereço de linha, ativo em `'0'` |
| `o_dram_cas_n` | saída | 1 | strobe de endereço de coluna, ativo em `'0'` |
| `o_dram_we_n` | saída | 1 | habilita de escrita, ativo em `'0'` |
| `o_dram_ba` | saída | `bank_bits` | banco |
| `o_dram_addr` | saída | maior entre `row_bits` e `col_bits` + 1 | endereço de linha ou de coluna |
| `o_dram_dqm` | saída | `dq_width` / 8 | máscara de bytes dos dados, um bit por byte, mascara em `'1'` |
| `o_dram_dq_out` | saída | `dq_width` | dado que o controlador coloca nos pinos DQ |
| `o_dram_dq_oe` | saída | 1 | `'1'` quando o controlador dirige os pinos DQ |
| `i_dram_dq_in` | entrada | `dq_width` | dado lido dos pinos DQ |

Todas as saídas do chip saem de registradores. O comando decidido numa borda aparece nos pinos logo depois dela, e o chip o amostra na borda seguinte. Sem comando, os pinos carregam NOP com endereço e máscara zerados, e `o_dram_dq_oe` fica em `'0'`.

## 3. Comportamento

### 3.1. Handshake de pedido

O requisitante coloca os campos do pedido nos barramentos e inverte `i_req_tog`. Os barramentos ficam estáveis da inversão de `i_req_tog` até a de `o_ack_tog`. Um pedido está pendente enquanto o toggle de pedido efetivo difere de `o_ack_tog`. O controlador só aceita um pedido no estado livre e com o intervalo mínimo entre comandos já cumprido (seção 3.4). Ao aceitar, copia todos os campos para registradores internos e inverte `o_ack_tog` ao fim do acesso.

Com `sync_req` verdadeiro o toggle de pedido atravessa um sincronizador de Common-Components, o que permite um requisitante em outro clock. Com `sync_req` falso o toggle é usado direto, sem a latência do sincronizador.

O reset leva `o_ack_tog` a `'0'`. O dado lido só muda quando uma leitura é amostrada, e um pedido de escrita não altera `o_rdata` nem `o_rdata_x`.

### 3.2. Endereçamento

O endereço de palavra tem $AW = \text{row\_bits} + \text{bank\_bits} + \text{col\_bits} - \log_2 B$ bits. Com $B = 2$ a coluna do chip é sempre par, e com $B = 1$ a coluna da palavra é a do chip. Com $WC = \text{col\_bits} - \log_2 B$, a largura da coluna de palavra, os campos de `i_addr` são os da tabela.

| Bits de `i_addr` | Campo | Destino |
| :--- | :--- | :--- |
| $AW - 1$ a $WC + \text{bank\_bits}$ | linha | `o_dram_addr` no ACTIVE |
| $WC + \text{bank\_bits} - 1$ a $WC$ | banco | `o_dram_ba` |
| $WC - 1$ a 0 | coluna de palavra | bits $\text{col\_bits} - 1$ a $\log_2 B$ de `o_dram_addr` no READ e no WRITE, com os $\log_2 B$ bits baixos em zero |

No padrão da DE0-CV $AW = 24$ e $WC = 9$, e a linha, o banco e a coluna são os bits 23 a 11, 10 a 9 e 8 a 0. Com o chip de 32 bits da DE2-115, $AW = 25$ e $WC = 10$, e são os bits 24 a 12, 11 a 10 e 9 a 0.

Em READ e WRITE o bit 10 de `o_dram_addr` é o auto-precharge. No acesso de palavra ele vale `'1'`. No acesso de linha vale `'1'` só no quarto comando, e os dois bits de `o_dram_addr` logo acima dos bits da rajada levam o índice da palavra (0 a 3) no lugar dos dois bits baixos de `i_addr`. As quatro palavras de uma linha caem na mesma linha e no mesmo banco do chip porque a linha tem 16 bytes e é alinhada.

### 3.3. Máquina de estados

| Estado | O que faz |
| :--- | :--- |
| `ST_INIT_WAIT` | conta `init_cycles` clocks após o reset |
| `ST_INIT_PRE` | emite PRECHARGE de todos os bancos |
| `ST_INIT_REF` | emite AUTO REFRESH, `INIT_REFRESHES` vezes |
| `ST_INIT_MRS` | emite LOAD MODE REGISTER com o valor do pacote e sinaliza `o_init_done` |
| `ST_WAIT` | conta os clocks até o próximo comando |
| `ST_IDLE` | emite o refresh devido ou aceita um pedido e emite o ACTIVE |
| `ST_RW` | emite o READ ou o WRITE de uma palavra |
| `ST_RDGAP` | clock de intervalo entre dois READ de uma linha |
| `ST_WRITE2` | coloca o segundo beat de uma escrita nos pinos |
| `ST_READ` | espera a amostragem do dado, que encerra o acesso |

Uma espera de $n$ clocks significa que o comando seguinte sai $n$ bordas depois do comando atual.

### 3.4. Intervalos mínimos entre comandos

Com $C_x = \lceil T_x / T_{CK} \rceil$ e $T_{CK} = 7000$ ps, os valores são $C_{RCD} = 3$, $C_{RP} = 3$, $C_{RC} = 9$, $C_{RFC} = 9$ e $C_{WR} = 2$. O controlador define dois intervalos entre um ACTIVE e o próximo, um para a palavra e outro para a linha.

$$
N_{palavra} = \max\left(C_{RC},\; C_{RCD} + CL + B + 2,\; C_{RCD} + B + C_{WR} + C_{RP}\right) = 10
$$

$$
N_{linha} = \max\left(C_{RC},\; C_{RCD} + 3B + CL + B + 2,\; C_{RCD} + 4B + C_{WR} + C_{RP}\right) = 16
$$

Os valores numéricos são os de $B = 2$. Com $B = 1$ saem $N_{palavra} = 9$ e $N_{linha} = 12$.

No ACTIVE, um contador é carregado com $N_{palavra}$ ou $N_{linha}$ e decrementa a cada clock. Um novo ACTIVE ou um refresh só sai quando o contador chega a zero, o que ocorre $N + 1$ clocks depois do ACTIVE. O mesmo contador protege o intervalo $C_{RFC}$ depois de um refresh e o `T_MRD_CK` depois do registrador de modo.

### 3.5. Energização

1. Após o reset, espera `init_cycles` clocks sem comando.
2. Emite PRECHARGE de todos os bancos (bit 10 do endereço em `'1'`) e espera $C_{RP}$.
3. Emite `INIT_REFRESHES` comandos AUTO REFRESH, cada um seguido de uma espera de $C_{RFC}$.
4. Emite LOAD MODE REGISTER com o valor definido em [sdram_pkg](sdram_pkg.md), coloca `o_init_done` em `'1'` e carrega o contador de refresh.
5. Espera `T_MRD_CK` clocks e passa ao estado livre.

### 3.6. Acessos

Os instantes abaixo são contados em bordas a partir de $t_0$, a borda em que o controlador decide o ACTIVE. Cada comando fica nos pinos logo depois da borda em que é decidido.

| Acesso | Comandos (borda de decisão) | Dado | `o_ack_tog` inverte em | Próximo ACTIVE a partir de |
| :--- | :--- | :--- | :--- | :--- |
| leitura de palavra | READ em $t_0+3$ | beats 0 e 1 amostrados em $t_0+8$ e $t_0+9$ | $t_0+9$ | $t_0+11$ |
| escrita de palavra | WRITE em $t_0+3$ | beat 0 com o WRITE, beat 1 um clock depois | $t_0+4$ | $t_0+11$ |
| leitura de linha | READ em $t_0+3$, $t_0+5$, $t_0+7$ e $t_0+9$ | beats 0 a 7 amostrados de $t_0+8$ a $t_0+15$ | $t_0+15$ | $t_0+17$ |
| escrita de linha | WRITE em $t_0+3$, $t_0+5$, $t_0+7$ e $t_0+9$ | dois beats por palavra, o último em $t_0+10$ | $t_0+10$ | $t_0+17$ |

O primeiro READ ou WRITE sai $C_{RCD}$ clocks depois do ACTIVE. Na linha, os comandos seguintes saem a cada $B$ clocks, o comprimento de uma rajada, e os $4B$ beats ocupam os pinos sem intervalo. A tabela vale para $B = 2$. Com $B = 1$ (chip de 32 bits) a rajada tem um beat, os quatro comandos de uma linha saem de $t_0+3$ a $t_0+6$, os estados `ST_RDGAP` e `ST_WRITE2` não são usados e o pedido de palavra termina no beat 0.

Na leitura, o beat $m$ (0 a $4B - 1$, ou seja, 0 a 7 no padrão) é amostrado $CL + 2 + m + \text{capture\_extra}$ clocks depois da borda do primeiro READ. O beat $m$ ocupa a fatia de `dq_width` bits que começa no bit `dq_width` $\cdot\, m$ do vetor formado por `o_rdata` e, acima dele, `o_rdata_x`. No padrão os beats 0 e 1 formam `o_rdata` e os beats 2 a 7 formam, de dois em dois, as palavras 1 a 3 de `o_rdata_x`. O pedido termina na amostragem do último beat, o beat $B - 1$ no acesso de palavra e o beat $4B - 1$ no de linha.

Na escrita, os beats de cada palavra levam as fatias de `dq_width` bits da palavra, da mais baixa à mais alta, e a máscara de cada beat é o complemento dos bits de `i_be` (ou de `i_be_x`) daquela fatia. O chip não altera um byte mascarado. A leitura não usa máscara.

### 3.7. Refresh

Depois da energização, um contador marca um refresh como devido a cada $\text{refresh\_cycles} + 1$ clocks. No estado livre, um refresh devido tem prioridade sobre um pedido pendente, desde que o intervalo mínimo entre comandos esteja cumprido. Depois do refresh, o próximo comando espera $C_{RFC}$.

Com os valores padrão o período é de 1006 clocks, cerca de 7,04 µs, e o modelo do chip reprova a simulação quando dois refreshes ficam mais de $T_{REFI} = 7{,}8125$ µs afastados.

## 4. Integração

| Instância | Onde | Como liga o controlador |
| :--- | :--- | :--- |
| `u_ctrl` em `sdram_system` | topo de simulação do subsistema | atrás de [sdram_arbiter](sdram_arbiter.md), com `sync_req` falso e `tck_ps`, `init_cycles` e `refresh_cycles` repassados dos generics do topo |
| `u_ctrl` em `sdram_bist_system` | topo de simulação do autoteste | ligado direto ao autoteste, com `sync_req` padrão e `capture_extra` vindo do generic do topo |

Com `capture_extra` igual a 1, o topo do autoteste registra os pinos de dados uma vez antes de entrarem no controlador. Os pinos DQ são resolvidos fora do controlador. O topo coloca `o_dram_dq_out` nos pinos quando `o_dram_dq_oe` vale `'1'`, e o modelo do chip ([sdram_model](sdram_model.md)) dirige os pinos nos demais casos. O sincronizador instanciado vem de Common-Components (`src/common/src/synchronizer.vhd`), que os testes compilam antes do controlador.

## 5. Verificação

O modelo do chip reprova a simulação em qualquer violação de tempo, ordem de comandos, energização ou intervalo de refresh. Por isso um teste que passa também prova que o controlador obedece ao chip. A prova formal do controlador está em `formal/sdram_ctrl/` e roda sobre a netlist de cada largura, a de 16 bits (nos clocks de 7 ns e de 10 ns) e a de 32 bits.

| Entrada de `tests.json` | Módulo de teste | O que exercita no controlador |
| :--- | :--- | :--- |
| `SdramSystem` | [sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py) | energização, escrita e leitura, todas as máscaras de bytes, decodificação de banco, linha e coluna, tráfego aleatório, refresh com o barramento ocioso por 60 µs, relações diferentes entre o clock do núcleo e o do controlador, bit corrompido no chip, acessos de linha (escrita, leitura, máscaras e custo contra quatro palavras) e mistura de linhas e palavras |
| `SdramCtrl32` e `SdramSystem32` | [sdram_ctrl.py](../../../tests/python/unittests/ram/sdram_ctrl.py) e [sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py) | os mesmos testes de energização, palavra, máscaras, linha, refresh e tráfego aleatório com `dq_width` igual a 32, sobre o modelo do chip de 32 bits |
| `SdramBist` | [sdram_bist.py](../../../tests/python/unittests/ram/sdram_bist.py) | o controlador ligado direto ao autoteste, nos modos rápido, padrões, varredura e endereços aleatórios, mais o controle de um bit invertido no chip |
| `SdramBistRegisteredPins` | [sdram_bist.py](../../../tests/python/unittests/ram/sdram_bist.py) | os mesmos testes com `capture_extra` igual a 1 e os pinos de dados registrados |
| `SdramDebugPort` | [sdram_debug_port.py](../../../tests/python/unittests/ram/sdram_debug_port.py) | acessos do núcleo e do hospedeiro ao mesmo tempo, preenchimento longo e limite de espera do núcleo |
| `DataCache`, `DataCacheWriteThrough` e `AxiSdramSlave` | `data_cache.py`, `data_cache_write_through.py` e [axi_sdram_slave.py](../../../tests/python/unittests/barramento/axi_sdram_slave.py) | acessos de palavra e de linha vindos da cache e do escravo AXI, pelo mesmo subsistema |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
