# flash1port

Single-port internal ROM IP that holds the test program (the internal FLASH) read by the instruction fetch stage.

## 1. Role of the component in the SoC

The internal FLASH starts right after the BOOT_ROM and runs to the start of the RAM (`0x00000800` to `0x00007FFF` in the default map, see [02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md)). This copy serves the instruction fetch (IF) stage. The fetch address indexes the IP directly, with no base subtraction, so the IP covers the whole range from zero to the start of the RAM and not only the logical FLASH span (32 KB of IP for 30 KB of FLASH). According to the VHDL header, each test image is left-padded with zeros up to the FLASH base before it becomes a `.mif`.

### 1.1. Difference between the three FLASH IPs

| IP | Role | Default size | Initialization file | Instance name |
| :--- | :--- | ---: | :--- | :--- |
| [flash1port](flash1port.md) | Copy read by the core IF stage | 32 KB | `./init.mif` | `FLASH` |
| [flash_mem1port](flash_mem1port.md) | Second physical copy, read by the MEM stage as data | 32 KB | `./init.mif` | `FLASH_MEM` |
| [flash_store1port](flash_store1port.md) | Storage behind the [flash_chip](flash_chip.md) chip | 256 KB | `./flash_init.mif` | `FLASH` |

All three use the same `altsyncram` recipe. The two internal copies must always hold the same content, and the distinct instance name is what makes the content editor treat each as a separate JTAG instance.

## 2. Interface

### 2.1. Generic

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `size_bytes` | `positive` | 32768 | Size in bytes, a power of two (32 KB by default); sets the width of `address` and the word count |

### 2.2. Ports

| Port | Direction | Width | Default | Meaning |
| :--- | :--- | ---: | :--- | :--- |
| `address` | input | $\log_2(\text{size\_bytes}) - 2$ (13 by default) | | Word index (byte address without the two low bits) |
| `clock` | input | 1 | `'1'` | Memory clock |
| `rden` | input | 1 | `'1'` | Read enable |
| `wren` | input | 1 | `'0'` | Write enable |
| `data` | input | 32 | zeros | Write data |
| `q` | output | 32 | | Word read |

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
| `lpm_hint` | `ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=FLASH` |
| `intended_device_family` | `Cyclone V` |

### 3.2. Read latency

The address is captured on the edge of `clock` and the output has no extra register, so the word of the address applied on an edge appears on `q` after it, with one cycle of synchronous latency. The `ENABLE_RUNTIME_MOD` hint keeps the memory visible to the Quartus In-System Memory Content Editor, and the instance shows up under the name `FLASH`, which lets the content be rewritten over JTAG without recompiling.

## 4. Integration

The file `src/rom/cyclone-v/flash1port.qip` registers the IP as "ROM: 1-PORT", version 20.1, family Cyclone V, and points to the VHDL.

| Top | Instance | Wiring |
| :--- | :--- | :--- |
| FPGA test top of the internal-memory platform (Insper-RISC-V) | `FLASH` | `address` on bits 14 to 2 of the fetch address, `clock` on the IF stage clock, `rden` on the fetch enable, `wren` at `'0'`, `q` on the FLASH instruction data |

The load tool rewrites this IP and [flash_mem1port](flash_mem1port.md) through the In-System Memory Content Editor on every test change, according to the VHDL header. In GHDL simulation the equivalent model is [rom_simulation](rom_simulation.md).

## 5. Verification

No `tests/python/tests.json` entry covers this IP, because it needs Intel's `altera_mf` library, absent from the continuous integration image (see the [README](../../../README.en.md)). What exercises it is the hardware top simulation in the Tests repository. `make paths` checks that the `.qip` exists.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
