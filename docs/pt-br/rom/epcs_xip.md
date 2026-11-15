# epcs_xip

Adaptador de leitura direta (XIP) da flash serial EPCS, atrás do contrato do [flash_chip](flash_chip.md), só para instruções.

## 1. Função do componente no SoC

O [epcs_ctrl](epcs_ctrl.md) entrega a flash serial ao software como um banco de registradores, sem leitura direta de linha. O `epcs_xip` entrega ao SoC o contrato de handshake do `flash_chip`, o mesmo do [nor_flash_ctrl](nor_flash_ctrl.md): um pedido de uma palavra ou de uma linha de quatro palavras, com `o_ready` mantido até `i_advance`. Assim o `flash_arbiter`, o `mem_region_router` e as caches servem a flash serial como servem a NOR paralela, e cada pedido vira um quadro de leitura da flash.

O adaptador só lê. Ele monta apenas as instruções READ e FAST_READ, então nunca grava, apaga nem habilita escrita; essas operações continuam no `epcs_ctrl`. A flash serial só serve atrás de cache, porque um quadro leva centenas de ciclos (seção 3.3).

| Aspecto | `nor_flash_ctrl` | `epcs_xip` |
| :--- | :--- | :--- |
| Pinos | Barramento paralelo de 8 bits com `CE#`, `OE#`, `WE#` | Quatro pinos SPI |
| Latência por linha | Cerca de 35 ciclos a 50 MHz | Centenas de ciclos |
| Escrita | Comandos K4 | Nenhuma |
| Janela | Início do chip | Começa em `chip_offset`, acima do bitstream |

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `window_bytes` | `positive` | 4194304 | Tamanho da janela vista pelo SoC, uma potência de dois de 16 bytes a 16 MB |
| `chip_offset` | `natural` | 4194304 | Byte do chip que é o byte zero da janela, múltiplo de 16 |
| `clk_div` | `positive` | 2 | Bordas de `i_clk` em cada meio período do clock SPI |
| `gap_ticks` | `positive` | 8 | Meios períodos com `CS#` alto depois de cada quadro |
| `fast_read` | `boolean` | `false` | Lê com FAST_READ (um byte dummy a mais) em vez de READ |

O padrão de `window_bytes` e de `chip_offset` é a metade de cima da EPCS64, que é a região de usuário do `epcs_ctrl`. A soma `chip_offset + window_bytes` não passa de 16 MB, o espaço de endereço de 24 bits da instrução.

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
| `o_busy` | saída | 1 | `'1'` do pedido do quadro até o fim dele |
| `o_rdata` | saída | 32 | Palavra pedida (palavra 0 da linha) |
| `o_rdata_x` | saída | 96 | Palavras 1 a 3 da linha |

### 2.3. Pinos SPI

| Porta | Direção | Significado |
| :--- | :--- | :--- |
| `o_sck` | saída | Clock SPI, em repouso baixo |
| `o_cs_n` | saída | Seleção do chip, ativa em `'0'` |
| `o_mosi` | saída | Dado para o chip |
| `i_miso` | entrada | Dado do chip |

Os pinos vão ao bloco de interface com a flash serial do dispositivo (`epcs_asmi_cyclone_iv_e` ou `epcs_asmi_cyclone_v`), ou ao modelo na simulação. O adaptador é o dono dos pinos; quando o `epcs_ctrl` também grava no mesmo chip, o topo escolhe qual dos dois liga os pinos em cada momento.

## 3. Comportamento

### 3.1. Janela

O SoC enxerga a flash como uma janela de `window_bytes` bytes. O byte $a$ da janela é o byte $chip\_offset + a$ do chip, de modo que com `chip_offset` igual ao início da região de usuário o bitstream, que fica abaixo, nunca é alcançado por uma leitura. Uma leitura cujos bits 25 até o fim do tamanho da janela não são todos zero está fora dela: o pedido termina no ciclo seguinte com zero em todas as palavras, sem selecionar o chip.

### 3.2. Quadro

Cada pedido que cai na janela vira um quadro, de `CS#` baixo a `CS#` alto, pelo mestre SPI do `epcs_ctrl`.

| Pedido | Endereço do quadro | Bytes de dado | Instrução |
| :--- | :--- | ---: | :--- |
| Palavra | Endereço alinhado a 4 bytes | 4 | `0x03` (READ) ou `0x0B` (FAST_READ) |
| Linha | Endereço alinhado a 16 bytes | 16 | `0x03` (READ) ou `0x0B` (FAST_READ) |

O byte de menor endereço fica nos bits mais baixos da palavra 0, e a palavra seguinte da linha fica nos bits mais baixos de `o_rdata_x`, como no `nor_flash_ctrl`. O `o_ready` sobe depois do intervalo de `CS#` alto do mestre SPI, e o pedido seguinte só começa depois do `i_advance`.

### 3.3. Latência

Sejam $d$ o `clk_div`, $g$ o `gap_ticks`, $h$ os bytes de cabeçalho (4 no READ e 5 no FAST_READ) e $n$ os bytes de dado (4 na palavra e 16 na linha). Cada byte leva 8 bits de $2d$ ciclos e mais um ciclo de carga, e o pedido de `i_rden` até `o_ready` leva

$$N = (h + n)\,(16\,d + 1) + (g + 1)\,d + 3 \text{ ciclos.}$$

| `clk_div` | `gap_ticks` | Instrução | Palavra | Linha |
| ---: | ---: | :--- | ---: | ---: |
| 2 | 8 | READ | 285 | 681 |
| 1 | 2 | FAST_READ | 159 | 363 |

Uma linha da NOR leva cerca de 35 ciclos a 50 MHz, então um miss de instrução na flash serial custa uma ordem de grandeza a mais.

### 3.4. Escolha de `clk_div`

O clock SPI vale $f_{clk} / (2d)$ e não passa do limite do chip para a instrução escolhida:

$$d \ge \left\lceil \frac{f_{clk}}{2\,f_{spi}} \right\rceil$$

O catálogo de chips traz `read_spi_mhz` (READ) e, quando o chip tem, `fast_read_spi_mhz` (FAST_READ) no campo `timing` de cada arquivo (ver [catálogo](../chips/catalogo.md)). Com a EPCS64 em 50 MHz, $d = 1$ dá 25 MHz; em 100 MHz, $d = 2$ dá 25 MHz.

## 4. Integração

| Bloco | Relação |
| :--- | :--- |
| `flash_arbiter` | Serve os dois mestres de leitura (cache de instruções e de dados) sobre o único chip, com a mesma interface do `nor_flash_ctrl` |
| `mem_region_router` | Roteia a janela da flash serial como roteia a da NOR |
| `epcs_ctrl` | Grava e apaga na região de usuário; divide o chip e os pinos com o adaptador |
| `epcs_spi` | Mestre SPI que o adaptador usa para montar cada quadro |
| Bloco ASMI do dispositivo | Leva os pinos SPI aos pinos de configuração da flash |

## 5. Verificação

| Verificação | Cobertura |
| :--- | :--- |
| Entradas `EpcsXip` (READ, `clk_div` 2) e `EpcsXipFast` (FAST_READ, `clk_div` 1) de `tests/python/tests.json`, módulo `tests.python.unittests.rom.epcs_xip`, sobre o banco `epcs_xip_tb` e o `epcs_model` | Palavra e linha contra o padrão do modelo a partir de `chip_offset`; endereço desalinhado alinhado à palavra ou à linha; leitura fora da janela com zero e `CS#` alto; latência exata da fórmula da seção 3.3; sequência aleatória de pedidos. Todo teste confere que o modelo não marcou violação |
| Prova formal `formal/epcs_xip/run.sh` | Ver [blocks](../formal/blocks.md): nos pinos SPI, só a instrução de leitura sai, o endereço é o do pedido dentro da janela e alinhado, o quadro tem o tamanho do pedido, o dado entregue é o lido do MISO e a leitura fora da janela não seleciona o chip, com mutantes |
| Síntese no Quartus 25.1 | Adaptador com o mestre SPI, ajustado em EP4CE22F17C6 (356 elementos lógicos) e 5CEBA4F23C7 (120 ALMs), 243 registradores e nenhum bit de memória nos dois |

## 6. Referência

| Fonte | Conteúdo |
| :--- | :--- |
| Manuais da DE0-CV (seção 3.1) e da DE2-115 (seção 4.1) | EPCS64 de configuração |
| [epcs_ctrl](epcs_ctrl.md), seção 7 | Instruções e quadro do mestre SPI |
| [flash_chip](flash_chip.md), seção 1.1 | Contrato de handshake de leitura |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
