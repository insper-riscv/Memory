# block_ram

🌐 [Português](../../pt-br/block_ram/block_ram.md) · [English](../../en/block_ram/block_ram.md)

FPGA block memory, with one or two ports, that wraps Intel's `altsyncram` megafunction and is the only instance of it in the repository.

## 1. Role of the component

`boot_memory`, `flash`, `flash_store` and `ram` are instances of this entity and differ only in the generics they pass. The `altsyncram` generic map exists in a single entity, in `src/block_ram/altera/` (a vendor folder), and the four memories do not repeat the parameters they share.

The entity needs Quartus' `altera_mf` library, which the tools image does not carry, so `make check` does not analyze it. The hardware-top simulation in Insper-RISC-V elaborates it with Intel's `altera_mf` models.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `operation_mode` | `string` | `"SINGLE_PORT"` | `"SINGLE_PORT"` (port A only) or `"BIDIR_DUAL_PORT"` (ports A and B read and write) |
| `word_count` | `positive` | 1024 | Number of words |
| `address_width` | `positive` | 10 | Word address width |
| `data_width` | `positive` | 32 | Word width, a multiple of `byte_lanes` |
| `byte_lanes` | `positive` | 1 | Byte-enabled lanes per word on the port A write (1 writes the whole word; more than 1 only in single-port mode) |
| `init_file` | `string` | `"UNUSED"` | Initialization `.mif` file |
| `instance_name` | `string` | `""` | Instance name for Quartus' In-System Memory Content Editor; empty does not expose the memory over JTAG |
| `block_depth` | `natural` | 0 | Words per block (`maximum_depth`); 0 lets Quartus choose |
| `device_family` | `string` | `"Cyclone V"` | Device family for Quartus |

### 2.2. Ports

| Port | Direction | Width | Default | Meaning |
| :--- | :--- | ---: | :--- | :--- |
| `i_clk_a` | in | 1 | `'1'` | Port A clock |
| `i_address_a` | in | `address_width` | | Word index of port A |
| `i_byteena_a` | in | `byte_lanes` | all `'1'` | Write byte enables of port A |
| `i_data_a` | in | `data_width` | zeros | Write data of port A |
| `i_rden_a` | in | 1 | `'1'` | Port A read enable |
| `i_wren_a` | in | 1 | `'0'` | Port A write enable |
| `o_q_a` | out | `data_width` | | Word read by port A |
| `i_clk_b` | in | 1 | `'1'` | Port B clock |
| `i_address_b` | in | `address_width` | zeros | Word index of port B |
| `i_data_b` | in | `data_width` | zeros | Write data of port B |
| `i_rden_b` | in | 1 | `'1'` | Port B read enable |
| `i_wren_b` | in | 1 | `'0'` | Port B write enable |
| `o_q_b` | out | `data_width` | | Word read by port B, zero in single-port mode |

The B ports are ignored in single-port mode.

## 3. Behavior

The read is synchronous and the output has no register: the address is captured on the rising edge of the port clock and the word appears on the output right after it, with one cycle of latency. On a read and write at the same address of the same port, the read returns the new data (`NEW_DATA_NO_NBE_READ`).

The `altsyncram` parameters that do not depend on the generics are fixed: `clock_enable_*` at `BYPASS`, `outdata_reg_*` at `UNREGISTERED`, `outdata_aclr_*` at `NONE` and `power_up_uninitialized` at `FALSE`. Quartus rejects parameters and ports that the mode does not use (`clock1`, `byteena_a` and `byte_size` with a single byte, and the port B parameters in single-port mode). The architecture therefore has three generate branches (single port with the whole word, single port with byte write, and two ports), and each branch cites only what its mode uses. The synthesis of each instance is that of a hand-written `altsyncram`: the DE0-CV keeps the same registers and block memory bits. Byte write (`byte_lanes` above 1) exists only in single-port mode.

With a non-empty `instance_name`, `lpm_hint` becomes `ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=<name>`. Quartus Lite does not accept this option in two-port mode.

## 4. Where it is used

| Instance | Mode | `byte_lanes` | `init_file` | `instance_name` |
| :--- | :--- | ---: | :--- | :--- |
| [boot_memory](../rom/boot_memory.md) | single port | 1 | `./boot_memory_init.mif` | |
| [flash](../rom/flash.md) | dual port | 1 | `./init.mif` | |
| [flash_store](../rom/flash_store.md) | single port | 1 | `./flash_init.mif` | `FLASH` |
| [ram](../ram/ram.md) | single port | 4 | | `RAM` |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
