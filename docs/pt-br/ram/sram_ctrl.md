# sram_ctrl

Controlador de SRAM assíncrona de 16 bits atrás do contrato de dados do [ram_chip](ram_chip.md).

## 1. Função do componente no SoC

O controlador é o backend `dispositivo/sram` da região RAM. Ele atende o SoC com o contrato de dados do `ram_chip` (pedido de uma palavra ou de uma linha de quatro palavras, habilita de bytes na escrita, endereço fora da janela lê zero) e comanda os pinos de uma SRAM de 1M x 16, como a IS61WV102416BLL-10 da DE2-115: 20 bits de endereço de palavra de 16 bits, `CE#`, `OE#`, `WE#`, `LB#` e `UB#`. Uma palavra de 32 bits são dois acessos de meia palavra, e uma linha são oito. O controlador tem uma só porta, e o árbitro à frente dele reparte os mestres.

## 2. Interface

### 2.1. Generics

Os tempos são ns, e os padrões vêm de [chip_timing_pkg](../rom/chip_timing_pkg.md).

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `clk_period_ns` | `positive` | 20 | Período do clock |
| `margin_ns` | `natural` | 0 | Margem somada a cada tempo para o atraso de pino e de placa |
| `size_bytes` | `positive` | 2097152 | Tamanho do chip, potência de dois de 16 bytes a 2 MB |
| `base_kib` | `natural` | 0 | Onde o chip começa dentro dos 64 MB da região, em KiB |
| `t_aa_ns`, `t_rc_ns` | `natural` | 10, 10 | Acesso por endereço e ciclo de leitura |
| `t_wc_ns`, `t_sce_ns`, `t_aw_ns` | `natural` | 10, 8, 8 | Ciclo de escrita, `CE#` e endereço até o fim da escrita |
| `t_pwe_ns`, `t_sd_ns` | `natural` | 8, 6 | Pulso de `WE#` e dado antes da subida |
| `t_ha_ns`, `t_hd_ns` | `natural` | 0, 0 | Endereço e dado mantidos depois da subida |

### 2.2. Portas do SoC

São as da porta de dados do `ram_chip`, com o avanço chamado `i_advance` (contrato K2).

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk`, `i_rst` | entrada | 1 | Clock e reset síncrono, ativo em `'1'` |
| `i_addr` | entrada | 32 | Endereço de byte do acesso |
| `i_wdata`, `i_byteena` | entrada | 32, 4 | Dado e habilita de bytes da palavra 0 |
| `i_rden`, `i_wren` | entrada | 1 | Pedido de leitura e de escrita; a escrita prevalece |
| `i_advance` | entrada | 1 | O pipeline avançou neste ciclo |
| `o_ready` | saída | 1 | Acesso concluído, mantido até `i_advance` |
| `o_rdata` | saída | 32 | Dado lido, que só muda na borda de `i_advance` |
| `i_line` | entrada | 1 | Acesso de linha de quatro palavras |
| `i_wdata_x`, `i_byteena_x` | entrada | 96, 12 | Palavras 1 a 3 do dado e do habilita de bytes |
| `o_rdata_x` | saída | 96 | Palavras 1 a 3 do dado lido |

### 2.3. Portas do chip

| Porta | Direção | Largura | Pino da DE2-115 |
| :--- | :--- | ---: | :--- |
| `o_sram_addr` | saída | 20 | `SRAM_ADDR[19:0]` |
| `o_sram_dq` | saída | 16 | `SRAM_DQ[15:0]`, dado a escrever |
| `o_sram_dq_oe` | saída | 1 | O controlador dirige `SRAM_DQ`; o topo faz o tristate |
| `i_sram_dq` | entrada | 16 | `SRAM_DQ[15:0]`, dado lido |
| `o_sram_ce_n`, `o_sram_oe_n`, `o_sram_we_n` | saída | 1 | `SRAM_CE_N`, `SRAM_OE_N`, `SRAM_WE_N` |
| `o_sram_lb_n`, `o_sram_ub_n` | saída | 1 | `SRAM_LB_N`, `SRAM_UB_N` |

## 3. Comportamento

### 3.1. Número de ciclos de cada fase

Com $T$ o período, $m$ a margem e $\lceil x \rceil$ o teto com mínimo de um (`cycles_of`),

$$ n_{rd} = \left\lceil \frac{\max(t_{aa}, t_{rc}) + m}{T} \right\rceil \qquad n_{wl} = \max\left( \left\lceil \frac{t_{pwe} + m}{T} \right\rceil,\ \left\lceil \frac{\max(t_{sd}, t_{aw}, t_{sce}) + m}{T} \right\rceil - 1 \right) $$

$$ n_{wh} = \max\left( \left\lceil \frac{\max(t_{ha}, t_{hd}) + m}{T} \right\rceil,\ \left\lceil \frac{t_{wc} + m}{T} \right\rceil - n_{wl} - 1 \right) $$

A 50 MHz os padrões dão $n_{rd} = n_{wl} = n_{wh} = 1$. Quando o período é menor que o tempo de acesso, $n_{rd}$ sobe e cada meia palavra leva mais de um ciclo.

### 3.2. Leitura

A cada meia palavra o endereço sai de um registrador junto com `CE#`, `OE#`, `LB#` e `UB#` baixos, e o dado é capturado $n_{rd}$ ciclos depois, com o endereço seguinte saindo na mesma borda. Uma palavra leva $2\,n_{rd}$ ciclos e uma linha $8\,n_{rd}$, além do ciclo que aceita o pedido, e `o_ready` sobe no ciclo seguinte à última captura. O dado fica num registrador pendente e passa a `o_rdata` na borda de `i_advance`, porque o load que ainda está no estágio de escrita lê o valor anterior até lá.

### 3.3. Escrita

Só as meias palavras com algum byte habilitado são escritas, em ordem de endereço, com `LB#` e `UB#` seguindo os bits de habilita de bytes: um store de byte não toca no byte vizinho. Cada escrita tem o ciclo de escolha da meia palavra, um ciclo de preparação com endereço, dado, `CE#`, `LB#` e `UB#` já nos pinos e `OE#` alto, `WE#` baixo por $n_{wl}$ ciclos e `WE#` alto por $n_{wh}$ ciclos. O controlador dirige `SRAM_DQ` só na escrita.

### 3.4. Janela

Um acesso fora do intervalo $[B,\ B + S)$, com $B$ igual a `base_kib` em bytes e $S$ igual a `size_bytes`, termina sem tocar no chip: a leitura devolve zero e a escrita é descartada.

### 3.5. Máquina de estados

| Estado | Ação | Próximo estado |
| :--- | :--- | :--- |
| `S_IDLE` | Captura endereço, dados e máscaras | `S_RD`, `S_WSEL` ou `S_DONE` (fora da janela) |
| `S_RD` | Espera $n_{rd}$ ciclos e captura a meia palavra | `S_RD` ou `S_DONE` |
| `S_WSEL` | Escolhe a próxima meia palavra com byte habilitado | `S_WSETUP` ou `S_DONE` |
| `S_WSETUP`, `S_WLOW`, `S_WHIGH` | As três fases da escrita | `S_WSEL` |
| `S_DONE` | `o_ready` alto até `i_advance` | `S_IDLE` |

As esperas são contadas pela [latency_counter](../latency/latency_counter.md).

## 4. Integração

O topo da placa faz o tristate de `SRAM_DQ` com `o_sram_dq_oe`. O modelo [sram_model](sram_model.md) faz o papel do chip na simulação, dentro do banco `sram_ctrl_tb`.

## 5. Verificação

| Verificação | Cobertura |
| :--- | :--- |
| Entradas `SramCtrl`, `SramCtrl100` e `SramCtrlSlow` de `tests/python/tests.json`, módulo `tests.python.unittests.ram.sram_ctrl`, sobre `sram_ctrl_tb` | Ciclos até o pronto de uma palavra e de uma linha segundo a fórmula; stores com as 16 máscaras de bytes e acumulação de bytes; linhas com máscaras; mistura aleatória de acessos contra uma memória de referência; janela acima e abaixo do chip; pronto mantido e dado só no avanço |
| Mesmas entradas | O [sram_model](sram_model.md) falha a simulação se o controlador violar um tempo; passam 50 MHz, 100 MHz com 2 ns de margem e `base_kib` de 64, e 250 MHz com 1 ns de margem |
| Prova formal `formal/sram_ctrl/run.sh` | Ver [blocks](../formal/blocks.md): pinos, bytes, fases, dado e contrato, em duas configurações de ciclos, com mutantes |

## 6. Referência

| Fonte | Conteúdo |
| :--- | :--- |
| `Plans/Multi-FPGA/05-FRENTES-E-TRILHAS.md`, tarefa M.5.5 | Controlador de SRAM com modelo e testes |
| `Plans/Multi-FPGA/01-ARQUITETURA.md`, seções 4 e 4.1 | Backend `dispositivo/sram`, dois acessos por palavra e ciclo duplo quando $T$ é menor que o tempo de acesso |
| `Plans/Multi-FPGA/placas/de2-115.md`, seção 5.2 | Pinos, largura de 16 bits e tempos `inferido` da IS61WV102416BLL-10 |
| `chips/IS61WV102416BLL-10.yaml` | Tempos do catálogo, espelhados em [chip_timing_pkg](../rom/chip_timing_pkg.md) |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
