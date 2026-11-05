# flash_arbiter

## 1. Função do componente no SoC

O chip de FLASH atende um pedido por vez. O árbitro compartilha esse chip entre dois mestres de leitura, o mestre A (lado da memória da [icache](icache.md)) e o mestre B (lado da memória de uma cache de dados). Ambos usam o contrato do chip, em que o pedido fica no barramento até `ready` e `ready` é um nível até `advance`.

## 2. Interface

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | Clock do módulo |
| `i_rst` | entrada | 1 | Reset, ativo em 1 |
| `i_a_addr` | entrada | 32 | Mestre A, endereço do pedido |
| `i_a_rden` | entrada | 1 | Mestre A, pedido de leitura |
| `i_a_line` | entrada | 1 | Mestre A, pedido de linha de quatro palavras |
| `i_a_advance` | entrada | 1 | Mestre A, o pedido foi consumido neste ciclo |
| `o_a_ready` | saída | 1 | Mestre A, pedido concluído |
| `o_a_rdata` | saída | 32 | Mestre A, palavra lida |
| `o_a_rdata_x` | saída | 96 | Mestre A, palavras 1 a 3 da linha lida |
| `i_b_addr` | entrada | 32 | Mestre B, endereço do pedido |
| `i_b_rden` | entrada | 1 | Mestre B, pedido de leitura |
| `i_b_line` | entrada | 1 | Mestre B, pedido de linha de quatro palavras |
| `i_b_advance` | entrada | 1 | Mestre B, o pedido foi consumido neste ciclo |
| `o_b_ready` | saída | 1 | Mestre B, pedido concluído |
| `o_b_rdata` | saída | 32 | Mestre B, palavra lida |
| `o_b_rdata_x` | saída | 96 | Mestre B, palavras 1 a 3 da linha lida |
| `o_addr` | saída | 32 | Chip, endereço do pedido |
| `o_rden` | saída | 1 | Chip, pedido de leitura |
| `o_line` | saída | 1 | Chip, pedido de linha |
| `o_advance` | saída | 1 | Chip, o pedido foi consumido |
| `i_ready` | entrada | 1 | Chip, pedido concluído |
| `i_rdata` | entrada | 32 | Chip, palavra lida |
| `i_rdata_x` | entrada | 96 | Chip, palavras 1 a 3 da linha lida |

O módulo não tem generics.

## 3. Comportamento

### 3.1. Concessão

A concessão é um registrador com três valores, nenhum dono, A ou B. Com o chip sem dono, a decisão segue a tabela.

| `i_a_rden` | `i_b_rden` | Último atendido | Dono seguinte |
| :--- | :--- | :--- | :--- |
| 1 | 0 | Qualquer | A |
| 0 | 1 | Qualquer | B |
| 1 | 1 | B, ou nenhum desde o reset | A |
| 1 | 1 | A | B |
| 0 | 0 | Qualquer | Nenhum |

O dono é registrado e fica com o mestre escolhido até o `advance` dele, quando o chip responde com `i_ready` em 1 no mesmo ciclo. No ciclo seguinte o chip volta a ficar sem dono, e a escolha é refeita na borda depois dele. Assim, um pedido em andamento nunca é interrompido.

### 3.2. Encaminhamento

| Sinal | Dono A | Dono B | Sem dono |
| :--- | :--- | :--- | :--- |
| `o_rden` | `i_a_rden` | `i_b_rden` | 0 |
| `o_advance` | `i_a_advance` | `i_b_advance` | 0 |
| `o_addr` e `o_line` | Os do A | Os do B | Os do B |
| `o_a_ready` | `i_ready` | 0 | 0 |
| `o_b_ready` | 0 | `i_ready` | 0 |

Os dados lidos (`i_rdata` e `i_rdata_x`) chegam aos dois mestres sem condição, mas só o dono recebe o `ready` que os valida.

### 3.3. Latência e justiça

A concessão custa um ciclo entre o primeiro `i_*_rden` visto e o dono assumir o chip, e há um ciclo sem dono entre dois pedidos consecutivos. Como o mestre que acabou de ser atendido perde o empate, nenhum mestre espera mais que um pedido do outro.

## 4. Integração

| Instância | Arquivo | Conexão |
| :--- | :--- | :--- |
| `u_arbiter` | `src/cache/SoC/sim/flash_path_system.vhd` | Mestre A ligado à saída da FLASH do roteador da icache; mestre B ligado à saída da FLASH do roteador da porta B; saída ligada ao chip `flash_chip` |

Os roteadores que alimentam o árbitro são o [mem_region_router](mem_region_router.md). O árbitro não conhece escritas, pois o roteador conclui qualquer escrita à FLASH sem repassá-la.

## 5. Verificação

Os testes são cocotb em `tests/python/unittests/cache`, registrados em `tests/python/tests.json`. Não há provas formais do árbitro da FLASH.

| Entrada de `tests.json` | Módulo de teste | O que cobre |
| :--- | :--- | :--- |
| `FlashArbiter` | [flash_arbiter.py](../../../tests/python/unittests/cache/flash_arbiter.py) | Pedidos isolados de cada mestre, A vence o primeiro empate e B segue, uma concessão nunca é cortada, B não passa fome com pedidos seguidos de A |
| `FlashPath` | [flash_path.py](../../../tests/python/unittests/cache/flash_path.py) | Dois mestres ao mesmo tempo recebem cada um o seu dado, B lê uma linha com a icache livre, a busca de instrução da FLASH de ponta a ponta |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
