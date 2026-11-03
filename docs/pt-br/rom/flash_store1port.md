# flash_store1port

IP interno de ROM de uma porta que serve de armazenamento do chip de FLASH externa.

## 1. Função do componente no SoC

Este IP é a memória de bloco da FPGA que o [flash_chip](flash_chip.md) comanda. O chip entrega o endereço registrado e recebe a palavra uma borda depois, e o conteúdo é regravado pelo hospedeiro por JTAG. Trocar o conteúdo não muda o chip. O mapa de endereços da FLASH externa (`0x20000000`) está em [02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md).

### 1.1. Diferença entre os três IPs de FLASH

A tabela comparativa está em [flash1port](flash1port.md). Em relação aos outros dois, este IP tem 256 KB por padrão (contra 32 KB), outro arquivo de inicialização (`./flash_init.mif`) e atende o chip, não o núcleo. Não há segunda cópia, porque o chip é o único leitor e as duas leituras do núcleo (instrução e dado) passam pelo chip.

## 2. Interface

### 2.1. Generic

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `size_bytes` | `positive` | 262144 | Tamanho em bytes, potência de dois (256 KB por padrão); define a largura de `address` e o número de palavras |

### 2.2. Portas

| Porta | Direção | Largura | Padrão | Significado |
| :--- | :--- | ---: | :--- | :--- |
| `address` | entrada | $\log_2(\text{size\_bytes}) - 2$ (16 com o padrão) | | Índice da palavra (endereço de byte sem os dois bits baixos) |
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
| `numwords_a` | $\text{size\_bytes} / 4$ (65536 com o padrão) |
| `widthad_a` | $\log_2(\text{size\_bytes}) - 2$ (16 com o padrão) |
| `init_file` | `./flash_init.mif` |
| `outdata_reg_a` | `UNREGISTERED` |
| `read_during_write_mode_port_a` | `NEW_DATA_NO_NBE_READ` |
| `lpm_hint` | `ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=FLASH` |
| `intended_device_family` | `Cyclone V` |

### 3.2. Latência de leitura

O endereço é capturado na borda de `clock` e a saída não tem registrador adicional, então a palavra do endereço aplicado numa borda aparece em `q` depois dela, com um ciclo de latência síncrona. A dica `ENABLE_RUNTIME_MOD` mantém a memória visível ao editor de conteúdo em sistema do Quartus, e a instância aparece com o nome `FLASH`, o que permite regravar o conteúdo por JTAG sem recompilar.

## 4. Integração

O arquivo `src/ROM/Cyclone-V/flash_store1port.qip` registra o IP como "ROM: 1-PORT", versão 20.1, família Cyclone V, e aponta para o VHDL.

| Topo | Instância | Ligação |
| :--- | :--- | :--- |
| Topo da placa DE0-CV (Insper-RISC-V) | `FLASH_STORE` | `address` nos bits 17 a 2 de `o_mem_addr` do chip, `clock` no mesmo clock do chip, `rden` em `'1'`, `wren` em `'0'`, `q` em `i_mem_data` do chip |

No mesmo topo o chip é instanciado com `size_bytes` de 262144, igual ao tamanho padrão deste IP. Na simulação modular o armazenamento do chip é o modelo [rom_simulation](rom_simulation.md).

## 5. Verificação

Nenhuma entrada de `tests/python/tests.json` cobre este IP, porque ele exige a biblioteca `altera_mf` da Intel, ausente da imagem de integração contínua (ver o [README](../../../README.md)). Quem o exercita é a simulação do topo de hardware no repositório Tests. O `make paths` não confere o `.qip` deste IP, porque ele não consta na lista de arquivos Quartus do `paths.yaml`.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
