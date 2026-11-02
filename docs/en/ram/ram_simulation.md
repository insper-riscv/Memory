# ram_simulation

## 1. Role of the component in the SoC

The data RAM simulation model plays, in GHDL simulations, the role of the internal RAM of the core. It is a single-port memory with synchronous read and write and byte enables, equivalent in contract to the board IP described in [ram1port.md](ram1port.md). The initial content can come from a file, which is how the simulation loads the program and the data.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `data_width` | natural | 32 | data port width in bits; the internal vector is always 32 bits, so only the value 32 is coherent |
| `addr_width` | natural | 30 | word address width in bits |
| `size_bytes` | positive | 2048 | memory size in bytes, a power of two (2048 are 512 words) |
| `ram_file` | string | empty | file with the initial content, one 32-bit word per line in hexadecimal; empty leaves the RAM zeroed |

### 2.2. Ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | RAM clock |
| `i_addr` | input | `addr_width` | address as a word index |
| `i_data_in` | input | `data_width` | write data |
| `o_data_out` | output | `data_width` | read data, valid in the cycle after the request |
| `i_we_ram` | input | 1 | write enable |
| `i_re_ram` | input | 1 | read enable |
| `i_en_ram` | input | 1 | chip enable |
| `i_mask` | input | 4 | byte enables of the write, one bit per byte |

## 3. Behavior

### 3.1. Addressing

The word index is the low $\log_2(\text{size\_bytes}) - 2$ bits of `i_addr`, and the high bits are ignored. The address wraps when it exceeds the memory, that is, an out-of-range access is not dropped, unlike [ram_chip.md](ram_chip.md).

### 3.2. Write

On the rising edge of `i_clk`, with `i_we_ram` and `i_en_ram` at `'1'`, each byte of the word at the index is replaced by the matching byte of `i_data_in` if the bit of `i_mask` with the same number is `'1'`. The other bytes keep their value.

### 3.3. Read

On the rising edge of `i_clk`, with `i_re_ram` and `i_en_ram` at `'1'`, the output register captures the word at the index. Without read enable, `o_data_out` keeps its previous value. The read latency is therefore 1 cycle, and a read on the same edge as a write to the same index returns the value from before the write, since the new word only appears after the edge.

| Operation | Enables | Effect on the edge |
| :--- | :--- | :--- |
| write | `i_en_ram` and `i_we_ram` | updates the enabled bytes of the word |
| read | `i_en_ram` and `i_re_ram` | `o_data_out` receives the word at the index |
| none | other combinations | memory and `o_data_out` do not change |

### 3.4. File load

A single process loads the file and then writes the vector, so the vector has a single driver. It reads the file line by line, ignores lines shorter than 8 characters, converts the others from hexadecimal and stores the word at the current index, which advances at every line of 8 characters or more; lines beyond the last word of the memory are discarded. The image goes through the vector signal and not through a function result, because GHDL allocates a function's vector on the stack, and a RAM of $2^{16}$ words or more exceeds its limit.

## 4. Integration

| Item | Description |
| :--- | :--- |
| Instantiated in | `src/simulation/modular/modular_sim_top.vhd` of the Insper-RISC-V repository, when `ram_external` is false, with `size_bytes` equal to `ram_size_bytes` and `ram_file` equal to `ram_file` |
| Address | `i_addr` receives bits 31 to 2 of the core RAM byte address |
| Clock | `pll_clk_idexmem`, the same as the instruction, execute and memory stages |
| Library | uses `utils_pkg` from Common-Components, for `log2_exact`, which fails elaboration if `size_bytes` is not a power of two |

Since the index uses only the low bits of the address, the RAM sees the right address only when its base in the map is a multiple of its size. The memory map is in the bus and memory contract of the Core repository. With an external RAM, the role of this model passes to [ram_chip.md](ram_chip.md).

## 5. Verification

The `RAM` entry of `tests/python/tests.json` builds the model with `utils_pkg.vhd` and runs `tests/python/unittests/ram/ram_simulation.py`, with `--std=08` and `-fsynopsys`.

| Test | Checks |
| :--- | :--- |
| `sw_fullword` | full-word write with mask `1111` and read back |
| `all_masks` | every partial-write mask |
| `disable_read` | without `i_re_ram` or without `i_en_ram`, the output does not change |
| `multi_positions` | writes at different positions and reads |
| `overwrite` | overwrite and read of the new value |

There is no formal proof of this block.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
