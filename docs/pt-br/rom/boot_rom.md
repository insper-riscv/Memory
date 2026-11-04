# boot_rom

IP interno de ROM de uma porta que guarda o programa de inicialização do SoC (a BOOT_ROM).

## 1. Função do componente no SoC

A BOOT_ROM ocupa o início do espaço de endereços (`0x00000000` até `0x00000FFF` no mapa padrão, ver [02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md)) e entrega ao estágio de busca a instrução do PC quando ele aponta para essa faixa. O conteúdo vem do arquivo de inicialização gravado na compilação completa do Quartus; segundo o cabeçalho do VHDL, nenhum teste o regrava por JTAG, ao contrário da FLASH ([flash](flash.md)). A BOOT_ROM não passa pela cache de instruções.

## 2. Interface

### 2.1. Generic

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `size_bytes` | `positive` | 4096 | Tamanho em bytes, potência de dois; define a largura de `i_address` e o número de palavras |

### 2.2. Portas

| Porta | Direção | Largura | Padrão | Significado |
| :--- | :--- | ---: | :--- | :--- |
| `i_address` | entrada | $\log_2(\text{size\_bytes}) - 2$ | | Índice da palavra (endereço de byte sem os dois bits baixos) |
| `i_clk` | entrada | 1 | `'1'` | Clock da memória |
| `i_rden` | entrada | 1 | `'1'` | Habilita a leitura |
| `i_wren` | entrada | 1 | `'0'` | Habilita a escrita |
| `i_data` | entrada | 32 | zeros | Dado de escrita |
| `o_q` | saída | 32 | | Palavra lida |

## 3. Comportamento

### 3.1. Configuração da biblioteca

A leitura é feita pela instância `altsyncram` da biblioteca `altera_mf`, que é do Quartus e não faz parte deste repositório. Os parâmetros fixados no VHDL são:

| Parâmetro | Valor |
| :--- | :--- |
| `operation_mode` | `SINGLE_PORT` |
| `width_a` | 32 |
| `numwords_a` | $\text{size\_bytes} / 4$ (1024 com o padrão) |
| `widthad_a` | $\log_2(\text{size\_bytes}) - 2$ (10 com o padrão) |
| `init_file` | `./boot_rom_init.mif` |
| `outdata_reg_a` | `UNREGISTERED` |
| `read_during_write_mode_port_a` | `NEW_DATA_NO_NBE_READ` |
| `lpm_hint` | `ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=BOOT_ROM` |
| `intended_device_family` | `Cyclone V` |

### 3.2. Latência de leitura

O endereço é capturado na borda de `i_clk` e a saída não tem registrador adicional, então a palavra do endereço aplicado numa borda aparece em `o_q` depois dela, com um ciclo de latência síncrona. A dica de edição em tempo de execução (`ENABLE_RUNTIME_MOD`) mantém a memória visível ao editor de conteúdo em sistema do Quartus, e a instância aparece com o nome `BOOT_ROM`.

### 3.3. Arquivo de inicialização

O `.mif` é gerado pelo fluxo de compilação da placa a partir do código de boot da plataforma. O tamanho do IP deve concordar com o limite da BOOT_ROM configurado no núcleo e no arquivo de configuração da plataforma.

## 4. Integração

O arquivo `.qip` (`src/ROM/Cyclone-V/boot_rom.qip`) registra o IP como "ROM: 1-PORT", versão 20.1, família Cyclone V, e aponta para o VHDL.

| Topo | Instância | Ligação |
| :--- | :--- | :--- |
| Topo da placa DE0-CV (Insper-RISC-V) | `BOOT_ROM` | `i_address` nos bits 11 a 2 do endereço de busca, `i_clk` no clock do estágio IF, `i_rden` na habilitação de busca, `i_wren` em `'0'`, `o_q` no dado da Boot ROM do núcleo |

Na simulação em GHDL o modelo de simulação equivalente é [rom_simulation](rom_simulation.md).

## 5. Verificação

Nenhuma entrada de `tests/python/tests.json` cobre este IP, porque ele exige a biblioteca `altera_mf` da Intel, ausente da imagem de integração contínua (ver o [README](../../../README.md)). Quem o exercita é a simulação do topo de hardware no repositório Tests. O `make paths` confere a existência do `.qip`.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
