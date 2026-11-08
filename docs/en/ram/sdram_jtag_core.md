# sdram_jtag_core

## 1. Role of the component in the SoC

The JTAG core of the SDRAM debug is the logic behind a Virtual JTAG instance. On the JTAG chain clock, it shifts in a 64-bit command from the host, returns the state of the previous command and hands the command to the debug master (`sdram_dbg_master`), which runs on the controller clock. The Virtual JTAG instance lives in the board wrapper `src/RAM/FPGA/Cyclone-V/sdram_jtag_shell.vhd`, and in simulation the testbench drives the ports of the core directly. The registers, the commands and the limits from the host point of view are in [sdram_debug.md](sdram_debug.md).

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
| `o_cmd_tog` | output | 1 | toggle that requests a command from the debug master |
| `o_op` | output | 4 | operation of the command |
| `o_be` | output | 4 | byte enables of the command |
| `o_addr` | output | 24 | word address of the command |
| `o_data` | output | 32 | data of the command (write or fill count) |
| `i_done_tog` | input | 1 | toggle that acknowledges the finished command |
| `i_rsp_addr` | input | 24 | last word accessed |
| `i_rsp_data` | input | 32 | data of the last read |
| `i_rsp_status` | input | 8 | status of the debug master |

All registers of the block run on `i_tck`, and the command outputs change only when a command is accepted.

## 3. Behavior

### 3.1. Registers

| Register | Width | Selected when | Role |
| :--- | ---: | :--- | :--- |
| instruction (`ir`) | 2 | loaded at every Update-IR | chooses the data register |
| DEBUG (`sr`) | 64 | instruction equal to 1 | receives the command and sends the state |
| bypass | 1 | any other instruction | repeats the input bit, sending nothing to the memory |

`o_tdo` is bit 0 of DEBUG when the instruction is 1 and the bypass otherwise.

### 3.2. Format of the DEBUG register

| Direction | Bits | Field | Meaning |
| :--- | :--- | :--- | :--- |
| in | 63 to 60 | op | command (those of `sdram_dbg_master`) |
| in | 59 to 56 | be | byte enables |
| in | 55 to 32 | addr | word address |
| in | 31 to 0 | data | write data or fill count |
| out | 63 to 56 | status | table below |
| out | 55 to 32 | word | last word accessed |
| out | 31 to 0 | data | data of the last read |

| Status bit | Source | Meaning |
| ---: | :--- | :--- |
| 0 | `busy` | the previous command has not finished, and `word` and `data` are not valid yet |
| 1 | bit 1 of `i_rsp_status` | the controller did not answer |
| 2 | bit 2 of `i_rsp_status` | the SDRAM is initialized |
| 3 | `overrun` | a command arrived with the master busy and was dropped |
| 4 to 7 | constant | zero |

### 3.3. Cycle of a shift

| Chain state | Effect with instruction 1 | Effect with another instruction |
| :--- | :--- | :--- |
| Capture-DR | loads DEBUG with the status, `i_rsp_addr` and `i_rsp_data` | none |
| Shift-DR | shifts DEBUG one bit to the right, with `i_tdi` entering at bit 63 | stores `i_tdi` in the bypass |
| Update-DR | accepts the command if `op` is different from 0 | none |
| Update-IR | loads `ir` with `i_ir_in` | loads `ir` with `i_ir_in` |

At Update-DR with `op` different from 0, the behavior depends on `busy`, which is 1 while `o_cmd_tog` differs from the synchronized `i_done_tog`.

| `busy` | Effect |
| :--- | :--- |
| 0 | clears `overrun`, registers `op`, `be`, `addr` and `data` on the outputs and flips `o_cmd_tog` |
| 1 | raises `overrun` and drops the command |

A shift with `op` equal to 0 only reads the status and sends nothing. Reading the status therefore creates no command by itself, which prevents every poll from creating a new command that never finishes (see [JTAG_STATUS_POLL.md](../bugs/JTAG_STATUS_POLL.md)).

### 3.4. Clock crossing and timing

`i_done_tog` enters `i_tck` through an instance `u_sync_done` of the two-stage `synchronizer`, internal to the block, and it only advances on edges of `i_tck`. The status is captured at the start of the shift, one or two edges of `i_tck` after the command was sent, so the first shift after a command may still show `busy` and the next one does not, because the 64 shifted bits give the synchronizer time. `o_cmd_tog`, `o_op`, `o_be`, `o_addr` and `o_data` stay stable until the next accepted command, and the debug master reads them after synchronizing `o_cmd_tog` to its clock. `i_rsp_addr`, `i_rsp_data` and `i_rsp_status` are captured directly at Capture-DR, with no synchronizer, and are valid only when `busy` is 0, because the debug master keeps them stable from before the flip of `i_done_tog`.

## 4. Integration

| Item | Description |
| :--- | :--- |
| Instantiated in | `src/RAM/FPGA/Cyclone-V/sdram_jtag_shell.vhd` (board, next to the `sld_virtual_jtag`) and `src/RAM/SoC/sim/sdram_system.vhd` (instance `u_jtag`, driven by the testbench) |
| Delivers commands to | `sdram_dbg_master`, through `o_cmd_tog`, `o_op`, `o_be`, `o_addr` and `o_data` |
| Receives from | `sdram_dbg_master`, through `i_done_tog`, `i_rsp_addr`, `i_rsp_data` and `i_rsp_status` |
| Host | the Virtual JTAG instance has a 2-bit instruction register, and instruction 1 selects the 64-bit DEBUG |

The JTAG port of the external bus UART is another Virtual JTAG instance, described in [jtag_uart.md](https://github.com/insper-riscv/Peripherals/blob/main/docs/en/UART/jtag_uart.md).

## 5. Verification

The tests of `tests/python/unittests/ram/sdram_debug_port.py` (entry `SdramDebugPort` of `tests/python/tests.json`) drive `i_tck`, `i_tdi` and the virtual chain states of `sdram_system`, so every command goes through the real JTAG core.

| Test | Checks in the JTAG core |
| :--- | :--- |
| `test_a_command_while_busy_is_dropped` | a command that arrives with `busy` at 1 raises `overrun` and does not run |
| `test_other_instructions_are_a_bypass` | with another instruction the register is 1 bit and nothing reaches the memory |
| `test_write_and_read_back` and the other read and write tests | the 64-bit format and the status read until `busy` returns to 0 |

There is no formal proof of this block.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
