# flash_mem

Single-port internal ROM IP that is the second physical copy of the internal FLASH, read as data by the MEM stage.

## 1. Role of the component in the SoC

The MEM stage must read the FLASH as data, for example to copy the `.data` section at startup (1-cycle FLASH data port, see [02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md), section 3.1). This copy serves that read, while [flash](flash.md) serves the instruction fetch. According to the VHDL header, a single two-port FLASH was not used because a `DUAL_PORT` `altsyncram` with `ENABLE_RUNTIME_MOD=YES` does not compile in this Quartus edition.

### 1.1. Difference between the three FLASH IPs

The comparison table is in [flash](flash.md). Relative to `flash`, this IP has the same recipe, the same size and the same initialization file, and differs only in the instance name (`FLASH_MEM`). The two copies must always hold the same content.

## 2. Interface

### 2.1. Generic

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `size_bytes` | `positive` | 32768 | Size in bytes, a power of two (32 KB by default); sets the width of `i_address` and the word count |

### 2.2. Ports

| Port | Direction | Width | Default | Meaning |
| :--- | :--- | ---: | :--- | :--- |
| `i_address` | input | $\log_2(\text{size\_bytes}) - 2$ (13 by default) | | Word index (byte address without the two low bits) |
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
| `numwords_a` | $\text{size\_bytes} / 4$ (8192 by default) |
| `widthad_a` | $\log_2(\text{size\_bytes}) - 2$ (13 by default) |
| `init_file` | `./init.mif` |
| `outdata_reg_a` | `UNREGISTERED` |
| `read_during_write_mode_port_a` | `NEW_DATA_NO_NBE_READ` |
| `lpm_hint` | `ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=FLASH_MEM` |
| `intended_device_family` | `Cyclone V` |

### 3.2. Read latency

The address is captured on the edge of `i_clk` and the output has no extra register, so the word of the address applied on an edge appears on `o_q` after it, with one cycle of synchronous latency. The `ENABLE_RUNTIME_MOD` hint keeps the memory visible to the Quartus In-System Memory Content Editor, and the instance shows up under the name `FLASH_MEM`, which lets the content be rewritten over JTAG without recompiling.

## 4. Integration

The file `src/ROM/Cyclone-V/flash_mem.qip` registers the IP as "ROM: 1-PORT", version 20.1, family Cyclone V, and points to the VHDL.

| Top | Instance | Wiring |
| :--- | :--- | :--- |
| FPGA test top of the internal-memory platform (Insper-RISC-V) | `FLASH_MEM` | `i_address` on bits 14 to 2 of the FLASH data read address, `i_clk` on the top `pll_clk_idexmem` clock, `i_rden` on the FLASH data read enable, `i_wren` at `'0'`, `o_q` on the FLASH read data |

The load tool rewrites both copies on every test change, according to the VHDL header. In GHDL simulation the second port of [rom_simulation](rom_simulation.md) plays the role of this copy.

## 5. Verification

No `tests/python/tests.json` entry covers this IP, because it needs Intel's `altera_mf` library, absent from the continuous integration image (see the [README](../../../README.en.md)). What exercises it is the hardware top simulation in the Tests repository. `make paths` checks that the `.qip` exists.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
