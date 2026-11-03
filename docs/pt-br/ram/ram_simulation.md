# ram_simulation

## 1. Função do componente no SoC

O modelo de simulação da RAM de dados faz, nas simulações com GHDL, o papel da RAM interna do core. É uma memória de uma porta com leitura e escrita síncronas e habilita de bytes, equivalente em contrato ao IP da placa descrito em [ram.md](ram.md). O conteúdo inicial pode vir de um arquivo, que é como a simulação carrega o programa e os dados.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `data_width` | natural | 32 | largura da porta de dados em bits; o vetor interno é sempre de 32 bits, então só o valor 32 é coerente |
| `addr_width` | natural | 30 | largura do endereço de palavra em bits |
| `size_bytes` | positive | 2048 | tamanho da memória em bytes, uma potência de dois (2048 são 512 palavras) |
| `ram_file` | string | vazio | arquivo com o conteúdo inicial, uma palavra de 32 bits por linha em hexadecimal; vazio deixa a RAM zerada |

### 2.2. Portas

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | clock da RAM |
| `i_addr` | entrada | `addr_width` | endereço em índice de palavra |
| `i_data_in` | entrada | `data_width` | dado de escrita |
| `o_data_out` | saída | `data_width` | dado lido, válido no ciclo seguinte ao pedido |
| `i_we_ram` | entrada | 1 | habilita de escrita |
| `i_re_ram` | entrada | 1 | habilita de leitura |
| `i_en_ram` | entrada | 1 | habilita do chip |
| `i_mask` | entrada | 4 | habilita de bytes da escrita, um bit por byte |

## 3. Comportamento

### 3.1. Endereçamento

O índice da palavra são os $\log_2(\text{size\_bytes}) - 2$ bits baixos de `i_addr`, e os bits altos são ignorados. O endereço dá a volta quando excede a memória, ou seja, não há descarte de acesso fora da faixa, ao contrário de [ram_chip.md](ram_chip.md).

### 3.2. Escrita

Na borda de subida de `i_clk`, com `i_we_ram` e `i_en_ram` em `'1'`, cada byte da palavra no índice é substituído pelo byte correspondente de `i_data_in` se o bit de `i_mask` do mesmo número for `'1'`. Os outros bytes mantêm o valor.

### 3.3. Leitura

Na borda de subida de `i_clk`, com `i_re_ram` e `i_en_ram` em `'1'`, o registrador de saída captura a palavra no índice. Sem leitura habilitada, `o_data_out` mantém o valor anterior. Assim a latência de leitura é de 1 ciclo, e uma leitura na mesma borda de uma escrita ao mesmo índice devolve o valor anterior à escrita, pois a palavra nova só aparece depois da borda.

| Operação | Habilitas | Efeito na borda |
| :--- | :--- | :--- |
| escrita | `i_en_ram` e `i_we_ram` | atualiza os bytes habilitados da palavra |
| leitura | `i_en_ram` e `i_re_ram` | `o_data_out` recebe a palavra do índice |
| nenhuma | demais combinações | memória e `o_data_out` não mudam |

### 3.4. Carga do arquivo

Um único processo carrega o arquivo e depois escreve o vetor, para o vetor ter um único driver. Ele lê o arquivo linha a linha, ignora as de menos de 8 caracteres, converte as demais de hexadecimal e grava a palavra no índice corrente, que avança a cada linha de 8 caracteres ou mais; linhas além da última palavra da memória são descartadas. A imagem passa pelo sinal do vetor e não pelo resultado de uma função, porque o GHDL aloca o vetor de uma função na pilha, e uma RAM de $2^{16}$ palavras ou mais excede o limite dela.

## 4. Integração

| Item | Descrição |
| :--- | :--- |
| Instanciado em | `src/simulation/modular/modular_sim_top.vhd` do repositório Insper-RISC-V, quando `ram_external` é falso, com `size_bytes` igual a `ram_size_bytes` e `ram_file` igual a `ram_file` |
| Endereço | `i_addr` recebe os bits 31 a 2 do endereço de byte da RAM do core |
| Clock | `pll_clk_idexmem`, o mesmo dos estágios de instrução, execução e memória |
| Biblioteca | usa `utils_pkg` de Common-Components, para `log2_exact`, que falha a elaboração se `size_bytes` não for potência de dois |

Como o índice usa apenas os bits baixos do endereço, a RAM só enxerga o endereço correto quando sua base no mapa é múltipla do tamanho. O mapa de memória está no contrato de barramento e memória do repositório Core. Com a RAM externa, o papel deste modelo passa ao [ram_chip.md](ram_chip.md).

## 5. Verificação

A entrada `RAM` de `tests/python/tests.json` compila o modelo com `utils_pkg.vhd` e roda `tests/python/unittests/ram/ram_simulation.py`, com `--std=08` e `-fsynopsys`.

| Teste | Verifica |
| :--- | :--- |
| `sw_fullword` | escrita de palavra inteira com máscara `1111` e leitura de volta |
| `all_masks` | todas as máscaras de escrita parcial |
| `disable_read` | sem `i_re_ram` ou sem `i_en_ram`, a saída não muda |
| `multi_positions` | escritas em posições diferentes e leituras |
| `overwrite` | sobrescrita e leitura do valor novo |

Não há prova formal deste bloco.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
