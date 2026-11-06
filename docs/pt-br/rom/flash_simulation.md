# flash_simulation

Modelo de simulação da FLASH interna de duas portas verdadeiras, equivalente ao IP [flash](flash.md), inicializado a partir de um arquivo de texto.

## 1. Função do componente no SoC

O modelo substitui, nas simulações em GHDL, o IP [flash](flash.md), que depende da biblioteca `altera_mf` do Quartus. Tem as mesmas portas e a mesma latência de um ciclo nas duas leituras, e o vetor de palavras é escrito em VHDL puro para que o cocotb consiga lê-lo. A escrita existe só na porta B. O topo `flash_system` liga o modelo ao [flash_loader](flash_loader.md) como o topo da FPGA.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `size_bytes` | `positive` | 32768 | Tamanho em bytes, potência de dois |
| `rom_file` | `string` | vazio | Arquivo com o conteúdo inicial, uma palavra de 32 bits por linha em hexadecimal; vazio deixa a memória zerada |

### 2.2. Portas

As portas são as do IP [flash](flash.md) (`i_clk_a`, `i_address_a`, `i_rden_a`, `o_q_a`, `i_clk_b`, `i_address_b`, `i_rden_b`, `i_wren_b`, `i_data_b`, `o_q_b`).

## 3. Comportamento

Cada porta tem o seu processo, na borda de subida do seu clock. A porta A captura a palavra do endereço quando `i_rden_a` vale `'1'`. A porta B grava `i_data_b` quando `i_wren_b` vale `'1'` e devolve o dado novo na mesma borda, e lê o endereço quando só `i_rden_b` vale `'1'`. As palavras que o arquivo não cobre ficam zeradas. O vetor é alocado no heap durante a leitura do arquivo, então o tamanho não é limitado pela pilha do GHDL e vale para os 256 KB da plataforma `external-data`.

## 4. Verificação

O teste `FlashLoader` usa este modelo dentro do topo `flash_system` (ver [flash_loader](flash_loader.md)), e o `FlashLoaderLarge` repete os mesmos testes com 256 KB, o tamanho da FLASH da plataforma `external-data`.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
