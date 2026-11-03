# flash_chip

Modelo da FLASH externa como o SoC a enxerga: um chip somente leitura que atende pedidos de uma palavra ou de uma linha de quatro palavras, com latência configurável. O armazenamento fica fora da entidade.

## 1. Função do componente no SoC

A FLASH ocupa a região que começa em `0x20000000` quando a ROM é externa ao núcleo (mapa em [02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md)). A cache de instruções e a cache de dados chegam a ela por um roteador de região e por um árbitro, e o chip responde com o mesmo contrato de handshake que a ponte da SDRAM dá ao núcleo.

### 1.1. Contrato de handshake

1. O pedido fica estável em `i_addr`, `i_rden` e `i_line` até `o_ready` subir.
2. `o_ready` permanece em nível alto até `i_advance` indicar que o pedido foi consumido.
3. O dado lido só muda no pedido seguinte.

### 1.2. Tipos de pedido

| `i_line` | Pedido | Endereço usado | Palavras devolvidas |
| :--- | :--- | :--- | :--- |
| `'1'` | Linha | Início da linha de 16 bytes que contém `i_addr` | Quatro, a palavra 0 em `o_rdata` e as palavras 1 a 3 em `o_rdata_x` |
| `'0'` | Palavra | `i_addr` alinhado a 4 bytes | Uma, em `o_rdata` |

Stores não chegam ao chip, porque a FLASH ignora escritas do núcleo.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `first_latency` | `natural` | 24 | Bordas de `i_clk` até a primeira palavra estar capturada. Mínimo 2; o contador interno vai de 0 a 255 |
| `next_latency` | `natural` | 4 | Bordas entre uma palavra e a seguinte da mesma linha. Mínimo 2; mesmo limite de 255 |
| `size_bytes` | `positive` | 1048576 | Tamanho do chip em bytes, potência de dois de 16 bytes a 32 MB. Outro valor aborta a elaboração |

### 2.2. Portas

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | Clock do módulo, o mesmo da memória de armazenamento |
| `i_rst` | entrada | 1 | Reset síncrono, ativo em `'1'` |
| `i_addr` | entrada | 32 | Endereço de byte do pedido |
| `i_rden` | entrada | 1 | Pedido de leitura |
| `i_line` | entrada | 1 | Seleciona linha (`'1'`) ou palavra (`'0'`) |
| `i_advance` | entrada | 1 | O pedido foi consumido neste ciclo e o chip pode aceitar outro |
| `o_ready` | saída | 1 | Pedido concluído, dado válido |
| `o_busy` | saída | 1 | `'1'` em cada ciclo de espera por uma palavra |
| `o_rdata` | saída | 32 | Palavra pedida (palavra 0 da linha) |
| `o_rdata_x` | saída | 96 | Palavras 1 a 3 da linha, a palavra 1 nos bits mais baixos |
| `o_mem_addr` | saída | 32 | Endereço de byte entregue ao armazenamento, vindo de um registrador |
| `i_mem_data` | entrada | 32 | Palavra lida do armazenamento, com leitura registrada |

## 3. Comportamento

### 3.1. Máquina de estados

| Estado | Condição de permanência | Ação | Próximo estado |
| :--- | :--- | :--- | :--- |
| `S_IDLE` | `i_rden = '0'` | Nenhuma | `S_WAIT` quando `i_rden = '1'`; antes registra a base, o fim de linha, a marca de fora da janela e o endereço em `o_mem_addr` |
| `S_WAIT` | O contador de bordas ainda não chegou a 1 | Decrementa o contador | `S_DONE` ao capturar a última palavra do pedido |
| `S_DONE` | `i_advance = '0'` | `o_ready = '1'` | `S_IDLE` quando `i_advance = '1'` |

`o_busy` vale `'1'` em `S_WAIT` e `o_ready` vale `'1'` em `S_DONE`. O reset leva a `S_IDLE`. Cada captura grava a palavra em `o_rdata` (palavra 0) ou em uma fatia de 32 bits de `o_rdata_x`; depois da captura de uma palavra que não é a última, o endereço registrado avança 4 bytes e o contador é recarregado com `next_latency`. Um pedido de palavra não altera `o_rdata_x`.

### 3.2. Latência

O endereço é registrado numa borda e a memória de armazenamento só responde na seguinte, por isso os dois generics valem pelo menos 2. Com $L_1$ a `first_latency` e $L_n$ a `next_latency`, o número de ciclos em que `o_busy` fica alto é:

$$
T_{palavra} = L_1 \qquad T_{linha} = L_1 + 3\,L_n
$$

`o_ready` sobe no ciclo seguinte ao da última captura.

### 3.3. Janela do chip

O chip ocupa $2^{W}$ bytes com $W = \log_2(\text{size\_bytes})$. Um pedido cujos bits do endereço de $W$ até 25 não são todos zero está fora da janela. Os bits 31 a 26 não entram na checagem. Um pedido fora da janela percorre a mesma latência e captura zero em todas as palavras, sem depender do conteúdo do armazenamento.

## 4. Integração

| Bloco | Relação com o chip |
| :--- | :--- |
| `icache` e `dcache` (`src/cache/`) | Mestres de linha; ver [dcache_axi.md](../barramento/dcache_axi.md) para a cache de dados |
| `mem_region_router` | Separa o pedido entre SDRAM e FLASH, conclui stores à FLASH sem efeito e devolve zero para leituras além da janela sem acordar o chip |
| `flash_arbiter` | Serializa os dois mestres sobre o único chip; um pedido em andamento nunca é interrompido |
| Armazenamento | Memória de leitura registrada comandada por `o_mem_addr` e `i_mem_data`. Na placa é o IP [flash_store1port](flash_store1port.md); na simulação modular é o modelo [rom_simulation](rom_simulation.md) |

O topo da placa DE0-CV, na Insper-RISC-V, instancia o chip com latências 24 e 4 e `size_bytes` de 262144, ligado ao IP de armazenamento de 256 KB pelos bits 17 a 2 de `o_mem_addr`. O topo de simulação modular da Insper-RISC-V o instancia com latências e tamanho vindos de genéricos. Nos dois casos o clock do chip e o do armazenamento são o mesmo.

## 5. Verificação

| Entrada de `tests/python/tests.json` | Módulo cocotb | O que cobre |
| :--- | :--- | :--- |
| `FlashChip` | `tests.python.unittests.external.flash_chip` | Linha inteira e alinhada, palavra única, latência segundo os generics, `o_ready` mantido até `i_advance`, pedidos em sequência, pedido fora da janela de 1 MB lendo zero e `o_busy` cobrindo $L_1 + 3\,L_n$ ciclos |
| `FlashPath` | `tests.python.unittests.external.flash_path` | Cache de instruções, roteadores, árbitro e chip juntos, incluindo store à FLASH que nunca chega ao chip e leitura além da janela que não o acorda |
| `FlashArbiter` | `tests.python.unittests.external.flash_arbiter` | O árbitro à frente do chip |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
