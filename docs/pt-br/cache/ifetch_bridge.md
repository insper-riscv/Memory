# ifetch_bridge

## 1. Função do componente no SoC

A ponte de busca entrega ao núcleo a instrução do endereço de busca lendo-a diretamente da memória externa, para a plataforma com ROM externa e sem cache de instruções. Ela ocupa o lugar da [icache](icache.md) com o mesmo contrato no lado do núcleo e o mesmo contrato de linha no lado da memória, então a troca de uma pela outra não altera quem as liga.

Ela não é uma cache. Não há RAM de dados, vetor de tags, bit de validade por linha nem reaproveitamento por índice. Existe um único registrador de busca, que guarda a palavra pedida (ou a linha de quatro palavras que a contém, conforme o genérico `fetch_line`) e o endereço a que pertence.

| Propriedade | Valor |
| :--- | :--- |
| Armazenamento | Um registrador de busca, de uma palavra ou de uma linha de quatro palavras |
| Atende | Só o endereço de busca corrente, parado ou andando dentro da mesma linha |
| Regiões atendidas | SDRAM e FLASH, a base de cada uma acrescentada do lado da memória |
| Clock | Um só, o do núcleo |
| Pedido à memória | Palavra ou linha, com o contrato de linha da [icache](icache.md) |

O primeiro endereço fora do registrador, inclusive o alvo de um desvio, dispara um novo pedido. Os stores do núcleo não são observados, e só uma invalidação (o `fence.i` do programa) torna código escrito visível à busca.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `fetch_line` | boolean | `true` | Pede a linha de quatro palavras que contém o endereço (`true`) ou só a palavra dele (`false`) |
| `base_sdram` | vetor de 6 bits | `010000` | Bits 31 a 26 acrescentados aos endereços da SDRAM no lado da memória (0x40000000) |
| `base_flash` | vetor de 6 bits | `001000` | Bits 31 a 26 acrescentados aos endereços da FLASH no lado da memória (0x20000000) |
| `rom_base_kib` | natural | 524288 | Base da região da ROM em KiB; o que cai nela é tratado como FLASH |
| `rom_end_kib` | natural | 1048576 | Fim exclusivo da região da ROM em KiB |

### 2.2. Portas

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | Clock do núcleo; o do registrador de busca e da máquina de estados |
| `i_rst` | entrada | 1 | Reset, ativo em 1; descarta o registrador de busca |
| `i_addr` | entrada | 32 | Endereço de busca (o PC) |
| `i_sel` | entrada | 1 | O endereço de busca pertence à SDRAM ou à FLASH |
| `o_ready` | saída | 1 | A instrução em `o_data` é a do endereço atual |
| `o_data` | saída | 32 | Instrução buscada |
| `i_invalidate` | entrada | 1 | Pulso que descarta o registrador de busca (padrão 0) |
| `o_miss` | saída | 1 | Pulso de um ciclo depois do início de cada pedido à memória |
| `o_d_addr` | saída | 32 | Endereço do pedido, com a base da região nos bits 31 a 26 |
| `o_d_rden` | saída | 1 | Pedido de leitura |
| `o_d_line` | saída | 1 | O pedido é de uma linha de quatro palavras |
| `o_d_advance` | saída | 1 | Igual a `i_d_ready` |
| `i_d_ready` | entrada | 1 | Pedido concluído |
| `i_d_rdata` | entrada | 32 | Palavra 0 do dado lido |
| `i_d_rdata_x` | entrada | 96 | Palavras 1 a 3 da linha lida (padrão zeros) |

## 3. Comportamento

### 3.1. Contrato do lado do núcleo

O estágio de busca do núcleo não avança o PC enquanto a ponte não indica que a instrução é a do endereço corrente. A ponte compara o endereço de busca com o do registrador, de modo que `o_ready` obedece à equação abaixo, com $L = 4$ para `fetch_line` verdadeiro e $L = 2$ para falso.

$$
\text{o\_ready} = \text{ok} \wedge \text{i\_sel} \wedge (\text{i\_addr}_{31:L} = \text{fetch\_addr}_{31:L})
$$

Como a comparação é combinacional sobre `i_addr`, `o_ready` cai no mesmo ciclo em que o PC sai da linha, e o núcleo nunca recebe a instrução do endereço anterior. Com `fetch_line` verdadeiro, `o_data` é a palavra de índice `i_addr(3:2)` da linha guardada.

A icache lê as RAMs no clock adiantado das memórias de instrução e por isso compara o endereço registrado nesse clock. A ponte guarda o registrador no clock do núcleo, então o dado já está estável quando o núcleo o amostra e nenhum clock adiantado é necessário.

### 3.2. Máquina de estados

A máquina roda em `i_clk`.

| Estado | Função |
| :--- | :--- |
| `S_IDLE` | Se `i_sel` vale 1, o registrador não contém o endereço de busca e `i_invalidate` vale 0, registra o endereço pendente, monta o pedido e passa a `S_WAIT` |
| `S_WAIT` | Mantém o pedido até `i_d_ready`; então baixa `o_d_rden` e `o_d_line`, grava o registrador de busca e volta a `S_IDLE` |

O endereço do pedido é a base da região (`base_flash` quando o endereço está em $[\texttt{rom\_base\_kib}, \texttt{rom\_end\_kib})$ KiB, `base_sdram` caso contrário) seguida dos bits 25 a 0 do endereço, com os bits abaixo do alinhamento zerados (16 bytes com `fetch_line` verdadeiro, 4 bytes com falso). O pedido fica estável até `i_d_ready`, que o chip mantém em nível até `o_d_advance`.

Um pedido em andamento não pode ser abortado, porque o chip termina a espera e só então aceita outro. Um desvio durante a espera paga o resto dela, grava a palavra do endereço antigo, que deixa de coincidir com o PC, e só então pede o endereço novo.

### 3.3. Latência

Seja $F$ o `first_latency` do chip e $N$ o `next_latency`. As bordas por linha de quatro instruções incluem a borda em que o núcleo consome cada instrução.

| Caso | Bordas até `o_ready` para a primeira instrução | Bordas por linha de quatro instruções |
| :--- | ---: | ---: |
| Palavra (`fetch_line` falso) | $F + 4$ | $4(F + 5)$ |
| Linha (`fetch_line` verdadeiro) | $F + 3N + 4$ | $F + 3N + 8$ |

Com $F = 24$ e $N = 4$ (o padrão do chip de FLASH), as simulações do caminho completo medem o seguinte para código sequencial.

| `fetch_line` | Bordas por instrução | Bordas por linha de quatro instruções |
| :--- | ---: | ---: |
| falso | 29 | 116 |
| verdadeiro | 11 | 44 |

As instruções seguintes da linha guardada têm `o_ready` em 1 sem espera. Um desvio a um endereço fora do registrador custa a latência inteira do pedido de volta.

### 3.4. Invalidação

Um pulso em `i_invalidate` descarta o registrador no mesmo ciclo. Se há um pedido em andamento, ele é concluído e a palavra que chega é descartada, de modo que nada guardado é mais antigo que a última invalidação. A marca de descarte é limpa quando a máquina volta a `S_IDLE`.

### 3.5. Reset

`i_rst` leva a máquina a `S_IDLE` e descarta o registrador de busca, a marca de descarte e os sinais de pedido.

## 4. Integração

| Instância | Arquivo | Conexão |
| :--- | :--- | :--- |
| `BRIDGE` | `src/cache/SoC/sim/ifetch_path_system.vhd` | `i_clk` no clock do núcleo; lado da memória ligado a um [mem_region_router](mem_region_router.md), cuja saída da FLASH vai ao mestre A do [flash_arbiter](flash_arbiter.md) |

O pedido da ponte é de leitura, de palavra ou de linha. No sistema de simulação, a saída da SDRAM do roteador da ponte não tem escravo.

## 5. Verificação

Os testes são cocotb em `tests/python/unittests/cache`, registrados em `tests/python/tests.json`. Não há provas formais da ponte, porque a icache também não as tem.

| Entrada de `tests.json` | Módulo de teste | O que cobre |
| :--- | :--- | :--- |
| `IfetchBridge` | [ifetch_bridge.py](../../../tests/python/unittests/cache/ifetch_bridge.py) | Falta seguida de palavras da linha sem espera, código sequencial entre linhas, `o_ready` cai com o endereço, endereço parado sem novo pedido, desvios, base da região no pedido, endereço não selecionado, invalidação e invalidação durante um pedido, desvio durante um pedido, um pulso de falta por pedido, reset |
| `IfetchBridgeWord` | [ifetch_bridge_word.py](../../../tests/python/unittests/cache/ifetch_bridge_word.py) | `fetch_line` falso, um pedido de palavra por instrução, palavra parada sem novo pedido |
| `IfetchPath` | [ifetch_path.py](../../../tests/python/unittests/cache/ifetch_path.py) | Busca da FLASH de ponta a ponta com a ponte, dois roteadores, o árbitro e o chip de 24 bordas, bordas por instrução, desvios, espera com `o_ready` baixo, `fence.i` e `fence.i` durante a espera, o mestre de dados compartilhando o chip, endereço da SDRAM fora do chip |
| `IfetchPathWord` | [ifetch_path_word.py](../../../tests/python/unittests/cache/ifetch_path_word.py) | O mesmo caminho com `fetch_line` falso e as bordas por instrução |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
