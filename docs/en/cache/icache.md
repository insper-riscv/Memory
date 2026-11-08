# icache

## 1. Role of the component in the SoC

The icache is the core's read-only instruction cache. It sits on the fetch path of the SDRAM and FLASH addresses. The boot memory does not go through it. When the instruction at the fetch address is not stored, the cache holds the core waiting (no `o_ready`) and brings the four-word line from memory.

| Property | Value |
| :--- | :--- |
| Organization | Direct-mapped, 16-byte lines (four words), read-only |
| Size | Generic `size_bits` (4 KB and 256 lines by default) |
| Regions served | SDRAM and FLASH, told apart by one tag bit |
| Clocks | Two, the instruction-memory clock (`i_clk`) and the core clock (`i_clk_cpu`) |
| RAM read | Registered, as in FPGA block RAMs |

On the platform without an instruction cache, the [ifetch_bridge](ifetch_bridge.md) takes its place with the same contract.

The core's stores are not observed by the cache. Only an invalidation (the program's `fence.i`) makes written code visible to the fetch. The SDRAM debug port writes with the core stopped and the cache invalidated, as after reset.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `size_bits` | positive | 32768 | Cache size in bits, a power of two of at least 256 (two lines). 32768 is 4 KB and 4096 is 4 kbit |
| `window_bits` | natural from 26 to 29 | 26 | Width of the address window of the cache: $2^{\texttt{window\_bits}}$ bytes (26 is 64 MiB, 27 is 128 MiB). The tag stores the bits below it |
| `base_sdram` | 6-bit vector | `010000` | Bits 31 to 26 of the SDRAM addresses on the memory side (0x40000000); only bits 31 down to `window_bits` are used |
| `base_flash` | 6-bit vector | `001000` | Bits 31 to 26 of the FLASH addresses on the memory side (0x20000000); only bits 31 down to `window_bits` are used |
| `rom_base_kib` | natural | 524288 | Base of the ROM region in KiB; whatever falls in it is treated as FLASH (0x20000000) |
| `rom_end_kib` | natural | 1048576 | Exclusive end of the ROM region in KiB (0x40000000) |
| `sel_from_kib` | integer | -1 | With a non-negative value, the select comes from the registered address (selected from this address, in KiB) and `i_sel` is ignored |
| `check_addr` | boolean | true | Checks on each lookup that the registered address is that of `i_addr`; with skewed clocks (the `i_clk` edge always before the core one) it can be turned off |

### 2.2. Ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | Instruction-memory clock; reads the RAMs and registers the fetch address |
| `i_clk_cpu` | input | 1 | Clock of the state machine, the valid sweep and the reset (the core clock) |
| `i_rst` | input | 1 | Reset, active at 1; sweeps and invalidates every line |
| `i_addr` | input | 32 | Fetch address (the PC) |
| `i_sel` | input | 1 | The fetch address belongs to the SDRAM or the FLASH |
| `o_ready` | output | 1 | The instruction on `o_data` is the one for the current address |
| `o_data` | output | 32 | Fetched instruction |
| `i_invalidate` | input | 1 | Pulse that asks for the sweep of every line (default 0) |
| `o_miss` | output | 1 | One-cycle pulse at the start of each line fill |
| `i_inval_region` | input | 1 | Pulse that drops the lines of the region from `i_inval_first` to `i_inval_last` (default 0) |
| `i_inval_first` | input | 32 | First byte address of the region to drop (default 0) |
| `i_inval_last` | input | 32 | Last byte address of the region to drop, included (default 0) |
| `o_d_addr` | output | 32 | Line request address, with the region base in bits 31 down to `window_bits` |
| `o_d_rden` | output | 1 | Read request |
| `o_d_line` | output | 1 | The request is for a line of four words |
| `o_d_advance` | output | 1 | Equal to `i_d_ready` |
| `i_d_ready` | input | 1 | Request completed |
| `i_d_rdata` | input | 32 | Word 0 of the line read |
| `i_d_rdata_x` | input | 96 | Words 1 to 3 of the line read (default zeros) |

## 3. Behavior

### 3.1. Address split

With $I = \log_2(\texttt{size\_bits}) - 7$ index bits, the cache has $2^I$ lines.

| Field | Address bits | Width |
| :--- | :--- | ---: |
| Word in line | 3 to 2 | 2 |
| Index | $I+3$ to 4 | $I$ |
| Tag | `window_bits`$-1$ to $I+4$ | $W-4-I$ |
| Region | Computed from `rom_base_kib` and `rom_end_kib`; becomes the most significant tag bit | 1 |

$$
\text{TAG\_BITS} = W - 3 - I
$$

Here $W$ is `window_bits`. The region bit in the tag keeps a FLASH line and an SDRAM line with the same bits $W-1$ to $I+4$ from being confused. Bits 31 to $W$ are not stored, and the memory-side request rebuilds them with bits 5 down to $W-26$ of `base_flash` or `base_sdram`, according to the region bit of the line being filled. With `window_bits` equal to 26 (the default) these are the six bits of the base; with 27 the window covers the 128 MiB of the DE2-115 SDRAM and the base loses bit 26, which becomes the top bit of the address tag. The width is fixed at generation by the memory map of the platform (`CACHE_WINDOW_BITS`), so the default leaves the generated hardware unchanged.

### 3.2. Lookup and core-side contract

The data, tag and valid RAMs are read on `i_clk` with the address of `i_addr`, and the address and `i_sel` are registered on the same edge. After that edge, the instruction of the registered address is on `o_data`, and `o_ready` says it is the right one.

$$
\text{o\_ready} = \text{sel\_q} \wedge \neg\text{blocked} \wedge \text{valid\_rd} \wedge (\text{tag\_rd} = \text{tag}(\text{addr\_q})) \wedge (\text{addr\_q} = \text{i\_addr})
$$

The last term drops `o_ready` if `i_addr` changed since the edge. The core samples `o_ready` and `o_data` on its own edge, a fraction of a clock after `i_clk`, and while `o_ready` is at 0 it keeps the address stable. A hit therefore has `o_ready` at 1 in the cycle after the edge that registered the address.

### 3.3. State machine

The machine runs on `i_clk_cpu`.

| State | Function | Output |
| :--- | :--- | :--- |
| `S_IDLE` | Waits for a miss. With `blocked` at 1 and a sweep pending, it starts `S_SWEEP`. Otherwise, if the miss registered in the previous cycle (`miss_q`, which is 1 when `S_IDLE` saw the registered `i_sel` at 1, no hit, the registered address equal to `i_addr` and `i_invalidate` at 0) still holds with `i_invalidate` at 0, it computes the tag and the index of the line from the address of the miss (`miss_a`, registered) and moves to `S_FILL_REQ`. Registering the decision takes the read of the tag out of the path to the state machine | |
| `S_FILL_REQ` | Builds the line request with the address $\text{base} \,\Vert\, \text{tag} \,\Vert\, \text{index} \,\Vert\, 0000_2$ and raises `o_d_rden` and `o_d_line` | `o_miss` at 1 |
| `S_FILL_WAIT` | Waits for `i_d_ready`, then lowers the request | |
| `S_FILL_GET` | Stores one word per cycle in the data RAM (words 0 to 3); on word 3 it stores the tag and the valid bit | |
| `S_SETTLE2`, `S_SETTLE` | Two cycles: the RAM writes come from registers and happen one cycle after the state that asks for them, and the registered read has to see the new tag and valid bit | |
| `S_SWEEP`, `S_RELEASE`, `S_RELEASE2` | Invalidation sweep (section 3.5) | |

During the fill, `i_addr` may change (a branch moved the PC). The line keeps being brought into the index recorded at the start.

### 3.4. Latency

Let $k$ be the number of `S_FILL_WAIT` cycles ($k \ge 1$) and assume `i_clk` equal to `i_clk_cpu`. A miss is detected in `S_IDLE`, in the cycle after the edge that registered the address, and spends $1 + 1 + k + 4 + 2$ cycles from the second cycle of `S_IDLE` (the one that reads `miss_q`) to `S_SETTLE`. Counting the detection cycle, the miss costs $9 + k$ cycles more than a hit, and the next lookup hits.

| Case | Cycles beyond a hit |
| :--- | ---: |
| Hit | 0 |
| Miss | $9 + k$ |

### 3.5. Invalidation

The valid bit of each line lives in a RAM read with the same address as the data and tag RAMs, which takes the one-input-per-line multiplexer out of the path between the PC and the cache. The RAM cannot be cleared at once, so an invalidation is a sweep that clears one line per `i_clk_cpu` cycle.

A pulse on `i_invalidate` asks for the sweep of every line. A pulse on `i_inval_region` asks for the lines of the region (section 3.6). Any request raises `blocked`, and while `blocked` is 1 no lookup hits and no fill starts. A request that arrives while the machine is not in `S_IDLE` stays pending and is served when the machine returns to `S_IDLE`; a second request that finds another pending becomes the request for every line. Thus no stored line is older than the last invalidation: a fill in progress finishes, and the sweep that follows clears its line if it falls in the request.

| State | Function |
| :--- | :--- |
| `S_SWEEP` | Clears line `sw_idx` and moves to the next, from `pend_first` to `pend_first + pend_off` (modulo the number of lines) |
| `S_RELEASE`, `S_RELEASE2` | Two cycles for the registered write and the registered read to see the last clear; if another request arrived, it returns to `S_IDLE` and sweeps again, otherwise it lowers `blocked` |

A sweep of every line costs $L$ cycles, where $L$ is the number of lines (256 at 4 KB), plus four of waiting.

### 3.6. Region invalidation

A pulse on `i_inval_region` drops the lines of the addresses from `i_inval_first` to `i_inval_last`, which is what the FLASH controller asks for at the end of an erase or a program. The cache stores the tag, not the full address, so it drops by index: every line whose index contains some address of the region, including the one of another region with the same index. With $N$ lines in the region and $L$ lines in the cache, the sweep clears the lines of index $i$ such that

$$
(i - i_{first}) \bmod L < N \qquad \text{or} \qquad N \ge L
$$

where $i_{first}$ is the index of the address `i_inval_first`. A region with `i_inval_last` below `i_inval_first` has no effect. The request is registered and applied in the next cycle; the lines outside the region keep their data but do not hit while the sweep runs.

### 3.7. Reset

`i_rst` takes the machine to `S_IDLE` with `blocked` at 1 and a sweep of every line pending, and clears the request signals and the word counter. The cache is ready $L + 4$ cycles after the reset.

## 4. Integration

| Instance | File | Connection |
| :--- | :--- | :--- |
| `u_icache` | `src/cache/SoC/sim/flash_path_system.vhd` | `i_clk` and `i_clk_cpu` wired to the same clock; memory side wired to a [mem_region_router](mem_region_router.md), whose FLASH output goes to master A of the [flash_arbiter](flash_arbiter.md) |

The icache request is always a line read. In the simulation system, the SDRAM output of the icache's router has no slave.

## 5. Verification

The tests are cocotb tests in `tests/python/unittests/cache`, registered in `tests/python/tests.json`. The formal proof is in `formal/icache/` (see [blocks](../formal/blocks.md)).

| `tests.json` entry | Test module | What it covers |
| :--- | :--- | :--- |
| `InstructionCache` | [instruction_cache.py](../../../tests/python/unittests/cache/instruction_cache.py) | A miss followed by hits in the line, sequential code across lines, a conflict that evicts the line, an unselected address never hits or fills, invalidation of every line and during a fill, address change during a fill, regions do not alias, region base in fill addresses, one miss pulse per line, region invalidation (only the line of the region, several lines, index wrap-around, a region as big as the cache, a backwards region, during a fill inside and outside the region) |
| `InstructionCacheSmall` | [instruction_cache_small.py](../../../tests/python/unittests/cache/instruction_cache_small.py) | `size_bits` equal to 4096, capacity of 32 lines, the 33rd line takes the place of the first, conflict at 512 bytes, FLASH and SDRAM at the same index conflict |
| `FlashPath` | [flash_path.py](../../../tests/python/unittests/cache/flash_path.py) | Instruction fetch from the FLASH end to end, with the icache, two routers, the arbiter and the chip |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
