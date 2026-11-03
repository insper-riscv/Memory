# flash_mem1port

IP interno de ROM de uma porta que é a segunda cópia física da FLASH interna, lida como dado pelo estágio MEM.

## 1. Função do componente no SoC

O estágio MEM precisa ler a FLASH como dado, por exemplo para copiar a seção `.data` na inicialização (porta de dados da FLASH de 1 ciclo, ver [02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md), seção 3.1). Esta cópia atende essa leitura, enquanto o [flash1port](flash1port.md) atende a busca de instruções. Pelo cabeçalho do VHDL, não se usou uma única FLASH de duas portas porque um `altsyncram` `DUAL_PORT` com `ENABLE_RUNTIME_MOD=YES` não compila nesta edição do Quartus.

### 1.1. Diferença entre os três IPs de FLASH

A tabela comparativa está em [flash1port](flash1port.md). Em relação ao `flash1port`, este IP tem a mesma receita, o mesmo tamanho e o mesmo arquivo de inicialização, e difere só no nome de instância (`FLASH_MEM`). As duas cópias precisam ter sempre o mesmo conteúdo.

## 2. Interface

### 2.1. Generic

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `size_bytes` | `positive` | 32768 | Tamanho em bytes, potência de dois (32 KB por padrão); define a largura de `address` e o número de palavras |

### 2.2. Portas

| Porta | Direção | Largura | Padrão | Significado |
| :--- | :--- | ---: | :--- | :--- |
| `address` | entrada | $\log_2(\text{size\_bytes}) - 2$ (13 com o padrão) | | Índice da palavra (endereço de byte sem os dois bits baixos) |
| `clock` | entrada | 1 | `'1'` | Clock da memória |
| `rden` | entrada | 1 | `'1'` | Habilita a leitura |
| `wren` | entrada | 1 | `'0'` | Habilita a escrita |
| `data` | entrada | 32 | zeros | Dado de escrita |
| `q` | saída | 32 | | Palavra lida |

## 3. Comportamento

### 3.1. Configuração da biblioteca

A leitura é feita pela instância `altsyncram` da biblioteca `altera_mf`, que é do Quartus e não faz parte deste repositório. Os parâmetros fixados no VHDL são:

| Parâmetro | Valor |
| :--- | :--- |
| `operation_mode` | `SINGLE_PORT` |
| `width_a` | 32 |
| `numwords_a` | $\text{size\_bytes} / 4$ (8192 com o padrão) |
| `widthad_a` | $\log_2(\text{size\_bytes}) - 2$ (13 com o padrão) |
| `init_file` | `./init.mif` |
| `outdata_reg_a` | `UNREGISTERED` |
| `read_during_write_mode_port_a` | `NEW_DATA_NO_NBE_READ` |
| `lpm_hint` | `ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=FLASH_MEM` |
| `intended_device_family` | `Cyclone V` |

### 3.2. Latência de leitura

O endereço é capturado na borda de `clock` e a saída não tem registrador adicional, então a palavra do endereço aplicado numa borda aparece em `q` depois dela, com um ciclo de latência síncrona. A dica `ENABLE_RUNTIME_MOD` mantém a memória visível ao editor de conteúdo em sistema do Quartus, e a instância aparece com o nome `FLASH_MEM`, o que permite regravar o conteúdo por JTAG sem recompilar.

## 4. Integração

O arquivo `src/rom/cyclone-v/flash_mem1port.qip` registra o IP como "ROM: 1-PORT", versão 20.1, família Cyclone V, e aponta para o VHDL.

| Topo | Instância | Ligação |
| :--- | :--- | :--- |
| Topo de teste de FPGA da plataforma de memória interna (Insper-RISC-V) | `FLASH_MEM` | `address` nos bits 14 a 2 do endereço de leitura de dado da FLASH, `clock` no clock `pll_clk_idexmem` do topo, `rden` na habilitação de leitura de dado da FLASH, `wren` em `'0'`, `q` no dado de leitura da FLASH |

A ferramenta de carga regrava as duas cópias a cada troca de teste, segundo o cabeçalho do VHDL. Na simulação em GHDL a segunda porta de [rom_simulation](rom_simulation.md) faz o papel desta cópia.

## 5. Verificação

Nenhuma entrada de `tests/python/tests.json` cobre este IP, porque ele exige a biblioteca `altera_mf` da Intel, ausente da imagem de integração contínua (ver o [README](../../../README.md)). Quem o exercita é a simulação do topo de hardware no repositório Tests. O `make paths` confere a existência do `.qip`.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
