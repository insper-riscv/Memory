# flash_cmd_port

Porta B do modelo de chip de FLASH: executa os comandos de programação de um chip real (habilitar escrita, apagar setor, gravar página, proteger) sobre o armazenamento de duas portas, enquanto a porta A ([flash_chip](flash_chip.md)) segue servindo leituras.

## 1. Função do componente no SoC

Uma FLASH real não aceita um store: o conteúdo muda por comandos que apagam um setor inteiro para 1 e gravam uma página levando bits de 1 para 0. O `flash_cmd_port` reproduz essas regras para que o software de atualização de programa seja testado contra um chip que as impõe. O comando chega do controlador de FLASH (repositório Peripherals), o dado da gravação vem do buffer de página do controlador, e o resultado é escrito na porta B do armazenamento, o IP [flash](flash.md) ou o modelo [flash_simulation](flash_simulation.md).

| Porta do modelo | Quem usa | Função |
| :--- | :--- | :--- |
| A (leitura) | Pedidos de linha das caches, pelo [flash_chip](flash_chip.md) | Busca de instruções e leitura de dados |
| B (programação) | O controlador de FLASH, por esta entidade | Apagar, gravar e proteger |

A leitura continua enquanto a porta B escreve. Uma leitura de uma região em programação devolve o conteúdo atual do armazenamento, palavra por palavra, de modo que uma palavra lida é sempre o valor antigo ou o novo, nunca uma mistura.

### 1.1. Comandos

| Código | Comando | Exige o latch | Efeito |
| :--- | :--- | :--- | :--- |
| `001` | Habilitar escrita | Não | Arma o latch de escrita e limpa a recusa |
| `010` | Apagar setor | Sim | Põe todos os bits do setor que contém o endereço em 1 |
| `011` | Gravar página | Sim | Para cada palavra da página, grava o E bit a bit do conteúdo atual com a palavra do buffer de página |
| `100` | Proteger | Não | Marca o setor que contém o endereço; apagar e gravar nele passam a ser recusados |
| `101` | Desproteger | Não | Desmarca o setor |
| outros | Reservados | Não | Ignorados |

### 1.2. Regras que o modelo impõe

1. Um apagar ou gravar sem o latch armado é ignorado por inteiro: não ocupa o chip, não escreve e não altera a recusa.
2. Com o latch armado, um endereço fora da janela ou num setor protegido é recusado: nada é escrito, o latch cai e `o_refused` sobe.
3. Um comando aceito mantém `o_busy` em nível alto até a última palavra estar escrita. O latch cai e sai o pulso de invalidação no mesmo ciclo em que `o_busy` cai.
4. Um comando que chega com `o_busy` em nível alto é ignorado, qualquer que seja o código.
5. Gravar sobre um bit em 0 não o leva a 1; só um apagar do setor faz isso.
6. O reset zera o latch, a recusa e a proteção.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `size_bytes` | `positive` | 1048576 | Tamanho do chip em bytes, potência de dois maior que `sector_bytes` e de até 32 MB |
| `sector_bytes` | `positive` | 4096 | Tamanho do setor de apagar e de proteger, potência de dois |
| `page_bytes` | `positive` | 256 | Tamanho da página de gravar, potência de dois de 8 bytes até `sector_bytes` |
| `base_addr` | vetor de 32 bits | `0x20000000` | Endereço do início do chip no mapa do SoC, somado ao deslocamento na região de invalidação |
| `erase_latency` | `natural` | 2000 | Bordas de espera de um apagar antes da varredura do setor |
| `program_latency` | `natural` | 200 | Bordas de espera de uma gravação antes da varredura da página |

Valores fora das faixas abortam a elaboração.

### 2.2. Portas

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | Clock do módulo, o mesmo da memória de armazenamento |
| `i_rst` | entrada | 1 | Reset síncrono, ativo em `'1'` |
| `i_cmd_valid` | entrada | 1 | Pulso de um ciclo que entrega um comando |
| `i_cmd_op` | entrada | 3 | Código do comando (seção 1.1) |
| `i_cmd_addr` | entrada | 32 | Endereço de byte do comando |
| `o_busy` | saída | 1 | Um apagar ou uma gravação está em andamento |
| `o_wel` | saída | 1 | O latch de escrita está armado |
| `o_refused` | saída | 1 | O último apagar ou gravar com o latch armado foi recusado; cai no próximo habilitar escrita |
| `o_buf_idx` | saída | $\log_2(\texttt{page\_bytes}) - 2$ | Índice da palavra do buffer de página lida pela gravação, registrado |
| `i_buf_data` | entrada | 32 | Palavra do buffer de página, com leitura registrada |
| `o_mem_addr` | saída | 32 | Endereço de byte entregue à porta B do armazenamento, registrado |
| `o_mem_we` | saída | 1 | Habilita de escrita da porta B do armazenamento |
| `o_mem_wdata` | saída | 32 | Palavra a escrever na porta B do armazenamento |
| `i_mem_data` | entrada | 32 | Palavra lida da porta B do armazenamento, com leitura registrada |
| `o_inval_valid` | saída | 1 | Pulso de um ciclo no fim de um apagar ou gravar aceito |
| `o_inval_first` | saída | 32 | Primeiro endereço de byte da região alterada, no mapa do SoC |
| `o_inval_last` | saída | 32 | Último endereço de byte da região alterada |

## 3. Comportamento

### 3.1. Endereços e janela

O chip ocupa $2^{W}$ bytes com $W = \log_2(\texttt{size\_bytes})$. Um endereço cujos bits de $W$ até 25 não são todos zero está fora da janela, como no [flash_chip](flash_chip.md); os bits 31 a 26 não entram na checagem. Os bits abaixo do tamanho do setor (apagar e proteger) ou da página (gravar) são ignorados, de modo que o comando age sobre o setor ou a página que contém o endereço.

### 3.2. Máquina de estados

| Estado | Ação | Próximo estado |
| :--- | :--- | :--- |
| `S_IDLE` | Aceita um comando em `i_cmd_valid` | `S_WAIT` num apagar ou gravar aceito; fica em `S_IDLE` nos demais casos |
| `S_WAIT` | Conta a espera inicial (`erase_latency` ou `program_latency`) | `S_RUN` quando o contador chega a zero; registra o endereço do início da região |
| `S_RUN` | Varre as palavras da região em três fases por palavra | `S_IDLE` depois da escrita da última palavra |

`o_busy` vale `'1'` fora de `S_IDLE`.

### 3.3. Varredura de uma palavra

A memória de armazenamento e o buffer de página têm leitura registrada, então o endereço emitido numa borda só rende dado duas bordas depois. Cada palavra leva três bordas.

| Fase | O que acontece |
| :--- | :--- |
| 0 | `o_mem_addr` e `o_buf_idx` mostram a palavra; a memória e o buffer capturam o endereço |
| 1 | `i_mem_data` e `i_buf_data` são válidos; o módulo registra a palavra nova e levanta `o_mem_we` |
| 2 | A memória escreve; o módulo baixa `o_mem_we` e emite o endereço da palavra seguinte, ou termina |

A palavra nova é $\texttt{0xFFFFFFFF}$ num apagar e $\texttt{i\_mem\_data} \wedge \texttt{i\_buf\_data}$ numa gravação. A última escrita acontece na mesma borda em que `o_busy` cai.

### 3.4. Latência

Com $L_e$ a `erase_latency`, $L_p$ a `program_latency`, $S$ o tamanho do setor e $P$ o da página, o número de ciclos em que `o_busy` fica alto é:

$$
T_{apagar} = L_e + 1 + 3\,\frac{S}{4} \qquad T_{gravar} = L_p + 1 + 3\,\frac{P}{4}
$$

### 3.5. Pulso de invalidação

No ciclo em que `o_busy` cai, `o_inval_valid` vale `'1'` por um ciclo, com a região alterada em `o_inval_first` e `o_inval_last` (o setor ou a página inteira, somada a `base_addr`). O pulso liga-se às entradas de invalidação por região das caches (ver [icache](../cache/icache.md) e [dcache](../cache/dcache.md)). Um comando ignorado ou recusado não gera pulso.

## 4. Integração

O sistema `flash_dual_system` (`src/cache/SoC/sim/`) liga o [flash_chip](flash_chip.md), esta entidade e o modelo [flash_simulation](flash_simulation.md) como no topo da FPGA, com um buffer de página de leitura registrada que faz o papel do buffer do controlador. A porta A do armazenamento atende o chip de leitura pelo endereço de palavra `o_mem_addr(W-1 downto 2)`, e a porta B atende esta entidade do mesmo modo.

## 5. Verificação

| Entrada de `tests/python/tests.json` | Módulo cocotb | O que cobre |
| :--- | :--- | :--- |
| `FlashCmdPort` | `tests.python.unittests.cache.flash_cmd_port` | Apagar põe só o setor em 1; gravar faz o E bit a bit e não leva bit a 1 sem apagar; comando sem latch é ignorado; o latch cai com a operação; setor protegido recusa e desproteger libera; endereço fora da janela recusa; duração de `o_busy` segundo os generics; comandos ignorados com o chip ocupado; região e instante do pulso; reset |
| `FlashDual` | `tests.python.unittests.cache.flash_dual` | A porta A lê o conteúdo programado pela porta B; as leituras seguem durante um apagar de outro setor; uma palavra lida durante o apagar é inteira, antiga ou nova; região do pulso no sistema |

A prova formal está em `formal/flash_cmd_port/` (ver [blocks](../formal/blocks.md)), com um chip de 64 bytes, setores de 16 bytes e páginas de 8 bytes, e doze mutantes do VHDL.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
