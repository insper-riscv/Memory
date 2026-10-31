# Byte, half-word and word reads from the SDRAM

## 1. The memory only knows words

The SDRAM is a 16-bit chip and the core talks to it through a 32-bit word interface. A word is two 16-bit beats of one burst. The address that reaches the controller is the byte address with its two low bits dropped, so a read always fetches the whole aligned word that contains the byte asked for.

| Core instruction | Size asked | Address sent to the controller | Bits that come back |
| :--- | :--- | :--- | :--- |
| `lw` | 4 bytes | `addr / 4` | 32 |
| `lh`, `lhu` | 2 bytes | `addr / 4` | 32 |
| `lb`, `lbu` | 1 byte | `addr / 4` | 32 |

The controller and the bridge never learn which instruction made the request. The read side has no byte enables, so nothing in the chip path narrows a read.

## 2. Where the right bytes are picked

The narrowing is done in the core, in the write-back stage, after the word has returned. Two things drive it.

| Input | Meaning |
| :--- | :--- |
| `EA` | the two low bits of the byte address, which say where the wanted bytes sit inside the word |
| Load kind | `lw`, `lh`, `lhu`, `lb` or `lbu`, which says how many bytes to keep and how to fill the upper bits |

Memory is little-endian, so the byte at offset 0 is in bits 7:0 of the word.

| `EA` | Byte in the word | Half-word in the word |
| :--- | :--- | :--- |
| `00` | bits 7:0 | bits 15:0 |
| `01` | bits 15:8 | not aligned |
| `10` | bits 23:16 | bits 31:16 |
| `11` | bits 31:24 | not aligned |

A half-word is selected by `EA(1)` alone, because an aligned half-word starts at an even offset.

## 3. How the 32-bit result is filled

Whatever is selected is placed in the low bits of the result, and the upper bits are filled by the load kind.

| Load | Result of 32 bits | Upper bits |
| :--- | :--- | :--- |
| `lw` | the word as it came | none, all 32 bits are data |
| `lh` | selected half-word | copies of bit 15 of the half-word (sign extension) |
| `lhu` | selected half-word | zeros |
| `lb` | selected byte | copies of bit 7 of the byte (sign extension) |
| `lbu` | selected byte | zeros |

In equations, with $b$ the selected byte and $h$ the selected half-word:

$$
\text{lb} = \{\,24\{b_7\},\; b\,\},\qquad \text{lbu} = \{\,24\{0\},\; b\,\}
$$

$$
\text{lh} = \{\,16\{h_{15}\},\; h\,\},\qquad \text{lhu} = \{\,16\{0\},\; h\,\}
$$

The bytes of the word that were not selected never reach the register. A `lbu` of offset 1 does not leak the neighbouring bytes, and a `lb` only reuses its own sign bit above the byte.

## 4. Examples

All examples read the same word in the SDRAM, stored at a word-aligned address `A`.

$$
\text{word} = \texttt{0xA1B2C3D4}
$$

| Offset | Byte | Half-word |
| :--- | :--- | :--- |
| 0 | `D4` | `C3D4` |
| 1 | `C3` | not aligned |
| 2 | `B2` | `A1B2` |
| 3 | `A1` | not aligned |

### 4.1 Bytes

| Instruction | `EA` | Selected bits | Result |
| :--- | :--- | :--- | :--- |
| `lbu` at `A+0` | `00` | 7:0 = `D4` | `0x000000D4` |
| `lb` at `A+0` | `00` | 7:0 = `D4` | `0xFFFFFFD4` |
| `lbu` at `A+1` | `01` | 15:8 = `C3` | `0x000000C3` |
| `lb` at `A+1` | `01` | 15:8 = `C3` | `0xFFFFFFC3` |
| `lbu` at `A+2` | `10` | 23:16 = `B2` | `0x000000B2` |
| `lb` at `A+3` | `11` | 31:24 = `A1` | `0xFFFFFFA1` |

The sign extension depends on bit 7 of the byte. `D4` is `1101 0100`, so bit 7 is 1 and the upper 24 bits of `lb` are ones. With a byte whose bit 7 is 0, `lb` and `lbu` give the same value.

| Word in the SDRAM | Instruction | Byte | Result |
| :--- | :--- | :--- | :--- |
| `0x1122337F` | `lb` at `A+0` | `7F` | `0x0000007F` |
| `0x1122337F` | `lbu` at `A+0` | `7F` | `0x0000007F` |
| `0x1122337F` | `lb` at `A+3` | `11` | `0x00000011` |

### 4.2 Half-words

| Instruction | `EA` | Selected bits | Result |
| :--- | :--- | :--- | :--- |
| `lhu` at `A+0` | `00` | 15:0 = `C3D4` | `0x0000C3D4` |
| `lh` at `A+0` | `00` | 15:0 = `C3D4` | `0xFFFFC3D4` |
| `lhu` at `A+2` | `10` | 31:16 = `A1B2` | `0x0000A1B2` |
| `lh` at `A+2` | `10` | 31:16 = `A1B2` | `0xFFFFA1B2` |

### 4.3 Word

| Instruction | `EA` | Result |
| :--- | :--- | :--- |
| `lw` at `A` | `00` | `0xA1B2C3D4` |

## 5. Alignment

Only aligned accesses are defined.

| Access | Defined |
| :--- | :--- |
| `lb`, `lbu` at any offset | yes |
| `lh`, `lhu` at offset 0 or 2 | yes |
| `lh`, `lhu` at offset 3, which crosses the word | no |
| `lw` at an address that is not a multiple of 4 | no |

For an undefined access nothing raises an exception. A misaligned `lw` returns the aligned word below the address, and a `lh` at offset 3 does not fetch the next word. Compilers emit aligned accesses, and byte-wise copies cover the rest.

## 6. The write side

A write cannot fetch, change and store back, so it carries the information a read does not need.

| Step | What happens |
| :--- | :--- |
| 1 | The store stage moves the data to the byte lane given by `EA` |
| 2 | It raises one byte enable per byte that is written, 4 bits for a word |
| 3 | The controller turns the enables into the chip's data masks, two bits per 16-bit beat, active low |

The bytes with the enable off are not touched in the chip. A `sb` at offset 2 changes only bits 23:16 of the stored word.

| Store | Enables (byte 3 to byte 0) | Bytes written |
| :--- | :--- | :--- |
| `sb` at `A+0` | `0001` | byte 0 |
| `sb` at `A+2` | `0100` | byte 2 |
| `sh` at `A+0` | `0011` | bytes 0 and 1 |
| `sh` at `A+2` | `1100` | bytes 2 and 3 |
| `sw` at `A` | `1111` | all four |

The read has no mask, so a read always moves 32 bits and the selection happens after it.

## 7. Where it is implemented

| Part | VHDL |
| :--- | :--- |
| Load selection and extension (sections 2 and 3) | [`ExtenderRAM.vhd`](https://github.com/insper-riscv/Core/blob/main/I/ExtenderRAM.vhd) |
| Store lane and byte enables (section 6) | [`StoreManager.vhd`](https://github.com/insper-riscv/Core/blob/main/I/StoreManager.vhd) |
| Byte enables to the chip's data masks, and the two beats of a word (sections 1 and 6) | [`sdram_ctrl.vhd`](../external/sdram/sdram_ctrl.vhd) |
| Word address and clock crossing between the core and the controller (section 1) | [`sdram_cpu_bridge.vhd`](../external/sdram/sdram_cpu_bridge.vhd) |
