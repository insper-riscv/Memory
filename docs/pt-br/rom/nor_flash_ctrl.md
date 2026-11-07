# nor_flash_ctrl

Controlador de FLASH NOR paralela de 8 bits com leitura assíncrona e em página, atrás do contrato do [flash_chip](flash_chip.md) e com os comandos K4 do [flash_cmd_port](flash_cmd_port.md).

## 1. Função do componente no SoC

O controlador é o backend `dispositivo/nor` da região FLASH. Ele atende o SoC com o contrato de handshake do `flash_chip` (pedido de uma palavra ou de uma linha de quatro palavras) e comanda os pinos de um chip NOR de barramento de 8 bits, como o S29GL064N da DE2-115: 23 bits de endereço, `CE#`, `OE#`, `WE#`, `RESET#`, `RY` e `WP#`. A leitura de uma palavra de 32 bits são quatro leituras de byte na mesma página do chip, e a de uma linha de 16 bytes são dezesseis.

Além da leitura, o controlador executa a face de comandos K4 do `flash_cmd_port` sobre o chip real: apagar um setor, gravar uma página e proteger. O dado da gravação vem do buffer de página do controlador de FLASH do Peripherals, e o pulso de invalidação no fim de cada operação liga-se às entradas de invalidação por região das caches.

| Aspecto | `flash_chip` com armazenamento | `nor_flash_ctrl` |
| :--- | :--- | :--- |
| Armazenamento | Memória de leitura registrada, fora da entidade | Chip nos pinos |
| Latência | `first_latency` e `next_latency` em bordas | Ciclos derivados dos tempos do chip e do clock |
| Escrita | Porta B do armazenamento, pelo `flash_cmd_port` | Ciclos de escrita do próprio chip, por esta entidade |

## 2. Interface

### 2.1. Generics

Os tempos são ns, e os padrões vêm de [chip_timing_pkg](chip_timing_pkg.md), com o selo `inferido` da ficha da DE2-115.

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `clk_period_ns` | `positive` | 20 | Período do clock `i_clk` |
| `margin_ns` | `natural` | 0 | Margem somada a cada tempo para o atraso de pino e de placa |
| `size_bytes` | `positive` | 8388608 | Tamanho do chip, potência de dois de 8 KB a 8 MB |
| `sector_bytes` | `positive` | 65536 | Setor de apagar e de proteger, potência de dois menor que `size_bytes` |
| `page_bytes` | `positive` | 256 | Página de gravar, potência de dois de 8 bytes até `sector_bytes` |
| `base_addr` | vetor de 32 bits | `0x20000000` | Início do chip no mapa do SoC, somado ao deslocamento na região de invalidação |
| `t_acc_ns` | `natural` | 90 | Acesso aleatório |
| `t_pacc_ns` | `natural` | 25 | Acesso dentro da página |
| `t_wc_ns` | `natural` | 90 | Ciclo de escrita |
| `t_wp_ns` | `natural` | 35 | Pulso de `WE#` |
| `t_wph_ns` | `natural` | 30 | `WE#` alto |
| `t_ds_ns` | `natural` | 45 | Dado estável antes da subida de `WE#` |
| `t_ah_ns` | `natural` | 45 | Endereço estável depois da descida de `WE#` |
| `t_busy_ns` | `natural` | 90 | Subida de `WE#` até a descida de `RY` |
| `t_rp_ns` | `natural` | 500 | Pulso de `RESET#` |
| `t_rh_ns` | `natural` | 50 | Subida de `RESET#` até o primeiro acesso |

Valores fora das faixas abortam a elaboração.

### 2.2. Portas de leitura

São as do `flash_chip`, sem as portas do armazenamento.

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | Clock do módulo |
| `i_rst` | entrada | 1 | Reset síncrono, ativo em `'1'` |
| `i_addr` | entrada | 32 | Endereço de byte do pedido |
| `i_rden` | entrada | 1 | Pedido de leitura |
| `i_line` | entrada | 1 | Linha (`'1'`) ou palavra (`'0'`) |
| `i_advance` | entrada | 1 | O pedido foi consumido neste ciclo |
| `o_ready` | saída | 1 | Pedido concluído, dado válido, mantido até `i_advance` |
| `o_busy` | saída | 1 | `'1'` em cada ciclo de espera do chip |
| `o_rdata` | saída | 32 | Palavra pedida (palavra 0 da linha) |
| `o_rdata_x` | saída | 96 | Palavras 1 a 3 da linha |

### 2.3. Portas de comando K4

São as do `flash_cmd_port`, sem as portas do armazenamento. A ocupação se chama `o_cmd_busy` para não colidir com `o_busy` da leitura.

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_cmd_valid` | entrada | 1 | Pulso de um ciclo que entrega um comando |
| `i_cmd_op` | entrada | 3 | Código do comando |
| `i_cmd_addr` | entrada | 32 | Endereço de byte do comando |
| `o_cmd_busy` | saída | 1 | Leitura, operação ou reset em andamento |
| `o_wel` | saída | 1 | O latch de escrita está armado |
| `o_refused` | saída | 1 | O último apagar ou gravar com o latch armado foi recusado |
| `o_buf_idx` | saída | $\log_2(\texttt{page\_bytes}) - 2$ | Índice da palavra do buffer de página, registrado |
| `i_buf_data` | entrada | 32 | Palavra do buffer de página, com leitura registrada |
| `o_inval_valid` | saída | 1 | Pulso de um ciclo no fim de um apagar ou gravar aceito |
| `o_inval_first` | saída | 32 | Primeiro endereço de byte da região alterada, no mapa do SoC |
| `o_inval_last` | saída | 32 | Último endereço de byte da região alterada |

### 2.4. Portas do chip

| Porta | Direção | Largura | Pino da DE2-115 |
| :--- | :--- | ---: | :--- |
| `o_fl_addr` | saída | 23 | `FL_ADDR[22:0]` |
| `o_fl_dq` | saída | 8 | `FL_DQ[7:0]`, dado a escrever |
| `o_fl_dq_oe` | saída | 1 | O controlador dirige `FL_DQ`; o topo faz o tristate |
| `i_fl_dq` | entrada | 8 | `FL_DQ[7:0]`, dado lido |
| `o_fl_ce_n` | saída | 1 | `FL_CE_N` |
| `o_fl_oe_n` | saída | 1 | `FL_OE_N` |
| `o_fl_we_n` | saída | 1 | `FL_WE_N` |
| `o_fl_rst_n` | saída | 1 | `FL_RST_N` |
| `o_fl_wp_n` | saída | 1 | `FL_WP_N`, mantido em `'1'` |
| `i_fl_ry` | entrada | 1 | `FL_RY`, assíncrono ao clock |

## 3. Comportamento

### 3.1. Número de ciclos de cada fase

Com $T$ o período, $m$ a margem e $\lceil x \rceil$ o teto com mínimo de um (`cycles_of`), as fases valem

$$ n_{first} = \left\lceil \frac{t_{acc} + m}{T} \right\rceil \qquad n_{next} = \left\lceil \frac{t_{pacc} + m}{T} \right\rceil \qquad n_{wl} = \left\lceil \frac{\max(t_{wp}, t_{ah}, t_{ds}) + m}{T} \right\rceil $$

$$ n_{wh} = \max\left( \left\lceil \frac{t_{wph} + m}{T} \right\rceil,\ \left\lceil \frac{t_{wc} + m}{T} \right\rceil - n_{wl} - 1 \right) \qquad n_{busy} = \left\lceil \frac{t_{busy} + m}{T} \right\rceil + 3 $$

Os padrões a 50 MHz dão $n_{first} = 5$, $n_{next} = 2$, $n_{wl} = 3$, $n_{wh} = 2$ e $n_{busy} = 8$.

### 3.2. Leitura

O pedido de palavra ou de linha começa quando o controlador está livre e nenhum comando chega no mesmo ciclo. O endereço alinhado a 4 bytes (palavra) ou a 16 bytes (linha) sai de um registrador junto com `CE#` e `OE#` baixos. O primeiro byte é capturado $n_{first}$ ciclos depois, e cada byte seguinte, com o endereço incrementado de um, $n_{next}$ ciclos depois do anterior, de modo que `o_busy` fica em `'1'` por

$$ T_{palavra} = n_{first} + 3\,n_{next} \qquad T_{linha} = n_{first} + 15\,n_{next} $$

ciclos. A 50 MHz isso são 11 e 35 ciclos. Os bytes ficam em ordem crescente de endereço, o byte de menor endereço nos bits mais baixos. Um pedido cujos bits 25 até o fim do tamanho do chip não são todos zero está fora da janela: devolve zero em todas as palavras sem tocar no chip.

### 3.3. Ciclo de escrita do chip

Cada ciclo de escrita tem três fases: a preparação, com endereço, dado e `CE#` já nos pinos e `OE#` alto, por um ciclo; `WE#` baixo por $n_{wl}$ ciclos; `WE#` alto por $n_{wh}$ ciclos. Os $n_{wl}$ ciclos cobrem o pulso mínimo, a retenção do endereço e, com o ciclo de preparação, o dado estável antes da subida. O ciclo inteiro, de uma descida de `WE#` à seguinte, dura $n_{wl} + n_{wh} + 1$ ciclos e cobre $t_{wc}$. O controlador dirige `FL_DQ` só nas três fases e solta o barramento antes de qualquer leitura.

### 3.4. Comandos K4

Os códigos e as regras são os do `flash_cmd_port`, e a execução no chip usa a sequência de comando em modo byte, com os endereços de desbloqueio `0xAAA` e `0x555`.

| Código | Comando | Ciclos de escrita no chip (endereço, dado) |
| :--- | :--- | :--- |
| `001` | Habilitar escrita | Nenhum; arma o latch e limpa a recusa |
| `010` | Apagar setor | `(AAA,AA)` `(555,55)` `(AAA,80)` `(AAA,AA)` `(555,55)` `(SA,30)`, com SA o início do setor |
| `011` | Gravar página | Para cada byte da página diferente de `0xFF`, em ordem de endereço: `(AAA,AA)` `(555,55)` `(AAA,A0)` `(PA,PD)` |
| `100` | Proteger | Nenhum; marca o setor no controlador |
| `101` | Desproteger | Nenhum; desmarca o setor |

Um apagar ou gravar sem o latch armado é ignorado por inteiro. Com ele armado, um endereço fora da janela ou num setor protegido é recusado: nada é escrito, o latch cai e `o_refused` sobe. Um comando só é aceito com `o_cmd_busy` baixo, e um comando que chega junto de um pedido de leitura tem prioridade, enquanto o pedido espera. A proteção é do controlador e vale para o chip todo; o pino `WP#` fica em `'1'`.

### 3.5. Gravação de página

O controlador lê a palavra de índice $k$ do buffer (`o_buf_idx` e `i_buf_data`, com leitura registrada) e grava seus quatro bytes. Um byte `0xFF` não muda o chip, porque o chip só leva bits de 1 para 0, e é pulado sem ciclo de escrita. O resultado de uma página sobre um setor já gravado é, byte a byte, o E bit a bit do conteúdo com o buffer, como no `flash_cmd_port`.

Depois do último ciclo de escrita de uma sequência o controlador espera $n_{busy}$ ciclos, que cobrem $t_{busy}$ e a sincronização de dois estágios do pino `RY`, e então espera `RY` subir. Só aí passa ao byte seguinte ou ao fim da operação.

### 3.6. Fim da operação

Ao fim de um apagar ou de uma gravação aceitos, no ciclo em que `o_cmd_busy` cai, o latch cai e `o_inval_valid` vale `'1'` por um ciclo, com a região alterada em `o_inval_first` e `o_inval_last` (o setor ou a página inteira, somada a `base_addr`).

### 3.7. Reset do chip

`i_rst` baixa `RESET#` e a espera de $\lceil (t_{rp} + m)/T \rceil$ ciclos define o pulso. O controlador só aceita pedidos $\lceil (t_{rh} + m)/T \rceil$ ciclos depois da subida. O reset também zera o latch, a recusa e a proteção.

### 3.8. Máquina de estados

| Estado | Ação | Próximo estado |
| :--- | :--- | :--- |
| `S_RST_ARM`, `S_RST_LOW`, `S_RST_HIGH` | Reset do chip: arma, `RESET#` baixo, espera depois da subida | `S_IDLE` |
| `S_IDLE` | Aceita um comando ou um pedido de leitura | `S_RD`, `S_RD_DONE` (fora da janela), `S_WSETUP` (apagar) ou `S_FETCH` (gravar) |
| `S_RD`, `S_RD_DONE` | Captura os bytes; espera o `i_advance` | `S_RD_DONE`, `S_IDLE` |
| `S_FETCH`, `S_PBYTE`, `S_NEXT` | Busca a palavra do buffer, escolhe o byte, avança | `S_WSETUP` ou `S_FIN` |
| `S_WSETUP`, `S_WLOW`, `S_WHIGH` | As três fases do ciclo de escrita | Próximo ciclo da sequência ou `S_BUSY` |
| `S_BUSY`, `S_POLL` | Espera de $t_{busy}$ e de `RY` | `S_NEXT` ou `S_FIN` |
| `S_FIN` | Pulso de invalidação, latch cai | `S_IDLE` |

Todas as esperas são contadas pela [latency_counter](../latency/latency_counter.md).

## 4. Integração

| Bloco | Relação |
| :--- | :--- |
| Topo da placa | Faz o tristate de `FL_DQ` com `o_fl_dq_oe` e liga os pinos; o controlador não cita pino nem família |
| `flash_arbiter` e `mem_region_router` | Servem os dois mestres de leitura sobre o único chip, como sobre o `flash_chip` |
| [nor_flash_model](nor_flash_model.md) | Modelo do chip nos pinos, que o banco de teste liga ao controlador |
| Controlador de FLASH do Peripherals | Entrega os comandos K4 e o buffer de página |
| `synchronizer` do Common-Components | Sincroniza `i_fl_ry`, que muda sem relação de fase com o clock |

## 5. Verificação

| Verificação | Cobertura |
| :--- | :--- |
| Entradas `NorFlashCtrl`, `NorFlashCtrl100` e `NorFlashCtrlMargin` de `tests/python/tests.json`, módulo `tests.python.unittests.rom.nor_flash_ctrl`, sobre o banco `nor_flash_ctrl_tb` | Número de ciclos de uma palavra e de uma linha segundo as fórmulas; leituras aleatórias de palavra e de linha contra uma memória de referência; leitura fora da janela; apagar de um setor sem tocar nos vizinhos; gravação de página com o E bit a bit, byte `0xFF` pulado e regravação; latch, recusa, proteção e reset; leitura pedida durante uma operação; mistura aleatória de leituras, apagares e gravações |
| Mesmas entradas | Os tempos do chip são verificados pelo [nor_flash_model](nor_flash_model.md), que falha a simulação se o controlador violar um; os três clocks (50 MHz, 100 MHz com 2 ns de margem e 40 MHz com 7 ns) passam |
| Prova formal `formal/nor_flash_ctrl/run.sh` | Ver [blocks](../formal/blocks.md): pinos, fases, sequência de comando, dado, fim da operação, leitura e comandos, em duas configurações de ciclos, com mutantes |

## 6. Referência

| Fonte | Conteúdo |
| :--- | :--- |
| `Plans/Multi-FPGA/05-FRENTES-E-TRILHAS.md`, tarefa M.5.4 | Controlador de FLASH NOR de 8 bits com leitura em página, comandos K4 e alinhamento de setor |
| `Plans/Multi-FPGA/01-ARQUITETURA.md`, seções 3 e 4 | Contrato K2 e K4, backend `dispositivo/nor` e latência $\lceil t / T \rceil$ |
| `Plans/Multi-FPGA/placas/de2-115.md`, seção 5.3 | Pinos, largura de 8 bits, 23 bits de endereço e os tempos `inferido` do S29GL064N90 |
| Datasheet Spansion S29GL064N | Sequências de comando em modo byte, página de 8 palavras, `RY` e `RESET#` (valores de memória, a conferir) |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
