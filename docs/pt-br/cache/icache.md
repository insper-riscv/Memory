# icache

## 1. Função do componente no SoC

A icache é a cache de instruções do core, somente leitura. Fica no caminho de busca dos endereços da SDRAM e da FLASH. A ROM de boot não passa por ela. Quando a instrução do endereço de busca não está guardada, a cache segura o core esperando (sem `o_ready`) e traz a linha de quatro palavras da memória.

| Propriedade | Valor |
| :--- | :--- |
| Organização | Mapeamento direto, linhas de 16 bytes (quatro palavras), somente leitura |
| Tamanho | Genérico `size_bits` (4 KB e 256 linhas por padrão) |
| Regiões atendidas | SDRAM e FLASH, distinguidas por um bit da tag |
| Clocks | Dois, o das memórias de instrução (`i_clk`) e o do core (`i_clk_cpu`) |
| Leitura das RAMs | Registrada, como nas RAMs de bloco da FPGA |

Na plataforma sem cache de instruções, a [ifetch_bridge](ifetch_bridge.md) ocupa o lugar dela com o mesmo contrato.

Os stores do core não são observados pela cache. Só uma invalidação (o `fence.i` do programa) torna código escrito visível à busca. A porta de debug da SDRAM escreve com o core parado e a cache invalidada, como depois do reset.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `size_bits` | positive | 32768 | Tamanho da cache em bits, potência de dois de pelo menos 256 (duas linhas). 32768 é 4 KB e 4096 é 4 kbit |
| `base_sdram` | vetor de 6 bits | `010000` | Bits 31 a 26 acrescentados aos endereços da SDRAM no lado da memória (0x40000000) |
| `base_flash` | vetor de 6 bits | `001000` | Bits 31 a 26 acrescentados aos endereços da FLASH no lado da memória (0x20000000) |
| `rom_base_kib` | natural | 524288 | Base da região da ROM em KiB; o que cai nela é tratado como FLASH (0x20000000) |
| `rom_end_kib` | natural | 1048576 | Fim exclusivo da região da ROM em KiB (0x40000000) |

### 2.2. Portas

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | Clock das memórias de instrução; lê as RAMs e registra o endereço de busca |
| `i_clk_cpu` | entrada | 1 | Clock da máquina de estados, do vetor de validade e do reset (o clock do core) |
| `i_rst` | entrada | 1 | Reset, ativo em 1; invalida todas as linhas |
| `i_addr` | entrada | 32 | Endereço de busca (o PC) |
| `i_sel` | entrada | 1 | O endereço de busca pertence à SDRAM ou à FLASH |
| `o_ready` | saída | 1 | A instrução em `o_data` é a do endereço atual |
| `o_data` | saída | 32 | Instrução buscada |
| `i_invalidate` | entrada | 1 | Pulso que derruba todas as linhas (padrão 0) |
| `o_miss` | saída | 1 | Pulso de um ciclo no início de cada preenchimento de linha |
| `i_inval_region` | entrada | 1 | Pulso que derruba as linhas da região de `i_inval_first` a `i_inval_last` (padrão 0) |
| `i_inval_first` | entrada | 32 | Primeiro endereço de byte da região a derrubar (padrão 0) |
| `i_inval_last` | entrada | 32 | Último endereço de byte da região a derrubar, incluído (padrão 0) |
| `o_d_addr` | saída | 32 | Endereço do pedido de linha, com a base da região nos bits 31 a 26 |
| `o_d_rden` | saída | 1 | Pedido de leitura |
| `o_d_line` | saída | 1 | O pedido é de uma linha de quatro palavras |
| `o_d_advance` | saída | 1 | Igual a `i_d_ready` |
| `i_d_ready` | entrada | 1 | Pedido concluído |
| `i_d_rdata` | entrada | 32 | Palavra 0 da linha lida |
| `i_d_rdata_x` | entrada | 96 | Palavras 1 a 3 da linha lida (padrão zeros) |

## 3. Comportamento

### 3.1. Divisão do endereço

Com $I = \log_2(\texttt{size\_bits}) - 7$ bits de índice, a cache tem $2^I$ linhas.

| Campo | Bits do endereço | Largura |
| :--- | :--- | ---: |
| Palavra na linha | 3 a 2 | 2 |
| Índice | $I+3$ a 4 | $I$ |
| Tag | 25 a $I+4$ | $22-I$ |
| Região | Calculada a partir de `rom_base_kib` e `rom_end_kib`; vira o bit mais significativo da tag | 1 |

$$
\text{TAG\_BITS} = 23 - I
$$

O bit de região na tag impede que uma linha da FLASH e uma da SDRAM com os mesmos bits 25 a $I+4$ se confundam. Os bits 31 a 26 não são guardados e o pedido ao lado da memória os reconstrói com `base_flash` ou `base_sdram`, conforme o bit de região da linha em preenchimento.

### 3.2. Consulta e contrato do lado do core

As RAMs de dados, de tags e o vetor de validade são lidos em `i_clk` com o endereço de `i_addr`, e o endereço e `i_sel` são registrados na mesma borda. Depois dessa borda, a instrução do endereço registrado está em `o_data`, e `o_ready` indica que ela é a certa.

$$
\text{o\_ready} = \text{sel\_q} \wedge \text{valid\_rd} \wedge (\text{tag\_rd} = \text{tag}(\text{addr\_q})) \wedge (\text{addr\_q} = \text{i\_addr})
$$

O último termo faz `o_ready` cair se `i_addr` mudou desde a borda. O core amostra `o_ready` e `o_data` na sua própria borda, uma fração de clock depois de `i_clk`, e enquanto `o_ready` está em 0 mantém o endereço estável. Um acerto, portanto, tem `o_ready` em 1 no ciclo seguinte à borda que registrou o endereço.

### 3.3. Máquina de estados

A máquina roda em `i_clk_cpu`.

| Estado | Função | Saída |
| :--- | :--- | :--- |
| `S_IDLE` | Espera uma falha. Se `i_sel` registrado está em 1, não há acerto, o endereço registrado é igual a `i_addr` e `i_invalidate` está em 0, registra a tag e o índice da linha e passa a `S_FILL_REQ` | |
| `S_FILL_REQ` | Monta o pedido de linha com o endereço $\text{base} \,\Vert\, \text{tag} \,\Vert\, \text{índice} \,\Vert\, 0000_2$ e levanta `o_d_rden` e `o_d_line` | `o_miss` em 1 |
| `S_FILL_WAIT` | Espera `i_d_ready`, então baixa o pedido | |
| `S_FILL_GET` | Grava uma palavra por ciclo nas RAMs de dados (palavras 0 a 3); na palavra 3 grava a tag e marca a linha como válida | |
| `S_SETTLE` | Um ciclo para a leitura registrada ver a tag e a validade novas | |

Durante o preenchimento, `i_addr` pode mudar (um desvio moveu o PC). A linha continua sendo trazida para o índice registrado no início.

### 3.4. Latência

Seja $k$ o número de ciclos de `S_FILL_WAIT` ($k \ge 1$) e supondo `i_clk` igual a `i_clk_cpu`. Uma falha é detectada em `S_IDLE`, no ciclo seguinte à borda que registrou o endereço, e gasta $1 + k + 4 + 1$ ciclos de `S_FILL_REQ` a `S_SETTLE`. Com o ciclo de detecção, a falha custa $7 + k$ ciclos a mais que um acerto, e a consulta seguinte acerta.

| Caso | Ciclos além do acerto |
| :--- | ---: |
| Acerto | 0 |
| Falha | $7 + k$ |

### 3.5. Invalidação

Um pulso em `i_invalidate` zera o vetor de validade em um ciclo de `i_clk_cpu`. Se a máquina não está em `S_IDLE`, o pulso também marca o preenchimento em andamento para descarte. Ao fim do preenchimento (palavra 3), a linha só é marcada como válida se não houve descarte e `i_invalidate` está em 0 naquele ciclo. Assim, nenhuma linha guardada é mais antiga que a última invalidação. A marca de descarte é limpa quando a máquina volta a `S_IDLE`.

### 3.6. Invalidação por região

Um pulso em `i_inval_region` derruba as linhas dos endereços de `i_inval_first` a `i_inval_last`, que é o que o controlador de FLASH pede ao fim de um apagar ou gravar. A cache guarda a tag, não o endereço completo, então derruba por índice: toda linha cujo índice contém algum endereço da região, inclusive a de outra região com o mesmo índice. Com $N$ linhas na região e $L$ linhas na cache, a região derruba as linhas de índice $i$ tais que

$$
(i - i_{primeira}) \bmod L < N \qquad \text{ou} \qquad N \ge L
$$

em que $i_{primeira}$ é o índice do endereço `i_inval_first`. Uma região com `i_inval_last` menor que `i_inval_first` não tem efeito.

O pedido é registrado e aplicado no ciclo seguinte. Se a máquina não está em `S_IDLE` e a linha em preenchimento cai na região, o preenchimento é descartado como no `i_invalidate`. Como o bit de validade lido tem um ciclo de atraso, nenhuma linha da região acerta a partir do quarto ciclo depois do pulso.

### 3.7. Reset

`i_rst` leva a máquina a `S_IDLE`, zera o vetor de validade, a marca de descarte, os sinais de pedido e o contador de palavras.

## 4. Integração

| Instância | Arquivo | Conexão |
| :--- | :--- | :--- |
| `u_icache` | `src/cache/SoC/sim/flash_path_system.vhd` | `i_clk` e `i_clk_cpu` ligados ao mesmo clock; lado da memória ligado a um [mem_region_router](mem_region_router.md), cuja saída da FLASH vai ao mestre A do [flash_arbiter](flash_arbiter.md) |

O pedido da icache só é de leitura de linha. No sistema de simulação, a saída da SDRAM do roteador da icache não tem escravo.

## 5. Verificação

Os testes são cocotb em `tests/python/unittests/cache`, registrados em `tests/python/tests.json`. A prova formal está em `formal/icache/` (ver [blocks](../formal/blocks.md)).

| Entrada de `tests.json` | Módulo de teste | O que cobre |
| :--- | :--- | :--- |
| `InstructionCache` | [instruction_cache.py](../../../tests/python/unittests/cache/instruction_cache.py) | Falha seguida de acertos na linha, código sequencial entre linhas, conflito que expulsa a linha, endereço não selecionado nunca acerta nem preenche, invalidação de todas as linhas e durante um preenchimento, troca de endereço durante um preenchimento, regiões sem alias, base da região nos endereços de preenchimento, um pulso de falha por linha, invalidação por região (só a linha da região, várias linhas, volta do índice, região do tamanho da cache, região invertida, durante um preenchimento dentro e fora da região) |
| `InstructionCacheSmall` | [instruction_cache_small.py](../../../tests/python/unittests/cache/instruction_cache_small.py) | `size_bits` igual a 4096, capacidade de 32 linhas, a linha 33 toma o lugar da primeira, conflito a 512 bytes, FLASH e SDRAM no mesmo índice em conflito |
| `FlashPath` | [flash_path.py](../../../tests/python/unittests/cache/flash_path.py) | Busca de instrução da FLASH de ponta a ponta, com a icache, dois roteadores, o árbitro e o chip |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
