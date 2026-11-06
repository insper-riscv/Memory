# flash

IP interno de memória de duas portas verdadeiras que guarda o programa de teste (a FLASH interna) numa só cópia, lida pelo estágio de busca de instruções e pelo estágio MEM e escrita pelo carregador.

## 1. Função do componente no SoC

A FLASH interna começa logo depois da BOOT_MEMORY e vai até o início da RAM (`0x00001000` até `0x00007FFF` no mapa padrão, ver [02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md)). A porta A atende o estágio de busca de instruções (IF). A porta B atende o estágio MEM, que lê a FLASH como dado (por exemplo para copiar a seção `.data` na inicialização), e o carregador [flash_loader](flash_loader.md), que a escreve. O núcleo só lê, porque a escrita existe apenas na porta B e o carregador a habilita só com o núcleo parado.

O endereço de busca indexa o IP direto, sem subtrair a base, então o IP cobre todo o intervalo de zero até o início da RAM e não só a faixa lógica da FLASH (32 KB de IP para 28 KB de FLASH). A imagem de cada teste é preenchida à esquerda com zeros até a base da FLASH antes de virar `.mif`.

### 1.1. Diferença entre os IPs de FLASH

| IP | Papel | Tamanho padrão | Arquivo de inicialização | Regravação |
| :--- | :--- | ---: | :--- | :--- |
| [flash](flash.md) | Única cópia da FLASH interna, duas portas | 32 KB | `./init.mif` | Carregador JTAG ([flash_loader](flash_loader.md)) |
| [flash_store](flash_store.md) | Armazenamento atrás do chip [flash_chip](flash_chip.md) | 256 KB | `./flash_init.mif` | Editor de conteúdo em sistema, instância `FLASH` |

## 2. Interface

### 2.1. Generic

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `size_bytes` | `positive` | 32768 | Tamanho em bytes, potência de dois (32 KB por padrão); define a largura dos endereços e o número de palavras |

### 2.2. Portas

| Porta | Direção | Largura | Padrão | Significado |
| :--- | :--- | ---: | :--- | :--- |
| `i_clk_a` | entrada | 1 | `'1'` | Clock da porta A |
| `i_address_a` | entrada | $\log_2(\text{size\_bytes}) - 2$ (13 com o padrão) | | Índice da palavra lida pela porta A (endereço de byte sem os dois bits baixos) |
| `i_rden_a` | entrada | 1 | `'1'` | Habilita a leitura da porta A |
| `o_q_a` | saída | 32 | | Palavra lida pela porta A |
| `i_clk_b` | entrada | 1 | `'1'` | Clock da porta B |
| `i_address_b` | entrada | $\log_2(\text{size\_bytes}) - 2$ | | Índice da palavra acessada pela porta B |
| `i_rden_b` | entrada | 1 | `'1'` | Habilita a leitura da porta B |
| `i_wren_b` | entrada | 1 | `'0'` | Habilita a escrita da porta B |
| `i_data_b` | entrada | 32 | zeros | Dado de escrita da porta B |
| `o_q_b` | saída | 32 | | Palavra lida pela porta B |

## 3. Comportamento

### 3.1. Instância da memória em bloco

A memória é por uma instância de [block_ram](../block_ram/block_ram.md), que encapsula o `altsyncram` da biblioteca `altera_mf` do Quartus, e os demais parâmetros do megafunção ficam fixos nela. Os generics passados à instância são:

| Generic | Valor |
| :--- | :--- |
| `operation_mode` | `BIDIR_DUAL_PORT` |
| `word_count` | $\text{size\_bytes} / 4$ (8192 com o padrão) |
| `address_width` | $\log_2(\text{size\_bytes}) - 2$ (13 com o padrão) |
| `block_depth` | 2048 (`maximum_depth` do megafunção) |
| `init_file` | `./init.mif` |

A instância não recebe `instance_name`, então não tem a dica `ENABLE_RUNTIME_MOD`, porque o Quartus Lite não a aceita em duas portas, então o editor de conteúdo em sistema não enxerga esta memória. A regravação passa pelo carregador.

### 3.2. Latência de leitura

O endereço é capturado na borda do clock da porta e a saída não tem registrador adicional, então a palavra do endereço aplicado numa borda aparece na saída depois dela, com um ciclo de latência síncrona, nas duas portas.

### 3.3. Ocupação de blocos

O parâmetro `maximum_depth` limita cada bloco a 2048 palavras, e o Quartus passa a usar o modo 2048x5 do M10K, o mais denso em duas portas verdadeiras para uma palavra de 32 bits. Sem ele o Quartus escolhe o modo 8192x1, que desperdiça bits.

Os valores abaixo são os do relatório do Fitter para o Cyclone V 5CEBA4F23C7.

| Tamanho | Palavras | Blocos M10K com `maximum_depth` 2048 | Blocos M10K sem o parâmetro |
| ---: | ---: | ---: | ---: |
| 32 KB | 8192 | 28 | 32 |
| 252 KB | 64512 | 221 | 256 |

## 4. Integração

O arquivo `src/ROM/Cyclone-V/flash.qip` lista o `block_ram.vhd` e o VHDL do IP, sem marca de família.

| Topo | Instância | Ligação |
| :--- | :--- | :--- |
| Topo de teste de FPGA da plataforma de memória interna (Insper-RISC-V) | `FLASH` | Porta A no endereço de busca (bits 14 a 2) e no clock do estágio IF; porta B nas saídas do carregador [flash_loader](flash_loader.md), que repassa o endereço do estágio MEM enquanto o núcleo roda |

Na simulação em GHDL o modelo equivalente é [flash_simulation](flash_simulation.md).

## 5. Verificação

Nenhuma entrada de `tests/python/tests.json` cobre este IP, porque ele exige a biblioteca `altera_mf` da Intel, ausente da imagem de integração contínua (ver o [README](../../../README.md)). O modelo equivalente é coberto pelo teste `FlashLoader`, e a simulação do topo de hardware no repositório Tests exercita o IP. O `make paths` confere a existência do `.qip`.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
