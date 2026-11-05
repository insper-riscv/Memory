# flash_jtag_core

Logic behind the Virtual JTAG instance of the FLASH loader, on the JTAG chain clock.

## 1. Role of the component in the SoC

On the JTAG chain clock, the block shifts in the 64-bit command or the STREAM words coming from the host, returns the state of the previous command and hands the command to the [flash_loader](flash_loader.md), which runs on the clock of the FLASH port B. The Virtual JTAG instance lives in `src/ROM/Cyclone-V/flash_jtag_shell.vhd`, and in simulation the testbench drives the ports of the block directly. The registers, the commands and the limits from the host point of view are in [flash_loader](flash_loader.md).

## 2. Interface

The component has no generics.

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_tck` | input | 1 | JTAG chain clock |
| `i_tdi` | input | 1 | serial data from the host |
| `o_tdo` | output | 1 | serial data to the host |
| `i_ir_in` | input | 2 | value of the Virtual JTAG instruction register |
| `i_state_cdr` | input | 1 | Capture-DR state of the virtual chain |
| `i_state_sdr` | input | 1 | Shift-DR state of the virtual chain |
| `i_state_udr` | input | 1 | Update-DR state of the virtual chain |
| `i_state_uir` | input | 1 | Update-IR state of the virtual chain |
| `o_cmd_tog` | output | 1 | toggle that requests a command from the loader |
| `o_op` | output | 4 | operation of the command |
| `o_addr` | output | 24 | word index of the command |
| `o_data` | output | 32 | data of the command |
| `i_done_tog` | input | 1 | toggle that confirms the finished command |
| `i_rsp_addr` | input | 24 | address of the response |
| `i_rsp_data` | input | 32 | data of the response |
| `i_rsp_status` | input | 8 | loader status |

Every register of the block runs on `i_tck`, and the command outputs change only when a command is accepted.

## 3. Behavior

### 3.1. Registers

| Register | Width | Selected when | Role |
| :--- | ---: | :--- | :--- |
| instruction | 2 | loaded on every Update-IR | picks the data register |
| CMD and STREAM | 64 | instruction equal to 1 or 2 | receives the command or the words and sends the state |
| bypass | 1 | any other instruction | repeats the input bit |
| cursor | 24 | always | index of the next STREAM word |
| bit counter | 5 | instruction equal to 2 | marks the complete 32-bit word |
| started | 1 | instruction equal to 2 | tells that the start bit has passed |

### 3.2. Accepting a command

1. On the Update-DR of the CMD, an operation other than 0 and 6 is accepted if the loader is not busy, and in that case it toggles `o_cmd_tog`.
2. If the loader is busy, the command is dropped and the overrun bit rises, until the next command is accepted.
3. Operation 6 only updates the cursor, without going through the loader, and operation 0 only reads the status.
4. Operations 3 and 4 leave the cursor at `addr + 1`.

### 3.3. Accepting a STREAM word

On Shift-DR with instruction 2, the block waits for the first bit with value 1, the start bit. After it, the bit counter counts from 0 to 31, and on the thirty-second bit the complete word is handed to the loader as a write at the cursor, which advances. The block waits for a new start bit on every Capture-DR.

## 4. Verification

The `FlashLoader` test drives this block through the `i_jtag_*` ports of the `flash_system` top, the way the Virtual JTAG would (see [flash_loader](flash_loader.md)).

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
