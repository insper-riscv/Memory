# flash1port

IP interno de ROM de uma porta que guarda o programa de teste (a FLASH interna) lido pelo estágio de busca de instruções.

## 1. Função do componente no SoC

A FLASH interna começa logo depois da BOOT_ROM e vai até o início da RAM (`0x00000800` até `0x00007FFF` no mapa padrão, ver [02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md)). Esta cópia atende o estágio de busca de instruções (IF). O endereço de busca indexa o IP direto, sem subtrair a base, então o IP cobre todo o intervalo de zero até o início da RAM e não só a faixa lógica da FLASH (32 KB de IP para 30 KB de FLASH). Segundo o cabeçalho do VHDL, a imagem de cada teste é preenchida à esquerda com zeros até a base da FLASH antes de virar `.mif`.

### 1.1. Diferença entre os três IPs de FLASH

| IP | Papel | Tamanho padrão | Arquivo de inicialização | Nome da instância |
| :--- | :--- | ---: | :--- | :--- |
| [flash1port](flash1port.md) | Cópia lida pelo estágio IF do núcleo | 32 KB | `./init.mif` | `FLASH` |
| [flash_mem1port](flash_mem1port.md) | Segunda cópia física, lida pelo estágio MEM como dado | 32 KB | `./init.mif` | `FLASH_MEM` |
| [flash_store1port](flash_store1port.md) | Armazenamento atrás do chip [flash_chip](flash_chip.md) | 256 KB | `./flash_init.mif` | `FLASH` |

Os três usam a mesma receita de `altsyncram`. As duas cópias internas precisam ter sempre o mesmo conteúdo, e o nome de instância distinto é o que faz o editor de conteúdo tratar cada uma como instância JTAG separada.

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
| `lpm_hint` | `ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=FLASH` |
| `intended_device_family` | `Cyclone V` |

### 3.2. Latência de leitura

O endereço é capturado na borda de `clock` e a saída não tem registrador adicional, então a palavra do endereço aplicado numa borda aparece em `q` depois dela, com um ciclo de latência síncrona. A dica `ENABLE_RUNTIME_MOD` mantém a memória visível ao editor de conteúdo em sistema do Quartus, e a instância aparece com o nome `FLASH`, o que permite regravar o conteúdo por JTAG sem recompilar.

## 4. Integração

O arquivo `src/rom/cyclone-v/flash1port.qip` registra o IP como "ROM: 1-PORT", versão 20.1, família Cyclone V, e aponta para o VHDL.

| Topo | Instância | Ligação |
| :--- | :--- | :--- |
| Topo de teste de FPGA da plataforma de memória interna (Insper-RISC-V) | `FLASH` | `address` nos bits 14 a 2 do endereço de busca, `clock` no clock do estágio IF, `rden` na habilitação de busca, `wren` em `'0'`, `q` no dado de instrução da FLASH |

A ferramenta de carga regrava este IP e o [flash_mem1port](flash_mem1port.md) pelo editor de conteúdo em sistema a cada troca de teste, segundo o cabeçalho do VHDL. Na simulação em GHDL o modelo equivalente é [rom_simulation](rom_simulation.md).

## 5. Verificação

Nenhuma entrada de `tests/python/tests.json` cobre este IP, porque ele exige a biblioteca `altera_mf` da Intel, ausente da imagem de integração contínua (ver o [README](../../../README.md)). Quem o exercita é a simulação do topo de hardware no repositório Tests. O `make paths` confere a existência do `.qip`.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
