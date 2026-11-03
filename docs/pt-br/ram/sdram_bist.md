# sdram_bist

## 1. Função do componente no SoC

O autoteste embutido da SDRAM escreve dados conhecidos sobre uma faixa de palavras, lê de volta e conta as palavras que diferem. Ele se liga direto à porta de requisição do controlador da SDRAM, sem core, ponte nem árbitro no caminho, e por isso valida os pinos, a fase do clock e o controlador sem depender de mais nada do sistema. O resultado sai em portas de status (fim, falha, contagem de erros e dados da primeira diferença).

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `window_log2` | natural | 16 | $\log_2$ do número de palavras da janela dos modos 0 e 1 |
| `sweep_log2` | natural | 24 | $\log_2$ do número de palavras da varredura do modo 2 (24 cobre as $2^{24}$ palavras da SDRAM) |
| `random_log2` | natural | 20 | $\log_2$ do número de palavras do modo aleatório |
| `timeout_cycles` | natural | 4096 | ciclos de espera por uma resposta do controlador antes de a execução ser declarada falha |

### 2.2. Portas

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | clock do módulo, o mesmo do controlador |
| `i_rst` | entrada | 1 | reset síncrono, ativo em `'1'` |
| `i_start` | entrada | 1 | uma borda de subida inicia uma execução |
| `i_mode` | entrada | 2 | modo da execução (seção 3.2), travado na partida |
| `i_init_done` | entrada | 1 | a inicialização da SDRAM terminou |
| `o_busy` | saída | 1 | há uma execução em andamento |
| `o_done` | saída | 1 | uma execução terminou, permanece em `'1'` até o próximo início |
| `o_fail` | saída | 1 | uma palavra diferiu ou o controlador não respondeu |
| `o_timeout` | saída | 1 | o controlador não respondeu dentro do prazo |
| `o_phase` | saída | 5 | índice da fase em andamento |
| `o_err_count` | saída | 32 | quantidade de palavras lidas que diferiram |
| `o_first_addr` | saída | 24 | endereço de palavra da primeira diferença |
| `o_first_exp` | saída | 32 | valor esperado na primeira diferença |
| `o_first_got` | saída | 32 | valor lido na primeira diferença |
| `o_ops_done` | saída | 32 | quantidade de palavras já movidas, escritas e leituras |
| `o_c_req_tog` | saída | 1 | alternância de pedido ao controlador, cada inversão é um pedido novo |
| `i_c_ack_tog` | entrada | 1 | alternância de confirmação, igual a `o_c_req_tog` quando o pedido foi atendido |
| `o_c_we` | saída | 1 | escrita (`'1'`) ou leitura (`'0'`) |
| `o_c_addr` | saída | 24 | endereço de palavra |
| `o_c_wdata` | saída | 32 | dado de escrita |
| `o_c_be` | saída | 4 | habilita de bytes da escrita |
| `i_c_rdata` | entrada | 32 | dado lido |

As portas de linha do controlador (acesso de quatro palavras) não existem neste componente, que só move palavras avulsas.

## 3. Comportamento

### 3.1. Máquina de estados

| Estado | Ação | Próximo estado |
| :--- | :--- | :--- |
| `ST_IDLE` | aguarda a borda de subida de `i_start` com `i_init_done` em `'1'`; ao aceitar, trava `i_mode`, zera o índice de fase, as contagens e os registros da primeira diferença, e limpa `o_done`, `o_fail` e `o_timeout` | `ST_PHASE` |
| `ST_PHASE` | carrega a definição da fase, zera a palavra corrente, recarrega a semente e calcula o limite $2^{n} - 1$; se a fase for o fim da lista, sobe `o_done` e baixa `o_busy` | `ST_ISSUE`, ou `ST_IDLE` no fim da lista |
| `ST_ISSUE` | calcula o endereço e registra `o_c_we`, `o_c_addr`, `o_c_be` e `o_c_wdata` (o dado esperado do padrão da fase) | `ST_TOG` |
| `ST_TOG` | inverte `o_c_req_tog` | `ST_WAIT` |
| `ST_WAIT` | espera `i_c_ack_tog` igual a `o_c_req_tog`; ao receber, conta a palavra e, numa leitura, compara `i_c_rdata` com o esperado; passa à palavra seguinte ou à próxima fase | `ST_ISSUE` ou `ST_PHASE` |

Uma borda de subida de `i_start` com `i_init_done` em `'0'` é descartada, porque a borda não é lembrada. `i_start` só é aceito em `ST_IDLE`.

Cada palavra gasta, do lado do autoteste, 2 ciclos (`ST_ISSUE` e `ST_TOG`) mais os ciclos de `ST_WAIT` até a confirmação, que dependem do controlador. Cada fase gasta mais 1 ciclo em `ST_PHASE`. As saídas do pedido são registradas e já estão estáveis um ciclo antes da inversão de `o_c_req_tog`.

Quando uma palavra lida difere, `o_err_count` aumenta e `o_fail` sobe. Os registros da primeira diferença só são gravados enquanto `o_err_count` vale zero, então guardam a primeira ocorrência da execução.

Se `i_c_ack_tog` não alcançar `o_c_req_tog` em $\text{timeout\_cycles} + 1$ ciclos de `ST_WAIT`, sobem `o_timeout` e `o_fail`, a execução termina com `o_done` em `'1'` e o estado volta a `ST_IDLE`. A alternância de pedido só volta ao valor inicial no reset.

### 3.2. Modos e fases

Cada fase é uma escrita ou uma leitura de $2^{n}$ palavras, com $n$ dado pelo generic do modo (janela, varredura ou aleatório). A tabela lista a sequência de fases de cada modo, e o total de palavras movidas é a soma dos tamanhos das fases.

| Modo | Nome | Fases (tipo, padrão, máscara de bytes) | Palavras movidas |
| ---: | :--- | :--- | :--- |
| 0 | rápido | escrita P6 `1111`; escrita P7 `0101`; leitura P8; escrita P1 `1010`; leitura P9; escrita P6 `1111`; leitura P6 | $7 \cdot 2^{\text{window\_log2}}$ |
| 1 | padrões | para cada padrão P0 a P7, uma escrita e uma leitura, máscara `1111` | $16 \cdot 2^{\text{window\_log2}}$ |
| 2 | varredura | escrita P6; leitura P6; escrita P7; leitura P7, máscara `1111` | $4 \cdot 2^{\text{sweep\_log2}}$ |
| 3 | aleatório | escrita P6 e leitura P6 em endereços pseudoaleatórios | $2 \cdot 2^{\text{random\_log2}}$ |

Os endereços dos modos 0 a 2 são a própria palavra corrente, de 0 até o limite da fase.

### 3.3. Padrões de dados

Seja $w$ o endereço de palavra de 24 bits, $h(w)$ o dado derivado do endereço e $\overline{x}$ o complemento bit a bit.

$$h(w) = \big(w_{7..0} \oplus w_{15..8} \oplus w_{23..16}\big)\ \Vert\ \big(w \oplus \texttt{5AC3A5}_{16}\big)$$

Os 24 bits baixos de $h(w)$ são uma bijeção de $w$, então o dado de uma palavra nunca se repete dentro do chip, e uma linha de endereço presa ou trocada leva o dado de uma palavra para outra, o que a leitura acusa.

| Padrão | Dado da palavra $w$ |
| ---: | :--- |
| P0 | `00000000` |
| P1 | `FFFFFFFF` |
| P2 | `AAAAAAAA` |
| P3 | `55555555` |
| P4 | um bit em `1` na posição $w_{4..0}$ (um andante) |
| P5 | complemento de P4 (um zero andante) |
| P6 | $h(w)$ |
| P7 | $\overline{h(w)}$ |
| P8 | bytes 1 e 3 de $h(w)$, bytes 0 e 2 de $\overline{h(w)}$ (o que sobra de P6 após escrever P7 com máscara `0101`) |
| P9 | bytes 1 e 3 em `FF`, bytes 0 e 2 de $\overline{h(w)}$ (o que sobra após escrever P1 com máscara `1010`) |

O modo 0 prova as máscaras de bytes porque um byte mascarado mantém o valor antigo e um byte habilitado muda.

### 3.4. Endereços aleatórios

No modo 3 o endereço é formado pelos 24 bits baixos de um gerador de 32 bits do tipo xorshift, com deslocamentos 13 à esquerda, 17 à direita e 5 à esquerda, que avança uma vez por palavra. A semente é `2545F491` em hexadecimal e é recarregada no início de cada fase, de modo que a fase de leitura percorre os mesmos endereços da fase de escrita. Como o dado depende só do endereço, um endereço repetido na sequência não gera falso erro.

## 4. Integração

| Item | Descrição |
| :--- | :--- |
| Instanciado em | `src/ram/soc/sim/sdram_bist_system.vhd`, que liga o autoteste ao controlador da SDRAM e ao modelo do chip em um único clock (a configuração de bring-up) |
| Fala com | o controlador da SDRAM (`sdram_ctrl`) pelo protocolo de alternâncias de pedido e confirmação, a mesma porta que a ponte do core usa através do árbitro |
| Não passa por | árbitro, ponte do core, mestre de depuração |

O endereço de palavra de 24 bits cobre as $2^{24}$ palavras de 32 bits da SDRAM. Os tempos do chip que o controlador respeita estão em [sdram_timings.md](sdram_timings.md), e o caminho de depuração por JTAG, que usa o mesmo chip por outra porta, está em [sdram_debug.md](sdram_debug.md).

## 5. Verificação

Os testes cocotb ficam em `tests/python/unittests/ram/sdram_bist.py` e rodam sobre o controlador real e o modelo do chip, que falha a simulação diante de qualquer regra de chip violada. Assim, uma execução aprovada prova também que o controlador obedece ao chip.

| Entrada de `tests.json` | O que muda |
| :--- | :--- |
| `SdramBist` | `CAPTURE_EXTRA` igual a 0, sem clock extra antes de amostrar o dado lido |
| `SdramBistRegisteredPins` | `CAPTURE_EXTRA` igual a 1, com um clock extra antes de amostrar o dado lido |

| Teste | Verifica |
| :--- | :--- |
| `test_quick_with_byte_masks` | o modo 0 termina sem falha e move $7 \cdot 2^{8}$ palavras |
| `test_patterns` | o modo 1 termina sem falha e move $16 \cdot 2^{8}$ palavras |
| `test_sweep` | o modo 2 termina sem falha e move $4 \cdot 2^{10}$ palavras |
| `test_random_addresses` | o modo 3 termina sem falha e move $2 \cdot 2^{8}$ palavras |
| `test_a_flipped_bit_is_found` | um bit invertido no chip entre a escrita e a leitura é reportado com o endereço e o bit exatos |

O sistema de simulação usa janela de $2^{8}$, varredura de $2^{10}$ e aleatório de $2^{8}$ palavras. Não há prova formal deste bloco, e as provas de [formal.md](../formal/formal.md) cobrem o árbitro e as pontes AXI.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
