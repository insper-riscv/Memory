# ifetch_bridge

## 1. Role of the component in the SoC

The fetch bridge hands the core the instruction of the fetch address by reading it directly from the external memory, for the platform with an external ROM and no instruction cache. It takes the place of the [icache](icache.md) with the same contract on the core side and the same line contract on the memory side, so swapping one for the other does not change what wires them.

It is not a cache. There is no data RAM, no tag vector, no valid bit per line and no reuse by index. There is a single fetch register, which holds the requested word (or the line of four words that contains it, depending on the `fetch_line` generic) and the address it belongs to.

| Property | Value |
| :--- | :--- |
| Storage | One fetch register, of one word or of one line of four words |
| Serves | Only the current fetch address, held or walking inside the same line |
| Regions served | SDRAM and FLASH, the base of each added on the memory side |
| Clock | One, the core clock |
| Request to the memory | Word or line, with the line contract of the [icache](icache.md) |

The first address outside the register, the target of a branch included, starts a new request. The core stores are not observed, and only an invalidation (the `fence.i` of the program) makes written code visible to the fetch.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `fetch_line` | boolean | `true` | Asks for the line of four words that contains the address (`true`) or only its word (`false`) |
| `base_sdram` | 6-bit vector | `010000` | Bits 31 to 26 added to the SDRAM addresses on the memory side (0x40000000) |
| `base_flash` | 6-bit vector | `001000` | Bits 31 to 26 added to the FLASH addresses on the memory side (0x20000000) |
| `rom_base_kib` | natural | 524288 | Base of the ROM region in KiB; whatever falls in it is treated as FLASH |
| `rom_end_kib` | natural | 1048576 | Exclusive end of the ROM region in KiB |

### 2.2. Ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | Core clock; the one of the fetch register and of the state machine |
| `i_rst` | input | 1 | Reset, active at 1; discards the fetch register |
| `i_addr` | input | 32 | Fetch address (the PC) |
| `i_sel` | input | 1 | The fetch address belongs to the SDRAM or to the FLASH |
| `o_ready` | output | 1 | The instruction on `o_data` is the one of the current address |
| `o_data` | output | 32 | Fetched instruction |
| `i_invalidate` | input | 1 | Pulse that discards the fetch register (default 0) |
| `o_miss` | output | 1 | One-cycle pulse after the start of each request to the memory |
| `o_d_addr` | output | 32 | Request address, with the region base on bits 31 to 26 |
| `o_d_rden` | output | 1 | Read request |
| `o_d_line` | output | 1 | The request is for a line of four words |
| `o_d_advance` | output | 1 | Equal to `i_d_ready` |
| `i_d_ready` | input | 1 | Request completed |
| `i_d_rdata` | input | 32 | Word 0 of the data read |
| `i_d_rdata_x` | input | 96 | Words 1 to 3 of the line read (default zeros) |

## 3. Behavior

### 3.1. Core-side contract

The fetch stage of the core does not advance the PC until the bridge says that the instruction is the one of the current address. The bridge compares the fetch address with the one of the register, so `o_ready` obeys the equation below, with $L = 4$ for `fetch_line` true and $L = 2$ for false.

$$
\text{o\_ready} = \text{ok} \wedge \text{i\_sel} \wedge (\text{i\_addr}_{31:L} = \text{fetch\_addr}_{31:L})
$$

Because the comparison is combinational on `i_addr`, `o_ready` falls in the same cycle in which the PC leaves the line, and the core never receives the instruction of the previous address. With `fetch_line` true, `o_data` is the word of index `i_addr(3:2)` of the held line.

The icache reads its RAMs on the advanced clock of the instruction memories and therefore compares the address registered on that clock. The bridge keeps the register on the core clock, so the data is already stable when the core samples it and no advanced clock is needed.

### 3.2. State machine

The machine runs on `i_clk`.

| State | Function |
| :--- | :--- |
| `S_IDLE` | If `i_sel` is 1, the register does not contain the fetch address and `i_invalidate` is 0, it records the pending address, builds the request and goes to `S_WAIT` |
| `S_WAIT` | Holds the request until `i_d_ready`; then lowers `o_d_rden` and `o_d_line`, writes the fetch register and returns to `S_IDLE` |

The request address is the region base (`base_flash` when the address is in $[\texttt{rom\_base\_kib}, \texttt{rom\_end\_kib})$ KiB, `base_sdram` otherwise) followed by bits 25 to 0 of the address, with the bits below the alignment cleared (16 bytes with `fetch_line` true, 4 bytes with false). The request stays stable until `i_d_ready`, which the chip holds as a level until `o_d_advance`.

A request in progress cannot be aborted, because the chip finishes the wait and only then accepts another. A branch during the wait pays the rest of it, stores the word of the old address, which no longer matches the PC, and only then asks for the new address.

### 3.3. Latency

Let $F$ be the `first_latency` of the chip and $N$ the `next_latency`. The clocks per line of four instructions include the clock in which the core consumes each instruction.

| Case | Clocks until `o_ready` for the first instruction | Clocks per line of four instructions |
| :--- | ---: | ---: |
| Word (`fetch_line` false) | $F + 4$ | $4(F + 5)$ |
| Line (`fetch_line` true) | $F + 3N + 4$ | $F + 3N + 8$ |

With $F = 24$ and $N = 4$ (the default of the FLASH chip), the simulations of the full path measure the following for sequential code.

| `fetch_line` | Clocks per instruction | Clocks per line of four instructions |
| :--- | ---: | ---: |
| false | 29 | 116 |
| true | 11 | 44 |

The following instructions of the held line have `o_ready` at 1 without waiting. A branch to an address outside the register costs the whole latency of the request again.

### 3.4. Invalidation

A pulse on `i_invalidate` discards the register in the same cycle. If a request is in progress, it is completed and the word that arrives is discarded, so nothing held is older than the last invalidation. The discard mark is cleared when the machine returns to `S_IDLE`.

### 3.5. Reset

`i_rst` takes the machine to `S_IDLE` and discards the fetch register, the discard mark and the request signals.

## 4. Integration

| Instance | File | Connection |
| :--- | :--- | :--- |
| `BRIDGE` | `src/cache/SoC/sim/ifetch_path_system.vhd` | `i_clk` on the core clock; memory side wired to a [mem_region_router](mem_region_router.md), whose FLASH output goes to master A of the [flash_arbiter](flash_arbiter.md) |

The bridge request is a read, of a word or of a line. In the simulation system, the SDRAM output of the bridge router has no slave.

## 5. Verification

The tests are cocotb tests in `tests/python/unittests/cache`, registered in `tests/python/tests.json`. The bridge has no formal proofs, because the icache has none either.

| `tests.json` entry | Test module | What it covers |
| :--- | :--- | :--- |
| `IfetchBridge` | [ifetch_bridge.py](../../../tests/python/unittests/cache/ifetch_bridge.py) | A miss followed by words of the line without waiting, sequential code across lines, `o_ready` falls with the address, a held address makes no new request, branches, region base in the request, an unselected address, invalidation and invalidation during a request, a branch during a request, one miss pulse per request, reset |
| `IfetchBridgeWord` | [ifetch_bridge_word.py](../../../tests/python/unittests/cache/ifetch_bridge_word.py) | `fetch_line` false, one word request per instruction, a held word makes no new request |
| `IfetchPath` | [ifetch_path.py](../../../tests/python/unittests/cache/ifetch_path.py) | FLASH fetch end to end with the bridge, two routers, the arbiter and the 24-clock chip, clocks per instruction, branches, a wait with `o_ready` low, `fence.i` and `fence.i` during the wait, the data master sharing the chip, a SDRAM address kept off the chip |
| `IfetchPathWord` | [ifetch_path_word.py](../../../tests/python/unittests/cache/ifetch_path_word.py) | The same path with `fetch_line` false and the clocks per instruction |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
