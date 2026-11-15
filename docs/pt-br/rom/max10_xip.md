# max10_xip

Adaptador de leitura direta (XIP) da flash interna do MAX 10 da DE10-Lite, atrás do contrato do [flash_chip](flash_chip.md), só para instruções.

## 1. Função do componente no SoC

O [max10_flash](max10_flash.md) entrega a flash interna ao software como um banco de registradores, sem leitura direta de linha. O `max10_xip` entrega ao SoC o contrato de handshake do `flash_chip`, o mesmo do [nor_flash_ctrl](nor_flash_ctrl.md): um pedido de uma palavra ou de uma linha de quatro palavras, com `o_ready` mantido até `i_advance`. Cada pedido vira leituras de palavra na interface Avalon-MM de dados da megafunção `altera_onchip_flash`, e as caches e o `flash_arbiter` servem a flash interna como servem a NOR paralela.

O adaptador só lê. Ele não tem porta de escrita nem de CSR, então nunca grava, apaga nem muda a proteção dos setores; essas operações continuam no `max10_flash`.

| Aspecto | `nor_flash_ctrl` | `max10_xip` |
| :--- | :--- | :--- |
| Interface com o armazenamento | Pinos paralelos de 8 bits | Avalon-MM de dados, uma palavra de 32 bits por leitura |
| Palavra de 32 bits | Quatro leituras de byte | Uma leitura |
| Linha de 16 bytes | Dezesseis leituras de byte | Quatro leituras de palavra, em sequência |
| Escrita | Comandos K4 | Nenhuma |

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `data_addr_bits` | `positive` | 17 | Largura do endereço de palavra da interface de dados da megafunção |
| `window_bytes` | `positive` | 262144 | Tamanho da janela vista pelo SoC, uma potência de dois de 16 bytes em diante |
| `base_word` | `natural` | 16384 | Palavra do espaço de dados da megafunção que é a palavra zero da janela |

O padrão é a primeira metade da CFM2 (palavras 16384 a 81919), o setor de usuário só de leitura do IP gerado. A soma de `base_word` com as palavras da janela cabe no espaço de dados de `2^data_addr_bits` palavras.

### 2.2. Portas de leitura

São as do `flash_chip`, sem as portas do armazenamento.

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | Clock do módulo, o mesmo da megafunção |
| `i_rst` | entrada | 1 | Reset síncrono, ativo em `'1'` |
| `i_addr` | entrada | 32 | Endereço de byte do pedido |
| `i_rden` | entrada | 1 | Pedido de leitura |
| `i_line` | entrada | 1 | Linha (`'1'`) ou palavra (`'0'`) |
| `i_advance` | entrada | 1 | O pedido foi consumido neste ciclo |
| `o_ready` | saída | 1 | Pedido concluído, dado válido, mantido até `i_advance` |
| `o_busy` | saída | 1 | `'1'` em cada ciclo de espera da megafunção |
| `o_rdata` | saída | 32 | Palavra pedida (palavra 0 da linha) |
| `o_rdata_x` | saída | 96 | Palavras 1 a 3 da linha |

### 2.3. Portas da megafunção

São as portas de dados do `max10_flash`, só as de leitura.

| Porta | Direção | Significado |
| :--- | :--- | :--- |
| `o_data_read` | saída | Pedido de leitura, mantido até `i_data_wait` cair |
| `o_data_addr` | saída | Endereço de palavra |
| `i_data_wait` | entrada | O pedido ainda não foi aceito |
| `i_data_rvalid`, `i_data_rdata` | entrada | Palavra lida e sua validade |

## 3. Comportamento

### 3.1. Janela

O SoC enxerga a flash como uma janela de `window_bytes` bytes. A palavra $w$ da janela é a palavra $base\_word + w$ do espaço de dados. Uma leitura cujos bits 25 até o fim do tamanho da janela não são todos zero está fora dela: o pedido termina no ciclo seguinte com zero em todas as palavras, sem tocar na megafunção.

### 3.2. Leitura

A palavra pedida é a de endereço alinhado a 4 bytes, e a linha começa no endereço alinhado a 16 bytes. As palavras saem em ordem crescente de endereço, uma leitura Avalon por palavra:

1. `o_data_read` sobe com o endereço da palavra e fica ativo até `i_data_wait` cair, que é o aceite.
2. O módulo espera `i_data_rvalid` e guarda `i_data_rdata` na posição da palavra.
3. Na última palavra do pedido `o_ready` sobe e fica em nível alto até `i_advance`; nas demais o endereço avança de um e o ciclo recomeça.

Uma leitura de endereço além dos setores da megafunção devolve uns, como o próprio IP.

### 3.3. Latência

A latência de cada palavra é a da megafunção, do aceite à validade do dado; no modelo de simulação são duas bordas depois do aceite. O pedido leva, no total, o tempo de uma leitura Avalon por palavra, de modo que uma linha custa quatro vezes o de uma palavra.

### 3.4. Divisão da megafunção com o `max10_flash`

A interface de dados da megafunção tem um dono por vez. Quando o `max10_flash` (que grava e apaga) usa a mesma megafunção, o topo liga as portas Avalon ao `max10_xip` ou ao `max10_flash` e entrega `'1'` em `i_data_wait` ao que não foi escolhido, o que mantém o pedido dele parado.

## 4. Integração

| Bloco | Relação |
| :--- | :--- |
| `flash_arbiter` | Serve os dois mestres de leitura (cache de instruções e de dados) sobre a megafunção, com a mesma interface do `nor_flash_ctrl` |
| `mem_region_router` | Roteia a janela da flash interna como roteia a da NOR |
| `max10_flash` | Grava e apaga os setores de usuário; divide a interface de dados com o adaptador (seção 3.4) |
| `max10_flash_ip` | Casca da megafunção gerada no Platform Designer, ou o `max10_flash_model` na simulação |

## 5. Verificação

| Verificação | Cobertura |
| :--- | :--- |
| Entrada `Max10Xip` de `tests/python/tests.json`, módulo `tests.python.unittests.rom.max10_xip`, sobre o banco `max10_xip_tb` e o `max10_flash_model`, com o `max10_flash` gravando o conteúdo | Palavra e linha contra o conteúdo gravado a partir de `base_word`; endereço desalinhado alinhado à palavra ou à linha; leitura fora da janela com zero; a linha leva quatro leituras; o adaptador nunca pede escrita; sequência aleatória de pedidos |
| Prova formal `formal/max10_xip/run.sh` | Ver [blocks](../formal/blocks.md): cada leitura traz o endereço de palavra do pedido na janela, uma por vez e na ordem, o pedido se mantém até o aceite, o dado entregue é o das palavras lidas e a leitura fora da janela não toca a megafunção, com mutantes |

## 6. Referência

| Fonte | Conteúdo |
| :--- | :--- |
| Manual da DE10-Lite, seção 1.3 e capítulo 6 | 5.888 Kbits de flash de usuário e a configuração interna do MAX 10 |
| [max10_flash](max10_flash.md), seções 1 e 2.3 | Setores do IP gerado e interface Avalon-MM de dados |
| [flash_chip](flash_chip.md), seção 1.1 | Contrato de handshake de leitura |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
