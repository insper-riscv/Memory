# ram

## 1. Função do componente no SoC

O IP interno da RAM é a memória de dados do core quando a RAM fica dentro da FPGA. É uma memória de uma porta, com leitura e escrita síncronas e habilita de bytes, implementada em blocos de memória do dispositivo por uma instância de [block_ram](../block_ram/block_ram.md), que encapsula a megafunção `altsyncram` da biblioteca `altera_mf` do Quartus (fora deste repositório). Segundo o README do repositório, os IPs também simulam no GHDL pelos modelos `altera_mf` da Intel, e o modelo de simulação de uso geral da RAM é o descrito em [ram_simulation.md](ram_simulation.md).

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `size_bytes` | positive | 262144 | tamanho da janela endereçável em bytes, uma potência de dois |
| `word_count` | positive | 65536 | quantidade de palavras de 32 bits fisicamente implementadas |

Com $S$ igual a `size_bytes`, o endereço de palavra tem $\log_2 S - 2$ bits. Com $N$ igual a `word_count`, a memória implementa $N$ palavras e exige $N \le S / 4$. Essa separação permite uma profundidade física que não seja potência de dois sem reduzir a largura do endereço.

### 2.2. Portas

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_address` | entrada | $\log_2 S - 2$ | endereço de palavra |
| `i_byteena` | entrada | 4 | habilita de bytes da escrita, padrão `1111` |
| `i_clk` | entrada | 1 | clock único da memória, padrão `'1'` |
| `i_data` | entrada | 32 | dado de escrita |
| `i_rden` | entrada | 1 | habilita de leitura, padrão `'1'` |
| `i_wren` | entrada | 1 | habilita de escrita |
| `o_q` | saída | 32 | dado lido |

Com o padrão de 256 KB, o endereço tem 16 bits.

## 3. Comportamento

### 3.1. Instância da `block_ram`

| Generic | Valor | Efeito |
| :--- | :--- | :--- |
| `operation_mode` | `SINGLE_PORT` | uma porta de leitura e escrita |
| `word_count` | `word_count` | quantidade de palavras fisicamente implementadas |
| `address_width` | $\log_2$ `size_bytes` $- 2$ | largura do endereço |
| `byte_lanes` | 4 | quatro faixas de byte de 8 bits |
| `instance_name` | `RAM` | o conteúdo pode ser lido e reescrito por JTAG com o editor de conteúdo de memória do Quartus, pela instância de nome `RAM` |

A `block_ram` fixa o restante: saída sem registrador (`UNREGISTERED`), sem habilita de clock (`BYPASS`), sem reset assíncrono da saída, leitura no mesmo endereço de uma escrita devolvendo o dado novo (`NEW_DATA_NO_NBE_READ`) e memória iniciada em zero (`power_up_uninitialized` em `FALSE`).

### 3.2. Latência

O endereço, o dado e os habilitas são capturados na borda de subida de `i_clk`, e a saída não tem registrador, então `o_q` apresenta a palavra lida logo depois dessa borda, ou seja, a leitura tem latência de 1 ciclo. O contrato do core espera o dado da RAM interna no ciclo seguinte ao pedido (veja o contrato de barramento e memória do repositório Core).

### 3.3. Inicialização

A instância não recebe arquivo de inicialização (`init_file` em `UNUSED`) e o `.qip` não lista nenhum. A pasta contém um `init.mif` de 4096 palavras de 32 bits cujo conteúdo declarado é zero nos endereços `00A` a `FFF`, que não é usado pelo IP. Com `power_up_uninitialized` em `FALSE`, a RAM inicia com zeros, e o `instance_name` permite reescrever o conteúdo por JTAG depois da configuração da FPGA. A instância usa `word_count` para a profundidade física e `size_bytes` para a largura do endereço.

### 3.4. Arquivos do IP

| Arquivo | Conteúdo |
| :--- | :--- |
| `ram.vhd` | a entidade e a instância da `block_ram` |
| `ram.qip` | lista o `block_ram.vhd` e o `ram.vhd` para o Quartus, sem marca de família |
| `init.mif` | imagem de zeros, sem referência no `.qip` nem no `.vhd` |

## 4. Integração

| Item | Descrição |
| :--- | :--- |
| Instanciado em | `src/simulation/internal-mem/quartus/core_fpga_test.vhd` do repositório Insper-RISC-V, instância `RAM`, no clock `pll_clk_idexmem` |
| Endereço | o endereço de byte da RAM do core menos a base da RAM (`0x00008000`), em palavras, truncado a 16 bits |
| Profundidade | `size_bytes` preserva os 16 bits de endereço e `word_count` recebe a quantidade de palavras da faixa de RAM definida pelo mapa da plataforma |
| Habilitas | `i_rden` e `i_wren` são os da RAM do core combinados com o habilita da RAM e com a negação da seleção da UART, de modo que um acesso à UART não alcança a RAM |
| Dado | `i_data` e `i_byteena` vêm dos sinais de escrita da RAM do core, e `o_q` volta ao core como dado lido |

O mapa de memória, a faixa da RAM interna (`0x00008000` a `0x3FFFFFFF` por padrão) e o contrato de ready do barramento estão no contrato de barramento e memória do repositório Core. A `RAM` é a única memória do desenho de memória interna com o editor de conteúdo em sistema, porque a FLASH é regravada pelo carregador, então a instância dela tem o índice 0.

## 5. Verificação

Este IP não tem teste cocotb próprio nem entrada em `tests/python/tests.json`, porque a biblioteca `altera_mf` é do Quartus. O comportamento de memória síncrona de uma porta com máscara de bytes é verificado no modelo de simulação equivalente, descrito em [ram_simulation.md](ram_simulation.md). Os caminhos do `.qip` estão registrados em `paths.yaml`.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
