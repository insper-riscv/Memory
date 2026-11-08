# ram

## 1. Role of the component in the SoC

The internal RAM IP is the data memory of the core when the RAM sits inside the FPGA. It is a single-port memory with synchronous read and write and byte enables, implemented in device memory blocks by an instance of [block_ram](../block_ram/block_ram.md), which wraps the `altsyncram` megafunction of Quartus' `altera_mf` library (outside this repository). According to the README of the repository, the IPs also simulate in GHDL through Intel's `altera_mf` models, and the general-purpose simulation model of the RAM is the one described in [ram_simulation.md](ram_simulation.md).

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `size_bytes` | positive | 262144 | addressable window size in bytes, a power of two |
| `word_count` | positive | 65536 | number of physically implemented 32-bit words |

With $S$ equal to `size_bytes`, the word address has $\log_2 S - 2$ bits. With $N$ equal to `word_count`, the memory implements $N$ words and requires $N \le S / 4$. This separation allows a physical depth that is not a power of two without reducing the address width.

### 2.2. Ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_address` | input | $\log_2 S - 2$ | word address |
| `i_byteena` | input | 4 | byte enables of the write, default `1111` |
| `i_clk` | input | 1 | single memory clock, default `'1'` |
| `i_data` | input | 32 | write data |
| `i_rden` | input | 1 | read enable, default `'1'` |
| `i_wren` | input | 1 | write enable |
| `o_q` | output | 32 | read data |

With the default 256 KB, the address has 16 bits.

## 3. Behavior

### 3.1. `block_ram` instance

| Generic | Value | Effect |
| :--- | :--- | :--- |
| `operation_mode` | `SINGLE_PORT` | one read and write port |
| `word_count` | `word_count` | number of physically implemented words |
| `address_width` | $\log_2$ `size_bytes` $- 2$ | address width |
| `byte_lanes` | 4 | four byte lanes of 8 bits |
| `instance_name` | `RAM` | the content can be read and rewritten over JTAG with the Quartus memory content editor, through the instance named `RAM` |

`block_ram` fixes the rest: unregistered output (`UNREGISTERED`), no clock enable (`BYPASS`), no asynchronous reset of the output, a read at the address of a write returning the new data (`NEW_DATA_NO_NBE_READ`) and a memory that starts zeroed (`power_up_uninitialized` at `FALSE`).

### 3.2. Latency

The address, the data and the enables are captured on the rising edge of `i_clk`, and the output has no register, so `o_q` presents the read word right after that edge, which makes the read latency 1 cycle. The core contract expects the internal RAM data in the cycle after the request (see the bus and memory contract of the Core repository).

### 3.3. Initialization

The instance gets no initialization file (`init_file` at `UNUSED`) and the `.qip` lists none. The folder holds an `init.mif` of 4096 32-bit words whose declared content is zero at addresses `00A` to `FFF`, which the IP does not use. With `power_up_uninitialized` at `FALSE`, the RAM starts with zeros, and `instance_name` allows the content to be rewritten over JTAG after the FPGA is configured. The instance uses `word_count` for the physical depth and `size_bytes` for the address width.

### 3.4. IP files

| File | Content |
| :--- | :--- |
| `ram.vhd` | the entity and the `block_ram` instance |
| `ram.qip` | lists `block_ram.vhd` and `ram.vhd` for Quartus, with no family tag |
| `init.mif` | image of zeros, referenced neither by the `.qip` nor by the `.vhd` |

## 4. Integration

| Item | Description |
| :--- | :--- |
| Instantiated in | `src/simulation/internal-mem/quartus/core_fpga_test.vhd` of the Insper-RISC-V repository, instance `RAM`, on the `pll_clk_idexmem` clock |
| Address | the byte address of the core RAM minus the RAM base (`0x00008000`), in words, truncated to 16 bits |
| Depth | `size_bytes` preserves the 16-bit address and `word_count` receives the number of words in the RAM range defined by the platform map |
| Enables | `i_rden` and `i_wren` are those of the core RAM combined with the RAM enable and the negation of the UART selection, so a UART access does not reach the RAM |
| Data | `i_data` and `i_byteena` come from the RAM write signals of the core, and `o_q` returns to the core as read data |

The memory map, the internal RAM range (`0x00008000` to `0x3FFFFFFF` by default) and the ready contract of the bus are in the bus and memory contract of the Core repository. The `RAM` is the only memory of the internal memory design with the In-System Memory Content Editor, because the FLASH is rewritten by the loader, so its instance has index 0.

## 5. Verification

This IP has no cocotb test of its own and no entry in `tests/python/tests.json`, because the `altera_mf` library belongs to Quartus. The behavior of a single-port synchronous memory with byte mask is verified in the equivalent simulation model, described in [ram_simulation.md](ram_simulation.md). The paths of the `.qip` are registered in `paths.yaml`.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
