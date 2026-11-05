# flash_simulation

Simulation model of the internal true dual-port FLASH, equivalent to the [flash](flash.md) IP, initialized from a text file.

## 1. Role of the component in the SoC

In GHDL simulations the model replaces the [flash](flash.md) IP, which depends on the Quartus `altera_mf` library. It has the same ports and the same one-cycle latency on both reads, and the word vector is written in plain VHDL so that cocotb can read it. The write exists only on port B. The `flash_system` top wires the model to the [flash_loader](flash_loader.md) like the FPGA top.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `size_bytes` | `positive` | 32768 | Size in bytes, a power of two |
| `rom_file` | `string` | empty | File with the initial content, one 32-bit word per line in hexadecimal; empty leaves the memory zeroed |

### 2.2. Ports

The ports are those of the [flash](flash.md) IP (`i_clk_a`, `i_address_a`, `i_rden_a`, `o_q_a`, `i_clk_b`, `i_address_b`, `i_rden_b`, `i_wren_b`, `i_data_b`, `o_q_b`).

## 3. Behavior

Each port has its own process, on the rising edge of its clock. Port A captures the word of the address when `i_rden_a` is `'1'`. Port B stores `i_data_b` when `i_wren_b` is `'1'` and returns the new data on the same edge, and reads the address when only `i_rden_b` is `'1'`. The words the file does not cover stay zeroed.

## 4. Verification

The `FlashLoader` test uses this model inside the `flash_system` top (see [flash_loader](flash_loader.md)).

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
