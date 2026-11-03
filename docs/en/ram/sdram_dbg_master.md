# sdram_dbg_master

## 1. Role of the component in the SoC

The SDRAM debug master runs, on the controller clock, the read, write and fill commands that a host sends through the JTAG port. It is master B of the SDRAM arbiter, next to the data bridge and the instruction bridge of the core, and it accesses the same chip the core uses. The host can thus read and write any word while the core runs, is stopped or hangs. The host view (JTAG registers, commands and limits) is in [SDRAM_DEBUG.md](../../SDRAM_DEBUG.md), and this document describes the controller side.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `timeout_cycles` | natural | $2^{16}$ | cycles of waiting for the arbiter answer before the command is dropped |

### 2.2. Ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | module clock, the controller's |
| `i_rst` | input | 1 | synchronous reset, active at `'1'` |
| `i_cmd_tog` | input | 1 | command toggle from the host (any clock), each flip is a new command |
| `o_done_tog` | output | 1 | toggle that acknowledges the finished command |
| `i_op` | input | 4 | debug command code, 0 to 6 |
| `i_be` | input | 4 | byte enables of the writes |
| `i_addr` | input | 24 | word address of the command |
| `i_data` | input | 32 | write data or, in command 4, the number of words of the fill |
| `o_rsp_addr` | output | 24 | last word accessed |
| `o_rsp_data` | output | 32 | data returned by port B on the last access |
| `o_rsp_status` | output | 8 | bit 1 flags an error (controller did not answer), bit 2 flags SDRAM initialized, the others are 0 |
| `i_init_done` | input | 1 | the SDRAM initialization has finished, from any clock |
| `o_b_req_tog` | output | 1 | request toggle to the arbiter |
| `i_b_ack_tog` | input | 1 | acknowledge toggle, equal to `o_b_req_tog` when the request has been served |
| `o_b_we` | output | 1 | write (`'1'`) or read (`'0'`) |
| `o_b_addr` | output | 24 | word address |
| `o_b_wdata` | output | 32 | write data |
| `o_b_be` | output | 4 | byte enables of the write |
| `i_b_rdata` | input | 32 | read data |

## 3. Behavior

### 3.1. Command protocol

A command is a flip of `i_cmd_tog`, with `i_op`, `i_be`, `i_addr` and `i_data` stable from the flip until the answer, which is a flip of `o_done_tog`. `i_cmd_tog` and `i_init_done` cross a two-stage synchronizer to the module clock, and a command is pending while the synchronized `i_cmd_tog` differs from `o_done_tog`. When the command finishes, `o_done_tog` takes the value of the synchronized `i_cmd_tog`, which makes the two equal. The result (`o_rsp_*`) stays stable from before that flip until the next command is accepted.

### 3.2. Commands

| `i_op` | Effect |
| ---: | :--- |
| 0 | nothing, answers without accessing the memory |
| 1 | reads the word at `i_addr` |
| 2 | writes `i_data` to the word at `i_addr`, bytes by `i_be` |
| 3 | writes `i_data` (all bytes) to `count` consecutive words from `i_addr`; with `count` equal to 0, answers without writing |
| 4 | sets `count` to the low 25 bits of `i_data`, up to $2^{24}$ words, the whole SDRAM |
| 5 | reads the word after the one accessed last |
| 6 | writes `i_data` to the word after the one accessed last, bytes by `i_be` |
| 7 to 15 | treated as command 0 |

The value of `count` is 1 after reset and is kept between commands. The register has 25 bits because a fill of the whole SDRAM is $2^{24}$, which does not fit in 24 bits (see [FILL_COUNT_24_BITS.md](../../bugs/FILL_COUNT_24_BITS.md)).

### 3.3. State machine

| State | Action | Next state |
| :--- | :--- | :--- |
| `ST_IDLE` | with a pending command, latches `i_op`, `i_be` and `i_data`, clears the error and runs the command; reads and writes issue a request to the arbiter (address, `o_b_we`, data and mask, flip of `o_b_req_tog`, clear of the wait counter), commands 0 and 4 and command 3 with a zero `count` answer at once | `ST_WAIT`, or stays |
| `ST_WAIT` | waits for `i_b_ack_tog` to equal `o_b_req_tog`; on receiving it, stores the accessed word in `o_rsp_addr` and `i_b_rdata` in `o_rsp_data` | `ST_NEXT` |
| `ST_NEXT` | in command 3 with words remaining, issues the write of the next word; otherwise answers | `ST_WAIT` or `ST_IDLE` |

The fill writes $\text{count}$ words, with $\text{count} - 1$ of them remaining after the first, and `o_rsp_addr` ends at the last word written. The data in `o_rsp_data` is copied from `i_b_rdata` at the end of every access, writes included, so it only has meaning after a read.

If `i_b_ack_tog` does not reach `o_b_req_tog` within $\text{timeout\_cycles} + 1$ cycles of `ST_WAIT`, the error bit of `o_rsp_status` rises, the command is dropped (a fill in progress ends there) and `o_done_tog` answers. The request is not cancelled, and the request toggle returns to its initial value only on reset.

### 3.4. Latency

The command is seen 2 edges of `i_clk` after the flip of `i_cmd_tog` is sampled, through the two-stage synchronizer, and execution starts on the next edge. Each access costs 1 cycle to issue the request, the arbiter and controller time until the acknowledge, and 1 cycle in `ST_NEXT`. The rate of a fill is that of the arbiter with the controller, around 15 cycles per word according to [SDRAM_DEBUG.md](../../SDRAM_DEBUG.md).

## 4. Integration

| Item | Description |
| :--- | :--- |
| Instantiated in | `src/cyclone-v/de0-cv/de0-cv_top.vhd` of the Insper-RISC-V repository (instance `SDRAM_DEBUG`, on the controller clock) and `src/ram/soc/sim/sdram_system.vhd` (instance `u_dbg`) |
| Receives commands from | `sdram_jtag_core`, directly in simulation and through the wrapper `src/ram/cyclone-v/sdram_jtag_shell.vhd` (which holds the Virtual JTAG) on the board |
| Delivers requests to | the master B port of `sdram_arbiter`, which carries them to the controller |
| Uses | the `synchronizer` of the Common-Components library, two instances, one for `i_cmd_tog` and one for `i_init_done` |

The core memory map sees the SDRAM from `0x40000000`, and a word address $a$ of the command corresponds to the byte address $0\text{x}40000000 + 4a$ seen by the core. The arbiter alternates between the masters when more than one waits, and its behavior is in [SDRAM_DEBUG.md](../../SDRAM_DEBUG.md) and in the proof of [FORMAL.md](../../FORMAL.md).

## 5. Verification

The cocotb tests of `tests/python/unittests/ram/sdram_debug_port.py` run the complete system (controller, arbiter, debug master, JTAG core and chip model), declared as `SdramDebugPort` in `tests/python/tests.json`. The `SdramSystem` entry builds the same sources, but its tests exercise the core path and not the debug commands.

| Test | Checks |
| :--- | :--- |
| `test_write_and_read_back` | a write reads back and reaches the chip, including the highest word address and the byte masks |
| `test_the_core_and_the_host_see_the_same_memory` | what the core writes the host reads, and the reverse |
| `test_fill` | the fill writes exactly `count` words from the address and does not change the neighbors |
| `test_the_fill_count_reaches_the_whole_sdram` | the `count` register holds $2^{24}$ and $2^{24} - 1$ |
| `test_next_word_commands` | commands 5 and 6 follow the last word accessed |
| `test_traffic_from_the_core_and_the_host_together` | simultaneous accesses from the core and the host do not corrupt each other |
| `test_a_command_while_busy_is_dropped` | the command that arrives with the master busy is dropped and flagged |
| `test_other_instructions_are_a_bypass` | another JTAG instruction sends nothing to the memory |
| `test_the_core_is_not_starved_by_a_long_fill` | a long fill does not delay the core beyond the arbiter bound |

There is no formal proof of this block. The proof in [FORMAL.md](../../FORMAL.md) covers the arbiter, with master B modeled by the assumptions about the environment.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
