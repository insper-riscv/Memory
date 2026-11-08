# flash

True dual-port memory IP that holds the test program (the internal FLASH) in a single copy, read by the instruction fetch stage and by the MEM stage and written by the loader.

## 1. Role of the component in the SoC

The internal FLASH starts right after the BOOT_MEMORY and runs to the start of the RAM (`0x00001000` to `0x00007FFF` in the default map, see [02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md)). Port A serves the instruction fetch (IF) stage. Port B serves the MEM stage, which reads the FLASH as data (for example to copy the `.data` section at startup), and the [flash_loader](flash_loader.md) loader, which writes it. The core only reads, because the write exists only on port B and the loader enables it only while the core is halted.

The fetch address indexes the IP directly, with no base subtraction, so the IP covers the whole range from zero to the start of the RAM and not only the logical FLASH span (32 KB of IP for 28 KB of FLASH). Each test image is left-padded with zeros up to the FLASH base before it becomes a `.mif`.

### 1.1. Difference between the FLASH IPs

| IP | Role | Default size | Initialization file | Rewriting |
| :--- | :--- | ---: | :--- | :--- |
| [flash](flash.md) | Single copy of the internal FLASH, two ports | 32 KB | `./init.mif` | JTAG loader ([flash_loader](flash_loader.md)) |
| [flash_store](flash_store.md) | Storage behind the [flash_chip](flash_chip.md) chip | 256 KB | `./flash_init.mif` | In-System Memory Content Editor, instance `FLASH` |

## 2. Interface

### 2.1. Generic

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `size_bytes` | `positive` | 32768 | Size in bytes, a power of two (32 KB by default); sets the width of the addresses and the word count |

### 2.2. Ports

| Port | Direction | Width | Default | Meaning |
| :--- | :--- | ---: | :--- | :--- |
| `i_clk_a` | input | 1 | `'1'` | Port A clock |
| `i_address_a` | input | $\log_2(\text{size\_bytes}) - 2$ (13 by default) | | Index of the word read by port A (byte address without the two low bits) |
| `i_rden_a` | input | 1 | `'1'` | Port A read enable |
| `o_q_a` | output | 32 | | Word read by port A |
| `i_clk_b` | input | 1 | `'1'` | Port B clock |
| `i_address_b` | input | $\log_2(\text{size\_bytes}) - 2$ | | Index of the word accessed by port B |
| `i_rden_b` | input | 1 | `'1'` | Port B read enable |
| `i_wren_b` | input | 1 | `'0'` | Port B write enable |
| `i_data_b` | input | 32 | zeros | Port B write data |
| `o_q_b` | output | 32 | | Word read by port B |

## 3. Behavior

### 3.1. Block memory instance

The memory is built by an instance of [block_ram](../block_ram/block_ram.md), which wraps the `altsyncram` of Quartus' `altera_mf` library, and the other megafunction parameters are fixed there. The generics passed to the instance are:

| Generic | Value |
| :--- | :--- |
| `operation_mode` | `BIDIR_DUAL_PORT` |
| `word_count` | $\text{size\_bytes} / 4$ (8192 by default) |
| `address_width` | $\log_2(\text{size\_bytes}) - 2$ (13 by default) |
| `block_depth` | 2048 (`maximum_depth` of the megafunction) |
| `init_file` | `./init.mif` |

The instance gets no `instance_name`, so it has no `ENABLE_RUNTIME_MOD` hint, because Quartus Lite does not accept it in two-port mode, so the In-System Memory Content Editor does not see this memory. Rewriting goes through the loader.

### 3.2. Read latency

The address is captured on the edge of the port clock and the output has no extra register, so the word of the address applied on an edge appears on the output after it, with one cycle of synchronous latency, on both ports.

### 3.3. Block usage

The `maximum_depth` parameter limits each block to 2048 words, and Quartus switches to the 2048x5 mode of the M10K, the densest true dual-port mode for a 32-bit word. Without it Quartus picks the 8192x1 mode, which wastes bits.

The values below come from the Fitter report for the Cyclone V 5CEBA4F23C7.

| Size | Words | M10K blocks with `maximum_depth` 2048 | M10K blocks without the parameter |
| ---: | ---: | ---: | ---: |
| 32 KB | 8192 | 28 | 32 |
| 252 KB | 64512 | 221 | 256 |

## 4. Integration

The file `src/ROM/Cyclone-V/flash.qip` lists `block_ram.vhd` and the IP's VHDL, with no family tag.

| Top | Instance | Wiring |
| :--- | :--- | :--- |
| FPGA test top of the internal-memory platform (Insper-RISC-V) | `FLASH` | Port A on the fetch address (bits 14 to 2) and the IF stage clock; port B on the outputs of the [flash_loader](flash_loader.md) loader, which passes the MEM stage address through while the core runs |

In GHDL simulation the equivalent model is [flash_simulation](flash_simulation.md).

## 5. Verification

No entry of `tests/python/tests.json` covers this IP, because it needs Intel's `altera_mf` library, absent from the continuous integration image (see the [README](../../../README.en.md)). The equivalent model is covered by the `FlashLoader` test, and the hardware top simulation in the Tests repository exercises the IP. `make paths` checks that the `.qip` exists.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
