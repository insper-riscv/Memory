# rom_simulation

Simulation model of the ROM with two synchronous read ports over the same word vector, initialized from a text file.

## 1. Role of the component in the SoC

In GHDL simulations the model replaces the board ROM IPs ([boot_memory](boot_memory.md) and [flash](flash.md)), which depend on the Quartus `altera_mf` library. Port 1 plays the instruction fetch access and port 2, with its own clock, plays the data access of the MEM stage (port B of the FLASH in hardware). The FLASH model with writes by the loader is [flash_simulation](flash_simulation.md). The vector is written in plain VHDL so that cocotb can read it.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `data_width` | `natural` | 32 | Data width in bits. The text converter produces 32 bits, so the useful value is 32 |
| `addr_width` | `natural` | 30 | Word address width in bits |
| `size_bytes` | `positive` | 2048 | Size in bytes, a power of two (512 words). Any other value aborts elaboration |
| `rom_file` | `string` | `"initROM.hex"` | File with the content, one 32-bit word per line in hexadecimal |

### 2.2. Ports

| Port | Direction | Width | Default | Meaning |
| :--- | :--- | ---: | :--- | :--- |
| `i_addr` | input | `addr_width` | | Word address, port 1 |
| `i_clk` | input | 1 | | Port 1 clock |
| `i_re` | input | 1 | | Port 1 read enable |
| `o_data` | output | `data_width` | | Data read on port 1 |
| `i_addr2` | input | `addr_width` | zeros | Word address, port 2 |
| `i_clk2` | input | 1 | `'0'` | Port 2 clock |
| `i_re2` | input | 1 | `'0'` | Port 2 read enable |
| `o_data2` | output | `data_width` | | Data read on port 2 |

## 3. Behavior

### 3.1. Sizing

The vector has $2^{A}$ words, with $A = \log_2(\text{size\_bytes}) - 2$. Each port uses only the low $A$ bits of its address, so an address past the size repeats the content from the start. Positions the file does not fill are zero.

### 3.2. Content loading

A process that runs once at the start of the simulation reads `rom_file` line by line and writes the words in increasing index order.

| Line situation | Effect |
| :--- | :--- |
| 8 characters or more | The first 8 form the word, in upper or lower case hexadecimal, and the index advances |
| Fewer than 8 characters | Ignored, without advancing the index |
| Character that is not a hexadecimal digit | Converted to zero |
| Index past the end of the vector | Word discarded |

### 3.3. Read

Each port reads on the rising edge of its clock, when the enable is `'1'`, and stores the word in an output register. The word of the address applied on an edge appears on `o_data` (or `o_data2`) after it, with one cycle of latency, as in the `altsyncram` IPs. With the enable at `'0'` the output keeps the last value read. There is no write port and no reset, and both ports may read the same word at the same time.

## 4. Integration

| Top (Insper-RISC-V) | Instances | Use |
| :--- | :--- | :--- |
| Modular simulation top | BOOT_MEMORY, using port 1 | Internal boot memory |
| Modular simulation top | Internal FLASH, using port 1 (fetch) and port 2 (data, MEM stage clock) | Two-port internal ROM |
| Modular simulation top | Storage behind the [flash_chip](flash_chip.md), with `i_re` at `'1'` | External ROM of configurable size |

## 5. Verification

| `tests/python/tests.json` entry | cocotb module | What it covers |
| :--- | :--- | :--- |
| `ROM` | `tests.python.unittests.sim.rom` | Synchronous reads of words from the `testROM.hex` file (parameter `ROM_FILE`) and the output held when the enable is `'0'`, on port 1 only |

Port 2 is not exercised by that test.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
