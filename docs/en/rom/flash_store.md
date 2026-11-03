# flash_store

Single-port internal ROM IP that serves as the storage of the external FLASH chip.

## 1. Role of the component in the SoC

This IP is the FPGA block memory that [flash_chip](flash_chip.md) drives. The chip hands over the registered address and receives the word one edge later, and the content is rewritten by the host over JTAG. Changing the content does not change the chip. The address map of the external FLASH (`0x20000000`) is in [02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md).

### 1.1. Difference between the three FLASH IPs

The comparison table is in [flash](flash.md). Relative to the other two, this IP is 256 KB by default (against 32 KB), has another initialization file (`./flash_init.mif`) and serves the chip, not the core. There is no second copy, because the chip is the only reader and both core reads (instruction and data) go through the chip.

## 2. Interface

### 2.1. Generic

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `size_bytes` | `positive` | 262144 | Size in bytes, a power of two (256 KB by default); sets the width of `i_address` and the word count |

### 2.2. Ports

| Port | Direction | Width | Default | Meaning |
| :--- | :--- | ---: | :--- | :--- |
| `i_address` | input | $\log_2(\text{size\_bytes}) - 2$ (16 by default) | | Word index (byte address without the two low bits) |
| `i_clk` | input | 1 | `'1'` | Memory clock |
| `i_rden` | input | 1 | `'1'` | Read enable |
| `i_wren` | input | 1 | `'0'` | Write enable |
| `i_data` | input | 32 | zeros | Write data |
| `o_q` | output | 32 | | Word read |

## 3. Behavior

### 3.1. Library configuration

The read is done by the `altsyncram` instance of the `altera_mf` library, which belongs to Quartus and is not part of this repository. The parameters fixed in the VHDL are:

| Parameter | Value |
| :--- | :--- |
| `operation_mode` | `SINGLE_PORT` |
| `width_a` | 32 |
| `numwords_a` | $\text{size\_bytes} / 4$ (65536 by default) |
| `widthad_a` | $\log_2(\text{size\_bytes}) - 2$ (16 by default) |
| `init_file` | `./flash_init.mif` |
| `outdata_reg_a` | `UNREGISTERED` |
| `read_during_write_mode_port_a` | `NEW_DATA_NO_NBE_READ` |
| `lpm_hint` | `ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=FLASH` |
| `intended_device_family` | `Cyclone V` |

### 3.2. Read latency

The address is captured on the edge of `i_clk` and the output has no extra register, so the word of the address applied on an edge appears on `o_q` after it, with one cycle of synchronous latency. The `ENABLE_RUNTIME_MOD` hint keeps the memory visible to the Quartus In-System Memory Content Editor, and the instance shows up under the name `FLASH`, which lets the content be rewritten over JTAG without recompiling.

## 4. Integration

The file `src/ROM/Cyclone-V/flash_store.qip` registers the IP as "ROM: 1-PORT", version 20.1, family Cyclone V, and points to the VHDL.

| Top | Instance | Wiring |
| :--- | :--- | :--- |
| DE0-CV board top (Insper-RISC-V) | `FLASH_STORE` | `i_address` on bits 17 to 2 of the chip `o_mem_addr`, `i_clk` on the same clock as the chip, `i_rden` at `'1'`, `i_wren` at `'0'`, `o_q` on the chip `i_mem_data` |

In the same top the chip is instantiated with a `size_bytes` of 262144, equal to the default size of this IP. In the modular simulation the chip storage is the [rom_simulation](rom_simulation.md) model.

## 5. Verification

No `tests/python/tests.json` entry covers this IP, because it needs Intel's `altera_mf` library, absent from the continuous integration image (see the [README](../../../README.en.md)). What exercises it is the hardware top simulation in the Tests repository. `make paths` does not check the `.qip` of this IP, because it is not in the Quartus file list of `paths.yaml`.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
