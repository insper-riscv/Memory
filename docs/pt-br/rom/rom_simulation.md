# rom_simulation

Modelo de simulação da ROM com duas portas de leitura síncronas sobre o mesmo vetor de palavras, inicializado a partir de um arquivo de texto.

## 1. Função do componente no SoC

O modelo substitui, nas simulações em GHDL, os IPs de ROM da placa ([boot_rom](boot_rom.md), [flash](flash.md) e [flash_mem](flash_mem.md)), que dependem da biblioteca `altera_mf` do Quartus. A porta 1 faz o papel do acesso de busca de instruções e a porta 2, com clock próprio, o do acesso de dados do estágio MEM (a segunda cópia física da FLASH no hardware). O vetor é escrito em VHDL puro para que o cocotb consiga lê-lo.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `data_width` | `natural` | 32 | Largura do dado em bits. O conversor de texto produz 32 bits, então o valor útil é 32 |
| `addr_width` | `natural` | 30 | Largura do endereço de palavra em bits |
| `size_bytes` | `positive` | 2048 | Tamanho em bytes, potência de dois (512 palavras). Outro valor aborta a elaboração |
| `rom_file` | `string` | `"initROM.hex"` | Arquivo com o conteúdo, uma palavra de 32 bits por linha em hexadecimal |

### 2.2. Portas

| Porta | Direção | Largura | Padrão | Significado |
| :--- | :--- | ---: | :--- | :--- |
| `i_addr` | entrada | `addr_width` | | Endereço da palavra, porta 1 |
| `i_clk` | entrada | 1 | | Clock da porta 1 |
| `i_re` | entrada | 1 | | Habilita a leitura da porta 1 |
| `o_data` | saída | `data_width` | | Dado lido na porta 1 |
| `i_addr2` | entrada | `addr_width` | zeros | Endereço da palavra, porta 2 |
| `i_clk2` | entrada | 1 | `'0'` | Clock da porta 2 |
| `i_re2` | entrada | 1 | `'0'` | Habilita a leitura da porta 2 |
| `o_data2` | saída | `data_width` | | Dado lido na porta 2 |

## 3. Comportamento

### 3.1. Dimensionamento

O vetor tem $2^{A}$ palavras, com $A = \log_2(\text{size\_bytes}) - 2$. Cada porta usa só os $A$ bits baixos do seu endereço, então um endereço além do tamanho repete o conteúdo desde o início. As posições que o arquivo não preenche valem zero.

### 3.2. Carga do conteúdo

Um processo executado uma vez no início da simulação lê `rom_file` linha a linha e grava as palavras em ordem crescente de índice.

| Situação da linha | Efeito |
| :--- | :--- |
| Com 8 caracteres ou mais | Os 8 primeiros formam a palavra, em hexadecimal com maiúsculas ou minúsculas, e o índice avança |
| Com menos de 8 caracteres | Ignorada, sem avançar o índice |
| Caractere que não é dígito hexadecimal | Convertido em zero |
| Índice além do fim do vetor | Palavra descartada |

### 3.3. Leitura

Cada porta lê na borda de subida do seu clock, quando a habilitação está em `'1'`, e guarda a palavra num registrador de saída. A palavra do endereço aplicado numa borda aparece em `o_data` (ou `o_data2`) depois dela, com um ciclo de latência, como nos IPs `altsyncram`. Com a habilitação em `'0'` a saída mantém o último valor lido. Não há porta de escrita nem reset, e as duas portas podem ler a mesma palavra no mesmo instante.

## 4. Integração

| Topo (Insper-RISC-V) | Instâncias | Uso |
| :--- | :--- | :--- |
| Topo de simulação modular | BOOT_ROM, com a porta 1 | Boot ROM interna |
| Topo de simulação modular | FLASH interna, com as portas 1 (busca) e 2 (dado, clock do estágio MEM) | ROM interna de duas portas |
| Topo de simulação modular | Armazenamento atrás do [flash_chip](flash_chip.md), com `i_re` em `'1'` | ROM externa, de tamanho configurável |

## 5. Verificação

| Entrada de `tests/python/tests.json` | Módulo cocotb | O que cobre |
| :--- | :--- | :--- |
| `ROM` | `tests.python.unittests.sim.rom` | Leituras síncronas de palavras do arquivo `testROM.hex` (parâmetro `ROM_FILE`) e a saída mantida quando a habilitação está em `'0'`, apenas na porta 1 |

A porta 2 não é exercitada por esse teste.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
