# sim_util_pkg

Utilidades dos modelos de simulação de memória e dos sistemas de teste, só para simulação.

## 1. Função do componente no SoC

Os modelos de chip da FLASH NOR e da SRAM registram violações das regras do chip do mesmo modo, e o padrão de dados que enche um chip é reproduzido pelos modelos e pelos sistemas de teste. O pacote reúne essas três utilidades, não tem portas nem estado próprio e nunca é sintetizado.

| Bloco | Uso |
| :--- | :--- |
| [nor_flash_model](../rom/nor_flash_model.md) | `tns`, `violate` e `pattern_word` no conteúdo inicial |
| [sram_model](../ram/sram_model.md) | `tns` e `violate` |
| `flash_path_system` (`src/cache/SoC/sim/`) | `pattern_word` no armazenamento de leitura registrada |

## 2. Interface

O pacote não tem generics nem portas.

### 2.1. Função `tns`

| Parâmetro | Tipo | Faixa | Significado |
| :--- | :--- | :--- | :--- |
| `n` | `natural` | 0 a $2^{31}-1$ | Tempo em nanossegundos |
| retorno | `time` | | $n$ nanossegundos |

### 2.2. Função `pattern_word`

| Parâmetro | Tipo | Faixa | Significado |
| :--- | :--- | :--- | :--- |
| `a` | `std_logic_vector(31 downto 0)` | 0 a $2^{32}-1$ | Endereço de byte |
| retorno | `std_logic_vector(31 downto 0)` | | Palavra do padrão no endereço |

$$ \text{pattern\_word}(a) = \left((a \cdot \texttt{0x9E3779B1}) \bmod 2^{32}\right) \oplus \texttt{0x5A5A1234} $$

O byte de endereço $a$ de um chip é o byte 3 de `pattern_word(a)`, e o endereço zero devolve a própria constante de xor.

### 2.3. Procedimento `violate`

| Parâmetro | Classe | Tipo | Significado |
| :--- | :--- | :--- | :--- |
| `o_violation` | sinal, saída | `std_logic` | Saída de violação do modelo, que recebe o pulso |
| `prefix` | constante | `string` | Nome do modelo, prefixo da mensagem |
| `abort` | constante | `boolean` | Verdadeiro para falhar a simulação, falso para só avisar |
| `msg` | constante | `string` | Regra do chip que foi violada |

O procedimento sobe `o_violation` por 1 ns e emite a mensagem `prefix: msg` com severidade `failure` quando `abort` é verdadeiro e `warning` quando é falso. O sinal passado como parâmetro fica com o driver do processo que chamou o procedimento.

## 3. Verificação

| Verificação | Cobertura |
| :--- | :--- |
| Entrada `SimUtilPkg` de `tests/python/tests.json`, módulo `tests.python.unittests.sim.sim_util_pkg`, testbench `tests/vhdl/sim_util_pkg_tb.vhd` | O padrão em endereços de borda; o atraso de `tns` de 20 ns, antes e depois; o pulso de `violate` com `abort` falso e o fim do pulso |
| Entradas `NorFlashModel` e `SramModel` | Os pulsos de violação de cada regra de tempo dos chips |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
