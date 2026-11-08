# sram_model

Modelo de simulação da SRAM assíncrona de 16 bits, que verifica os tempos do datasheet e falha a simulação quando o [sram_ctrl](sram_ctrl.md) viola um.

## 1. Função do componente no SoC

O modelo faz o papel da IS61WV102416BLL-10 da DE2-115 nos pinos do controlador: 1M palavras de 16 bits, leitura assíncrona por endereço e escrita comandada por `WE#`, com `LB#` e `UB#` escolhendo o byte baixo e o alto. O conteúdo começa em zero. O modelo não é sintetizável, porque mede o tempo de simulação. O banco `sram_ctrl_tb` liga o controlador ao modelo e faz o tristate do barramento de dados; o modelo recebe só o que o controlador dirige, para flagrar uma contenção.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `size_bytes` | `positive` | 2097152 | Tamanho do chip, potência de dois de 16 bytes a 2 MB |
| `t_aa_ns`, `t_rc_ns` | `natural` | 10, 10 | Acesso por endereço e ciclo de leitura |
| `t_wc_ns`, `t_sce_ns`, `t_aw_ns` | `natural` | 10, 8, 8 | Ciclo de escrita, `CE#` e endereço até o fim da escrita |
| `t_pwe_ns`, `t_sd_ns` | `natural` | 8, 6 | Pulso de `WE#` e dado antes da subida |
| `t_ha_ns`, `t_hd_ns` | `natural` | 0, 0 | Endereço e dado mantidos depois da subida |
| `abort_on_violation` | `boolean` | `true` | Uma violação aborta a simulação; falso só avisa |

### 2.2. Portas

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_sram_addr` | entrada | 20 | Endereço de palavra de 16 bits |
| `i_sram_dq` | entrada | 16 | Dado dirigido pelo controlador, `'Z'` quando solto |
| `o_sram_dq` | saída | 16 | Dado dirigido pelo chip, `'Z'` nas faixas de byte desabilitadas |
| `i_sram_ce_n`, `i_sram_oe_n`, `i_sram_we_n`, `i_sram_lb_n`, `i_sram_ub_n` | entrada | 1 | Controles, ativos em `'0'` |
| `o_violation` | saída | 1 | Pulso de 1 ns a cada violação |

## 3. Comportamento

Na leitura, com `CE#` e `OE#` baixos e `WE#` alto, `o_sram_dq` vale `'X'` até $\max(t_{addr}, t_{ce}, t_{oe}) + t_{aa}$ e depois a palavra do endereço, com `'Z'` na faixa cujo `LB#` ou `UB#` está alto. Na subida de `WE#` com `CE#` baixo, o chip grava só os bytes que `LB#` e `UB#` habilitam na descida.

| Violação | Regra |
| :--- | :--- |
| Leitura encerrada antes do tempo | Mudança de endereço, `CE#`, `OE#` ou `WE#` antes de `t_aa_ns` |
| Ciclo de endereço | Mudança de endereço em menos de `t_rc_ns` durante uma leitura ou uma escrita |
| Pulso de `WE#` | Menor que `t_pwe_ns` |
| Preparação da escrita | Endereço estável por menos de `t_aw_ns`, `CE#` baixo por menos de `t_sce_ns` ou dado estável por menos de `t_sd_ns` antes da subida |
| Ciclo de escrita | De uma descida de `WE#` à seguinte, menos que `t_wc_ns` |
| Retenção | Endereço ou dado mudando antes de `t_ha_ns` ou `t_hd_ns` depois da subida, ou o endereço mudando com `WE#` baixo |
| Dado | Indefinido na subida de `WE#`, ou `LB#`/`UB#` mudando durante o pulso |
| Contenção | O controlador dirigindo o dado enquanto o chip dirige a leitura |

## 4. Verificação

| Entrada de `tests/python/tests.json` | Módulo cocotb | O que cobre |
| :--- | :--- | :--- |
| `SramModel` | `tests.python.unittests.ram.sram_model` | Escrita e leitura nos tempos do datasheet sem violação, faixas de byte, e a leitura cortada, o pulso curto, o dado tardio e a contenção pulsando `o_violation` |
| `SramCtrl`, `SramCtrl100`, `SramCtrlSlow` | `tests.python.unittests.ram.sram_ctrl` | O modelo com `abort_on_violation` verdadeiro dentro de `sram_ctrl_tb`: um teste que termina prova que o controlador respeitou os tempos |

## 5. Referência

| Fonte | Conteúdo |
| :--- | :--- |
| `Plans/Multi-FPGA/05-FRENTES-E-TRILHAS.md`, tarefa M.5.5 | Controlador de SRAM com modelo e testes |
| `Plans/Multi-FPGA/placas/de2-115.md`, seção 5.2 | Tempos `inferido` da IS61WV102416BLL-10 |
| `chips/IS61WV102416BLL-10.yaml` | Tempos do catálogo, espelhados em [chip_timing_pkg](../rom/chip_timing_pkg.md) |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
