# ram

## 1. Função do componente no SoC

O IP interno da RAM é a memória de dados do core quando a RAM fica dentro da FPGA. É uma memória de uma porta, com leitura e escrita síncronas e habilita de bytes, implementada em blocos de memória do dispositivo pela megafunção `altsyncram`. O arquivo foi gerado pelo assistente de megafunções do Quartus (RAM de 1 porta, versão 20.1, família Cyclone V), com o tamanho tornado um generic. A biblioteca `altsyncram` pertence ao Quartus (biblioteca `altera_mf`) e não está neste repositório. Segundo o README do repositório, os IPs também simulam no GHDL pelos modelos `altera_mf` da Intel, e o modelo de simulação de uso geral da RAM é o descrito em [ram_simulation.md](ram_simulation.md).

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `size_bytes` | positive | 262144 | tamanho da memória em bytes, uma potência de dois, que é o que ela ocupa na FPGA |

Com $S$ igual a `size_bytes`, a memória tem $S / 4$ palavras de 32 bits, e o endereço de palavra tem $\log_2 S - 2$ bits.

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

### 3.1. Configuração da `altsyncram`

| Parâmetro | Valor | Efeito |
| :--- | :--- | :--- |
| `operation_mode` | `SINGLE_PORT` | uma porta de leitura e escrita |
| `width_a` | 32 | largura do dado |
| `numwords_a` | `size_bytes / 4` | quantidade de palavras |
| `widthad_a` | $\log_2$ `size_bytes` $- 2$ | largura do endereço |
| `width_byteena_a` e `byte_size` | 4 e 8 | quatro faixas de byte de 8 bits |
| `outdata_reg_a` | `UNREGISTERED` | a saída não tem registrador adicional |
| `clock_enable_input_a` e `clock_enable_output_a` | `BYPASS` | sem habilita de clock |
| `outdata_aclr_a` | `NONE` | sem reset assíncrono da saída |
| `read_during_write_mode_port_a` | `NEW_DATA_NO_NBE_READ` | modo de leitura no mesmo endereço de uma escrita, definido pela biblioteca do Quartus |
| `power_up_uninitialized` | `FALSE` | a memória inicia zerada |
| `lpm_hint` | `ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=RAM` | o conteúdo pode ser lido e reescrito por JTAG com o editor de conteúdo de memória do Quartus, pela instância de nome `RAM` |
| `intended_device_family` | `Cyclone V` | família alvo |

### 3.2. Latência

O endereço, o dado e os habilitas são capturados na borda de subida de `i_clk`, e a saída não tem registrador, então `o_q` apresenta a palavra lida logo depois dessa borda, ou seja, a leitura tem latência de 1 ciclo. O contrato do core espera o dado da RAM interna no ciclo seguinte ao pedido (veja o contrato de barramento e memória do repositório Core).

### 3.3. Inicialização

O gerador não referencia nenhum arquivo de inicialização (`MIFfilename` vazio no cabeçalho do IP) e o `.qip` não lista nenhum. A pasta contém um `init.mif` de 4096 palavras de 32 bits cujo conteúdo declarado é zero nos endereços `00A` a `FFF`, que não é usado pelo IP. Com `power_up_uninitialized` em `FALSE`, a RAM inicia com zeros, e o `ENABLE_RUNTIME_MOD` permite reescrever o conteúdo por JTAG depois da configuração da FPGA.

Os parâmetros `NUMWORDS_A` igual a 4096 e `WidthAddr` igual a 12 que o cabeçalho do IP ainda registra são da configuração do assistente, e a instância usa o generic `size_bytes`.

### 3.4. Arquivos do IP

| Arquivo | Conteúdo |
| :--- | :--- |
| `ram.vhd` | a entidade e a instância da `altsyncram` |
| `ram.qip` | lista o `ram.vhd` e o `ram.cmp` para o Quartus, com o nome de ferramenta `RAM: 1-PORT` |
| `init.mif` | imagem de zeros, sem referência no `.qip` nem no `.vhd` |

## 4. Integração

| Item | Descrição |
| :--- | :--- |
| Instanciado em | `src/simulation/internal-mem/quartus/core_fpga_test.vhd` do repositório Insper-RISC-V, instância `RAM`, no clock `pll_clk_idexmem` |
| Endereço | o endereço de byte da RAM do core menos a base da RAM (`0x00008000`), em palavras, truncado a 16 bits |
| Habilitas | `i_rden` e `i_wren` são os da RAM do core combinados com o habilita da RAM e com a negação da seleção da UART, de modo que um acesso à UART não alcança a RAM |
| Dado | `i_data` e `i_byteena` vêm dos sinais de escrita da RAM do core, e `o_q` volta ao core como dado lido |

O mapa de memória, a faixa da RAM interna (`0x00008000` a `0x3FFFFFFF` por padrão) e o contrato de ready do barramento estão no contrato de barramento e memória do repositório Core. A ordem de instanciação importa para o índice da instância JTAG da `RAM`, e o `core_fpga_test` instancia a `FLASH_MEM` depois dela para não mudar o índice da RAM.

## 5. Verificação

Este IP não tem teste cocotb próprio nem entrada em `tests/python/tests.json`, porque a biblioteca `altera_mf` é do Quartus. O comportamento de memória síncrona de uma porta com máscara de bytes é verificado no modelo de simulação equivalente, descrito em [ram_simulation.md](ram_simulation.md). Os caminhos do `.qip` estão registrados em `paths.yaml`.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
