# Leituras de byte, meia palavra e palavra da SDRAM

## 1. A memória só conhece palavras

A SDRAM é um chip de 16 bits e o core fala com ela por uma interface de palavra de 32 bits. Uma palavra são dois beats de 16 bits de uma rajada. O endereço que chega ao controlador é o endereço de byte sem os dois bits baixos, então uma leitura sempre busca a palavra alinhada inteira que contém o byte pedido.

| Instrução do core | Tamanho pedido | Endereço enviado ao controlador | Bits que voltam |
| :--- | :--- | :--- | :--- |
| `lw` | 4 bytes | `addr / 4` | 32 |
| `lh`, `lhu` | 2 bytes | `addr / 4` | 32 |
| `lb`, `lbu` | 1 byte | `addr / 4` | 32 |

O controlador e a ponte nunca sabem qual instrução fez o pedido. O lado da leitura não tem habilitação de bytes, então nada no caminho do chip estreita uma leitura.

## 2. Onde os bytes certos são escolhidos

O estreitamento é feito no core, no estágio de write-back, depois de a palavra voltar. Duas entradas o conduzem.

| Entrada | Significado |
| :--- | :--- |
| `EA` | Os dois bits baixos do endereço de byte, que dizem onde os bytes desejados estão dentro da palavra |
| Tipo do load | `lw`, `lh`, `lhu`, `lb` ou `lbu`, que diz quantos bytes manter e como preencher os bits altos |

A memória é little-endian, então o byte no deslocamento 0 está nos bits 7:0 da palavra.

| `EA` | Byte na palavra | Meia palavra na palavra |
| :--- | :--- | :--- |
| `00` | bits 7:0 | bits 15:0 |
| `01` | bits 15:8 | não alinhada |
| `10` | bits 23:16 | bits 31:16 |
| `11` | bits 31:24 | não alinhada |

Uma meia palavra é escolhida só por `EA(1)`, porque uma meia palavra alinhada começa num deslocamento par.

## 3. Como o resultado de 32 bits é preenchido

O que foi escolhido vai para os bits baixos do resultado, e os bits altos são preenchidos pelo tipo do load.

| Load | Resultado de 32 bits | Bits altos |
| :--- | :--- | :--- |
| `lw` | A palavra como veio | Nenhum, os 32 bits são dado |
| `lh` | A meia palavra escolhida | Cópias do bit 15 da meia palavra (extensão de sinal) |
| `lhu` | A meia palavra escolhida | Zeros |
| `lb` | O byte escolhido | Cópias do bit 7 do byte (extensão de sinal) |
| `lbu` | O byte escolhido | Zeros |

Em equações, com $b$ o byte escolhido e $h$ a meia palavra escolhida:

$$
\text{lb} = \{\,24\{b_7\},\; b\,\},\qquad \text{lbu} = \{\,24\{0\},\; b\,\}
$$

$$
\text{lh} = \{\,16\{h_{15}\},\; h\,\},\qquad \text{lhu} = \{\,16\{0\},\; h\,\}
$$

Os bytes da palavra que não foram escolhidos nunca chegam ao registrador. Um `lbu` no deslocamento 1 não vaza os bytes vizinhos, e um `lb` só reutiliza o próprio bit de sinal acima do byte.

## 4. Exemplos

Todos os exemplos leem a mesma palavra da SDRAM, guardada num endereço `A` alinhado em palavra.

$$
\text{word} = \texttt{0xA1B2C3D4}
$$

| Deslocamento | Byte | Meia palavra |
| :--- | :--- | :--- |
| 0 | `D4` | `C3D4` |
| 1 | `C3` | não alinhada |
| 2 | `B2` | `A1B2` |
| 3 | `A1` | não alinhada |

### 4.1 Bytes

| Instrução | `EA` | Bits escolhidos | Resultado |
| :--- | :--- | :--- | :--- |
| `lbu` em `A+0` | `00` | 7:0 = `D4` | `0x000000D4` |
| `lb` em `A+0` | `00` | 7:0 = `D4` | `0xFFFFFFD4` |
| `lbu` em `A+1` | `01` | 15:8 = `C3` | `0x000000C3` |
| `lb` em `A+1` | `01` | 15:8 = `C3` | `0xFFFFFFC3` |
| `lbu` em `A+2` | `10` | 23:16 = `B2` | `0x000000B2` |
| `lb` em `A+3` | `11` | 31:24 = `A1` | `0xFFFFFFA1` |

A extensão de sinal depende do bit 7 do byte. `D4` é `1101 0100`, então o bit 7 vale 1 e os 24 bits altos do `lb` são uns. Com um byte cujo bit 7 vale 0, `lb` e `lbu` dão o mesmo valor.

| Palavra na SDRAM | Instrução | Byte | Resultado |
| :--- | :--- | :--- | :--- |
| `0x1122337F` | `lb` em `A+0` | `7F` | `0x0000007F` |
| `0x1122337F` | `lbu` em `A+0` | `7F` | `0x0000007F` |
| `0x1122337F` | `lb` em `A+3` | `11` | `0x00000011` |

### 4.2 Meias palavras

| Instrução | `EA` | Bits escolhidos | Resultado |
| :--- | :--- | :--- | :--- |
| `lhu` em `A+0` | `00` | 15:0 = `C3D4` | `0x0000C3D4` |
| `lh` em `A+0` | `00` | 15:0 = `C3D4` | `0xFFFFC3D4` |
| `lhu` em `A+2` | `10` | 31:16 = `A1B2` | `0x0000A1B2` |
| `lh` em `A+2` | `10` | 31:16 = `A1B2` | `0xFFFFA1B2` |

### 4.3 Palavra

| Instrução | `EA` | Resultado |
| :--- | :--- | :--- |
| `lw` em `A` | `00` | `0xA1B2C3D4` |

## 5. Alinhamento

Só os acessos alinhados são definidos.

| Acesso | Definido |
| :--- | :--- |
| `lb`, `lbu` em qualquer deslocamento | sim |
| `lh`, `lhu` no deslocamento 0 ou 2 | sim |
| `lh`, `lhu` no deslocamento 3, que cruza a palavra | não |
| `lw` num endereço que não é múltiplo de 4 | não |

Num acesso não definido nada levanta exceção. Um `lw` desalinhado devolve a palavra alinhada abaixo do endereço, e um `lh` no deslocamento 3 não busca a palavra seguinte. Os compiladores emitem acessos alinhados, e as cópias byte a byte cobrem o resto.

## 6. O lado da escrita

Uma escrita não pode buscar, alterar e guardar de volta, então ela leva a informação de que uma leitura não precisa.

| Passo | O que acontece |
| :--- | :--- |
| 1 | O estágio de store move o dado para a faixa de byte dada por `EA` |
| 2 | Ele levanta uma habilitação de byte para cada byte escrito, 4 bits para uma palavra |
| 3 | O controlador transforma as habilitações nas máscaras de dado do chip, dois bits por beat de 16 bits, ativas em nível baixo |

Os bytes com a habilitação desligada não são tocados no chip. Um `sb` no deslocamento 2 muda só os bits 23:16 da palavra guardada.

| Store | Habilitações (byte 3 a byte 0) | Bytes escritos |
| :--- | :--- | :--- |
| `sb` em `A+0` | `0001` | byte 0 |
| `sb` em `A+2` | `0100` | byte 2 |
| `sh` em `A+0` | `0011` | bytes 0 e 1 |
| `sh` em `A+2` | `1100` | bytes 2 e 3 |
| `sw` em `A` | `1111` | os quatro |

A leitura não tem máscara, então ela sempre move 32 bits e a seleção acontece depois dela.

## 7. Onde está implementado

| Parte | VHDL |
| :--- | :--- |
| Seleção e extensão do load (seções 2 e 3) | [`extender_ram.vhd`](https://github.com/insper-riscv/Core/blob/main/src/I/extender_ram.vhd) |
| Faixa do store e habilitações de byte (seção 6) | [`store_manager.vhd`](https://github.com/insper-riscv/Core/blob/main/src/I/store_manager.vhd) |
| Habilitações de byte para as máscaras de dado do chip, e os dois beats de uma palavra (seções 1 e 6) | [`sdram_ctrl.vhd`](../../../src/RAM/SoC/sdram/sdram_ctrl.vhd) |
| Endereço de palavra e cruzamento de clock entre o core e o controlador (seção 1) | [`sdram_cpu_bridge.vhd`](../../../src/RAM/SoC/sdram/sdram_cpu_bridge.vhd) |
