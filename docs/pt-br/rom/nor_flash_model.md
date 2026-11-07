# nor_flash_model

Modelo de simulação do chip de FLASH NOR paralela de 8 bits, que verifica os tempos do datasheet e falha a simulação quando o [nor_flash_ctrl](nor_flash_ctrl.md) viola um.

## 1. Função do componente no SoC

O modelo faz o papel do S29GL064N da DE2-115 nos pinos do controlador: leitura assíncrona com acesso aleatório e de página, e os ciclos de escrita de comando do chip em modo byte, com a operação interna durando `t_prog_ns` ou `t_erase_ns` e o pino `RY` baixo enquanto dura. O banco de teste `nor_flash_ctrl_tb` liga o controlador ao modelo e faz o tristate do barramento de dados, como o topo da placa.

O modelo não é sintetizável, porque mede o tempo de simulação. O controlador conta ciclos e o modelo mede nanossegundos, de modo que um erro de conversão no controlador aparece como violação.

## 2. Interface

### 2.1. Generics

Os tempos são ns, e os padrões vêm de [chip_timing_pkg](chip_timing_pkg.md).

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `size_bytes` | `positive` | 8388608 | Tamanho do chip, potência de dois de 8 KB a 8 MB |
| `sector_bytes` | `positive` | 65536 | Setor de apagar |
| `t_acc_ns`, `t_pacc_ns`, `t_oe_ns` | `natural` | 90, 25, 35 | Acesso aleatório e de `CE#`, de página e de `OE#` |
| `t_wc_ns`, `t_wp_ns`, `t_wph_ns` | `natural` | 90, 35, 30 | Ciclo, pulso e `WE#` alto |
| `t_ds_ns`, `t_ah_ns` | `natural` | 45, 45 | Dado antes e endereço depois do pulso |
| `t_busy_ns`, `t_rp_ns`, `t_rh_ns` | `natural` | 90, 500, 50 | Descida de `RY`, pulso e espera de `RESET#` |
| `t_prog_ns`, `t_erase_ns` | `natural` | 60000, 500000000 | Duração da gravação de um byte e do apagar de um setor |
| `erased_init` | `boolean` | `false` | Conteúdo inicial todo em `0xFF`, em vez do padrão determinístico |
| `abort_on_violation` | `boolean` | `true` | Uma violação aborta a simulação; falso só avisa |

### 2.2. Portas

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_fl_addr` | entrada | 23 | Endereço de byte |
| `i_fl_dq` | entrada | 8 | Dado dirigido pelo controlador, `'Z'` quando solto |
| `o_fl_dq` | saída | 8 | Dado dirigido pelo chip, `'Z'` quando solto |
| `i_fl_ce_n`, `i_fl_oe_n`, `i_fl_we_n`, `i_fl_rst_n`, `i_fl_wp_n` | entrada | 1 | Controles, ativos em `'0'` |
| `o_fl_ry` | saída | 1 | Pronto (`'1'`) ou ocupado (`'0'`) |
| `o_violation` | saída | 1 | Pulso de 1 ns a cada violação |

## 3. Comportamento

### 3.1. Leitura

Com $t_{addr}$, $t_{ce}$ e $t_{oe}$ os instantes da última mudança de endereço e das últimas descidas de `CE#` e `OE#`, o dado fica válido em

$$ t_{valido} = \max(t_{addr} + t_{a},\ t_{ce} + t_{acc},\ t_{oe} + t_{oe\_ns}) $$

com $t_a$ igual a `t_acc_ns` quando a página do endereço (bits 22 a 4) mudou ou `CE#` acabou de descer, e a `t_pacc_ns` dentro da página. Antes disso `o_fl_dq` vale `'X'`, e depois vale o byte do conteúdo. Com `CE#` ou `OE#` alto, ou `WE#` baixo, o chip solta o barramento.

### 3.2. Comandos

Os ciclos de escrita são decodificados em modo byte, com os endereços de desbloqueio `0xAAA` e `0x555` comparados nos 12 bits baixos.

| Sequência (endereço, dado) | Efeito |
| :--- | :--- |
| `(AAA,AA)` `(555,55)` `(AAA,A0)` `(PA,PD)` | Grava o byte: o novo conteúdo é o E bit a bit do conteúdo com `PD`, ao fim de `t_prog_ns` |
| `(AAA,AA)` `(555,55)` `(AAA,80)` `(AAA,AA)` `(555,55)` `(SA,30)` | Apaga o setor de `SA`, ao fim de `t_erase_ns` |
| Qualquer ciclo com dado `0xF0` em repouso | Ignorado |

`RY` desce `t_busy_ns` depois da subida de `WE#` do último ciclo e sobe no fim da operação. A leitura durante a operação devolve o estado: no bit 7, o complemento do bit 7 do dado gravado (gravação) ou `'0'` (apagar), e zero nos demais; o bit 6 de alternância não é modelado. `RESET#` baixo aborta a operação e deixa o conteúdo como estava. `WP#` baixo ignora gravar e apagar no último setor.

### 3.3. Violações

Cada linha abaixo faz `o_violation` pulsar e, com `abort_on_violation` verdadeiro, falha a simulação.

| Violação | Regra |
| :--- | :--- |
| Leitura encerrada antes do tempo | Mudança de endereço, `CE#` ou `OE#` alto antes de $t_{valido}$ |
| Pulso de `WE#` | Largura menor que `t_wp_ns` |
| `WE#` alto | Menos que `t_wph_ns` desde a subida anterior |
| Ciclo de escrita | De uma descida de `WE#` à seguinte, menos que `t_wc_ns` |
| Dado antes da subida | Estável por menos de `t_ds_ns`, ou indefinido |
| Endereço depois da descida | Muda antes de `t_ah_ns` |
| Uso | `WE#` sem `CE#`, `WE#` e `OE#` baixos juntos, escrita fora da sequência ou durante a operação |
| `RESET#` | Pulso menor que `t_rp_ns`, ou `CE#` baixo antes de `t_rh_ns` da subida |

### 3.4. Conteúdo inicial

O byte de endereço $a$ começa em $\left\lfloor ((a \cdot \texttt{0x9E3779B1}) \bmod 2^{32}) \oplus \texttt{0x5A5A1234} \right\rfloor \gg 24$, que os testes reproduzem, ou em `0xFF` com `erased_init`.

## 4. Verificação

| Entrada de `tests/python/tests.json` | Módulo cocotb | O que cobre |
| :--- | :--- | :--- |
| `NorFlashModel` | `tests.python.unittests.rom.nor_flash_model` | Leituras aleatória e de página nos tempos exatos sem violação, dado `'X'` antes do tempo de página, gravação e apagar com `RY` e estado, e cada violação da seção 3.3 pulsando `o_violation` |
| `NorFlashCtrl`, `NorFlashCtrl100`, `NorFlashCtrlMargin` | `tests.python.unittests.rom.nor_flash_ctrl` | O modelo com `abort_on_violation` verdadeiro dentro do banco `nor_flash_ctrl_tb`: um teste que termina prova que o controlador respeitou todos os tempos |

## 5. Referência

| Fonte | Conteúdo |
| :--- | :--- |
| `Plans/Multi-FPGA/05-FRENTES-E-TRILHAS.md`, tarefa M.5.4 | Modelo de chip que lê os tempos do catálogo e falha se o controlador violar um |
| `Plans/Multi-FPGA/placas/de2-115.md`, seção 5.3 | Tempos `inferido` do S29GL064N90 |
| `chips/S29GL064N90.yaml` | Tempos do catálogo, espelhados em [chip_timing_pkg](chip_timing_pkg.md) |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
