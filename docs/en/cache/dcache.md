# dcache

## 1. Role of the component in the SoC

The dcache is the core's data cache. It sits on the memory path of the SDRAM and FLASH addresses, between the pipeline's memory stage and a memory port that moves one word at a time or one line of four words. Peripherals never go through it. The pipeline stays stopped while an access is in progress, so the cache serves one access at a time.

| Property | Value |
| :--- | :--- |
| Organization | Direct-mapped, 16-byte lines (four words) |
| Size | Generic `size_bits` (4 KB by default) |
| Write policy | Write-back with write-allocate, or write-through with write-around (generic `write_through`) |
| Regions served | SDRAM and FLASH, told apart by one tag bit |
| RAM read | Registered, as in FPGA block RAMs |

The overview of the path from the core to the SDRAM, the cost measurements and the design choices are in [dcache_axi.md](../barramento/dcache_axi.md) and [dcache_axi_decisions.md](../barramento/dcache_axi_decisions.md). The reason for the write-through policy on platforms with a debug port is in [CACHE_HOST_COHERENCE.md](../bugs/CACHE_HOST_COHERENCE.md).

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `size_bits` | positive | 32768 | Cache size in bits, a power of two of at least 256 (two lines). 32768 is 4 KB and 4096 is 4 kbit |
| `base_sdram` | 6-bit vector | `010000` | Bits 31 to 26 appended to SDRAM addresses on the memory side (0x40000000) |
| `base_flash` | 6-bit vector | `001000` | Bits 31 to 26 appended to FLASH addresses on the memory side (0x20000000) |
| `rom_base_kib` | natural | 524288 | Base of the ROM region in KiB; whatever falls in it is treated as FLASH (0x20000000) |
| `rom_end_kib` | natural | 1048576 | Exclusive end of the ROM region in KiB (0x40000000) |
| `write_through` | boolean | false | True makes every store also go to memory and a store miss not bring the line in |

### 2.2. Core-side ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | Module clock |
| `i_rst` | input | 1 | Reset, active at 1; invalidates every line |
| `i_addr` | input | 32 | Access address |
| `i_wdata` | input | 32 | Write data |
| `i_byteena` | input | 4 | Write byte enables, one bit per byte |
| `i_rden` | input | 1 | Read request |
| `i_wren` | input | 1 | Write request |
| `i_mem_advance` | input | 1 | The pipeline advanced, the completed access may be released |
| `o_ready` | output | 1 | Access completed; stays at 1 until `i_mem_advance` |
| `o_rdata` | output | 32 | Read data; changes only on the edge in which the pipeline advances |
| `i_flush` | input | 1 | Requests that every dirty line be written back; one pulse is enough |
| `i_invalidate` | input | 1 | At 1 in the same cycle as `i_flush`, drops every line after the write-back (default 0) |
| `i_bypass` | input | 1 | The access does not go through the cache (default 0) |
| `o_miss` | output | 1 | One-cycle pulse at the start of each line fill |
| `o_flush_done` | output | 1 | One-cycle pulse at the end of the flush |
| `o_busy` | output | 1 | A flush is pending or in progress |

### 2.3. Memory-side ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `o_d_addr` | output | 32 | Request address, with the region base in bits 31 to 26 |
| `o_d_wdata` | output | 32 | Write data (word 0 of a line write) |
| `o_d_byteena` | output | 4 | Write byte enables |
| `o_d_rden` | output | 1 | Read request |
| `o_d_wren` | output | 1 | Write request |
| `o_d_line` | output | 1 | The request is for a line of four words |
| `o_d_wdata_x` | output | 96 | Words 1 to 3 of the line write data |
| `o_d_advance` | output | 1 | Equal to `i_d_ready`; the cache consumes the answer in the same cycle |
| `i_d_ready` | input | 1 | Request completed |
| `i_d_rdata` | input | 32 | Read data (word 0 of a line read) |
| `i_d_rdata_x` | input | 96 | Words 1 to 3 of the line read (default zeros) |

## 3. Behavior

### 3.1. Address split

With $I = \log_2(\texttt{size\_bits}) - 7$ index bits, the cache has $2^I$ lines and the address splits as in the table.

| Field | Address bits | Width |
| :--- | :--- | ---: |
| Word in line | 3 to 2 | 2 |
| Index | $I+3$ to 4 | $I$ |
| Tag | 25 to $I+4$ | $22-I$ |
| Region | Computed from `rom_base_kib` and `rom_end_kib`; becomes the most significant tag bit | 1 |

$$
\text{TAG\_BITS} = 23 - I
$$

Bits 31 to 26 are not stored. In a memory-side request, the cache rebuilds them with `base_flash` (ROM region) or `base_sdram`. With the default size, $I = 8$ (256 lines) and the tag has 15 bits.

The choice of base in a fill reads bit 14 of the tag, not the most significant bit. The two coincide only when $\text{TAG\_BITS} = 15$, that is, with `size_bits` equal to 32768. The choice of base in the write-back uses the most significant tag bit, for any size.

### 3.2. Core-side contract

The access stays on `i_addr`, `i_wdata`, `i_byteena`, `i_rden` and `i_wren` while the memory stage is stopped. `o_ready` rises when the access finishes and stays at 1 until `i_mem_advance`. `o_rdata` takes the read data only on the edge in which `i_mem_advance` completes a read access.

### 3.3. State machine

| Group | States | Function |
| :--- | :--- | :--- |
| Access | `S_IDLE`, `S_LOOK`, `S_DONE` | Wait, RAM lookup and delivery of the result |
| Write-back | `S_WB_RD`, `S_WB_CAP`, `S_WB_REQ`, `S_WB_WAIT` | Reads the four words of the dirty line and writes them to memory in one line request |
| Fill | `S_FILL_REQ`, `S_FILL_WAIT`, `S_FILL_GET` | Requests the line and stores the four words in the RAMs |
| Flush | `S_FL_TAG`, `S_FL_CHK`, `S_FL_NEXT` | Sweeps the lines one by one |
| Write-through | `S_WT_REQ`, `S_WT_WAIT` | Forwards the single-word store to memory |
| Uncached | `S_BY_REQ`, `S_BY_WAIT`, `S_BY_GET` | Reads one word from memory without consulting the cache |

In `S_IDLE`, a pending flush takes priority over an access. In `S_LOOK`, the decision follows the order of the table.

| Order | Condition | Next state | Effect |
| ---: | :--- | :--- | :--- |
| 1 | `i_bypass` at 1 and `i_wren` at 0 | `S_BY_REQ` | One-word load straight from memory |
| 2 | `i_wren` at 1 and (`write_through` or address in the ROM or `i_bypass` at 1) | `S_WT_REQ` | Store forwarded to memory |
| 3 | Hit | `S_DONE` | A load keeps the word read; a store marks the line dirty |
| 4 | Miss, line valid and dirty | `S_WB_RD` | Write-back and then fill |
| 5 | Miss, line clean or invalid | `S_FILL_REQ` | Fill |

A hit is the line being valid with the stored tag equal to the address tag. In a store that follows order 2 and hits, the RAMs also receive the word, except when the address is in the ROM or `i_bypass` is at 1. Thus a store to the FLASH never changes the cache, neither on a hit nor on a miss; it is only forwarded to memory, where the region router completes it with no effect.

After the fill, the machine returns to `S_IDLE` and repeats the lookup, so the access that caused the miss is served as a hit. For a store without `write_through`, this marks the line dirty (write-allocate).

### 3.4. Latencies

Counted in `i_clk` cycles, from the cycle in which the access appears with the machine in `S_IDLE` to the first cycle with `o_ready` at 1. Let $k$ be the number of cycles the memory takes to answer, counted in the wait cycles of the corresponding state ($k \ge 1$).

| Access | Cycles |
| :--- | :--- |
| Load or store hit (no write-through) | $2$ |
| Miss with clean or invalid line | $9 + k$ |
| Miss with dirty line | $18 + k_w + k_r$, with $k_w$ in the write-back and $k_r$ in the fill |
| Store with write-through | $3 + k$ |
| Uncached load | $4 + k$ |

The extra cycle of the uncached load is `S_BY_GET`, which reads `i_d_rdata` one cycle after `i_d_ready`, because the data changes only on the edge in which the memory advances. The same rule holds in the fill, where `S_FILL_GET` walks words 0 to 3 in four cycles.

### 3.5. Write-back

Each word of the line is read from the RAM (`S_WB_RD` and `S_WB_CAP`, two cycles per word) and accumulated in a 128-bit register. The line request uses the address $\text{base} \,\Vert\, \text{tag} \,\Vert\, \text{index} \,\Vert\, 0000_2$, with word 0 on `o_d_wdata` and words 1 to 3 on `o_d_wdata_x`. On `i_d_ready`, the line becomes clean. If the write-back came from a flush, the sweep continues; otherwise the fill follows.

### 3.6. Flush and invalidate

| Step | Description |
| :--- | :--- |
| Request | One cycle with `i_flush` at 1 registers the request, and `o_busy` rises in the next cycle. The value of `i_invalidate` in the last `i_flush` cycle decides whether the sweep drops the lines |
| Start | In `S_IDLE`, before any waiting access. An access already in `S_LOOK` or beyond finishes first, and an access that arrives later waits for the end |
| Sweep | For each line, `S_FL_TAG`, `S_FL_CHK` and `S_FL_NEXT`; a valid dirty line goes through the write-back first |
| End | After the last line, `o_flush_done` pulses and `o_busy` falls in the same cycle; with invalidate, every line becomes invalid |

The sweep of a cache with no dirty lines takes $3 \cdot 2^I$ cycles, plus the start cycle. A new `i_flush` during the sweep schedules one more sweep. `i_invalidate` alone, without `i_flush`, has no effect.

### 3.7. Miss pulse

`o_miss` is at 1 in `S_FILL_REQ`, one cycle per fill. Uncached loads and write-through stores produce no pulse.

## 4. Integration

| Instance | File | Connection |
| :--- | :--- | :--- |
| `u_cache` | `ext_axi_interconnect` of the Insper-RISC-V repository | Memory side wired to the AXI4 master (`axi_master_bridge`) through a multiplexer shared with the core's direct access; `i_flush` takes the request of peripheral 7 and `i_invalidate` takes bit 1 of the data written to it; `i_bypass` stays at its default |
| `u_cache` | `src/cache/SoC/sim/sdram_dcache_system.vhd` | Memory side wired to `axi_master_bridge`, `axi_slave_word_bridge` and the SDRAM controller, for simulation |

In the interconnect, the region generics keep their defaults and only `base_sdram` and `write_through` are passed on. Accesses to peripherals and to the last 4 KB window of the SDRAM do not reach the cache, because the interconnect diverts them. The full layout of the path is in [dcache_axi.md](../barramento/dcache_axi.md), and the contention for the AXI4 master between the cache and the core's direct access is in [CACHE_MASTER_SHARING.md](../bugs/CACHE_MASTER_SHARING.md).

For the FLASH, the memory side of the cache can go through a [mem_region_router](mem_region_router.md), which separates SDRAM from FLASH and completes stores to the FLASH with no effect. Instruction fetch uses the [icache](icache.md).

## 5. Verification

The tests are cocotb tests in `tests/python/unittests/cache`, registered in `tests/python/tests.json`. The cache has no formal proofs.

| `tests.json` entry | Test module | What it covers |
| :--- | :--- | :--- |
| `DataCache` | [data_cache.py](../../../tests/python/unittests/cache/data_cache.py) | Write and read back, hit and miss latency, byte enables, stability of `o_ready` and `o_rdata`, eviction with write-back, random traffic, flush keeping the lines valid; compares the chip memory with a Python copy |
| `DataCacheWriteThrough` | [data_cache_write_through.py](../../../tests/python/unittests/cache/data_cache_write_through.py) | A store reaches the chip with no flush, a store miss does not bring the line in, a hit updates line and chip, random traffic |
| `DataCacheFlash` | [data_cache_flash.py](../../../tests/python/unittests/cache/data_cache_flash.py) | FLASH load is cached, a store never changes the FLASH line, regions do not alias, an SDRAM store still updates the line, `i_bypass` on load and store, one miss pulse per line |
| `DataCacheSmall` | [data_cache_small.py](../../../tests/python/unittests/cache/data_cache_small.py) | `size_bits` equal to 4096 with `write_through`, capacity of 32 lines and conflict at 512 bytes; uses only SDRAM addresses |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
