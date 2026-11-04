# onchip_ram_port

## 1. Role of the component in the SoC

The on-chip RAM adapter puts the FPGA RAM block behind the line contract of the memory side, the same one as the [ram_chip](ram_chip.md). With it, an internal RAM can sit behind the data cache and the region router, with the wait and the line protocol of an external memory, and the requester cannot tell one from the other. The adapter has no storage of its own and is synthesizable. It holds a state machine and the registers of the access, and the storage is the RAM block wired to the `o_mem_*` ports and `i_mem_q`, which can be the [ram](ram.md) IP on the board or the [ram_simulation](ram_simulation.md) model in simulation.

The RAM block has a single word port with a registered read. The adapter moves a four-word line as four consecutive accesses to that port, one per edge, and uses the same port for debug in the cycles when no access occupies it.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `size_bytes` | positive | 1048576 | size of the RAM window in bytes, a power of two from 16 bytes to 32 MB |
| `base_kib` | natural | 0 | where the RAM starts inside the 64 MB region, in KiB; the RAM address is the region address minus this base |

With $S$ equal to `size_bytes`, the word index of the RAM block has $\log_2 S - 2$ bits, the same width as the `i_address` port of the `ram` IP.

### 2.2. Requester ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | clock of the module and of the RAM block |
| `i_rst` | input | 1 | synchronous reset, active at `'1'` |
| `i_addr` | input | 32 | byte address of the access |
| `i_wdata` | input | 32 | write data (word 0 of the line) |
| `i_byteena` | input | 4 | byte enables of the write (word 0) |
| `i_rden` | input | 1 | read request |
| `i_wren` | input | 1 | write request, which wins over the read if both come together |
| `i_mem_advance` | input | 1 | the pipeline advanced in this cycle, the completed access can end |
| `o_ready` | output | 1 | access completed, the read data is valid |
| `o_rdata` | output | 32 | read data (word 0 of the line) |
| `i_line` | input | 1 | line access, four consecutive words (default `'0'`) |
| `i_wdata_x` | input | 96 | words 1 to 3 of the line write data, word 1 in the lowest bits |
| `i_byteena_x` | input | 12 | byte enables of words 1 to 3, four bits per word |
| `o_rdata_x` | output | 96 | words 1 to 3 of the line read data |

### 2.3. RAM block ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `o_mem_addr` | output | $\log_2 S - 2$ | word index |
| `o_mem_wdata` | output | 32 | write data |
| `o_mem_byteena` | output | 4 | byte enables of the write |
| `o_mem_rden` | output | 1 | read enable |
| `o_mem_wren` | output | 1 | write enable |
| `i_mem_q` | input | 32 | read word, valid one cycle after the address |

### 2.4. Debug port

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_dbg_word_addr` | input | 24 | index of the word read, counted from the start of the window and not shifted by `base_kib` |
| `o_dbg_word_data` | output | 32 | RAM word at that index |

## 3. Behavior

### 3.1. Access contract

The access stays on `i_addr`, `i_rden` or `i_wren` and `i_line` while the stage that requests it is stalled. `o_ready` rises when the access finishes and stays high until `i_mem_advance` is `'1'`. The read data (`o_rdata`, `o_rdata_x`) changes only on that edge, because the load still in the write-back stage reads the previous value until then. The port accepts requests again on the edge after the advance.

The address of a word access is aligned to 4 bytes, and that of a line access to 16 bytes. A line moves the four words that follow the aligned address, and a write updates only the enabled bytes of each word.

### 3.2. Address window

The adapter uses the low 26 bits of the byte address. With $B$ equal to $1024 \cdot$ `base_kib` and $S$ equal to `size_bytes`, the word index is

$$\text{index} = \frac{a_{25..0} - B}{4}, \qquad B \le a_{25..0} < B + S$$

Outside this interval the read returns zero and the write is dropped, without an error, and the access takes the same time as one inside the window.

### 3.3. State machine and latency

| State | Action | Next state |
| :--- | :--- | :--- |
| `S_IDLE` | with `i_rden` or `i_wren`, captures address, data and masks and clears the step | `S_ACCESS` |
| `S_ACCESS` | step $k$ issues word $k$ to the block, and step $k+1$ collects the word read; at the end of the step after the last word, it finishes | `S_DONE` |
| `S_DONE` | `o_ready` at `'1'`; with `i_mem_advance`, copies the collected data to the read output | `S_IDLE` |

The latency is low and constant. Let $E_0$ be the edge on which the request is seen. A word access ends on edge $E_2$ and a line access on edge $E_5$, and `o_ready` rises right after. Reads and writes take the same time, at any address and also outside the window.

| Access | Edges until `o_ready` |
| :--- | ---: |
| Word | 2 |
| Line | 5 |

### 3.4. Debug port

Debug reads the block through the same port, in the cycles when the adapter is free (no request) or has a completed access waiting for the advance. A new index shows up on `o_dbg_word_data` 2 edges after the change when the port is free, and the output keeps the last value read while it is not. A debug read never delays or alters an access in progress. An index outside the window reads zero. The testbench uses this port to read the `tohost` without going through the caches.

## 4. Integration

| Item | Description |
| :--- | :--- |
| Above it | the data cache ([dcache](../cache/dcache.md)) and, when the ROM is also behind a cache, the router [mem_region_router](../cache/mem_region_router.md); the line ports carry the lines of the cache |
| Below it | the [ram](ram.md) IP on the board, or the [ram_simulation](ram_simulation.md) in simulation, wired through the `o_mem_*` ports and `i_mem_q` |
| Requester port list | the data port of the [ram_chip](ram_chip.md), which lets the top swap one for the other |
| Instruction port | the adapter has a single access port, because the RAM block has a single port |

## 5. Verification

The simulation top `onchip_ram_system` wires the adapter to `ram_simulation`, with the `dcache` in front or not. With the `use_chip` generic, the `ram_chip` takes the place of the adapter and the model, and the same test runs on both, so the `ram_chip` is the reference of the contract.

| `tests/python/tests.json` entry | Test module | Parameters |
| :--- | :--- | :--- |
| `OnchipRamPort` | `onchip_ram_port` | `SIZE_BYTES` equal to 4096 |
| `OnchipRamPortChip` | `onchip_ram_port` | `SIZE_BYTES` equal to 4096 and `USE_CHIP` true |
| `OnchipRamLatency` | `onchip_ram_latency` | `SIZE_BYTES` equal to 4096 |
| `OnchipRamOffset` | `onchip_ram_offset` | `SIZE_BYTES` equal to 4096 and `BASE_KIB` equal to 8 |
| `OnchipRamDcache` | `onchip_ram_dcache` | `WITH_CACHE` true |
| `OnchipRamDcacheWriteThrough` | `onchip_ram_dcache` | `WITH_CACHE` and `WRITE_THROUGH` true |
| `OnchipRamDcacheChip` | `onchip_ram_dcache` | `WITH_CACHE` and `USE_CHIP` true |

| Test | Checks |
| :--- | :--- |
| `test_a_word_is_written_and_read_back` | a stored word comes back and the debug port sees it |
| `test_byte_enables_keep_the_other_bytes` | the 16 masks change only the enabled bytes |
| `test_a_line_is_written_and_read_back` | the line write and read move four words from the 16-byte boundary |
| `test_a_line_write_keeps_the_masked_bytes` | the byte enables of words 1 to 3 apply to the line write |
| `test_the_read_data_changes_on_advance` | `o_ready` waits for the advance and the old data is kept until then |
| `test_outside_the_window_reads_zero_and_drops_stores` | outside the window the read is zero, the write vanishes and addresses do not wrap |
| `test_the_debug_port_ends_with_the_window` | the debug port reads zero beyond the last word |
| `test_the_latency_of_a_word_is_constant` and `test_the_latency_of_a_line_is_constant` | 3 and 6 edges counting edge $E_0$, equal for read and write |
| `test_the_outside_of_the_window_takes_the_same_time` | an access outside the window is not faster |
| `test_the_debug_port_reads_while_ready_waits` | debug reads while `o_ready` waits and does not drop it |
| `test_the_debug_port_does_not_disturb_an_access` | changing the debug index at every clock does not alter the accesses |
| `test_the_ram_starts_at_the_base` and `test_outside_the_ram_is_zero` | with `base_kib` equal to 8, the first word is the one at the base and the neighbors outside the window read zero |
| `test_write_then_read`, `test_byte_enables`, `test_eviction_writes_back` and `test_random_traffic` | the `dcache` over the adapter, with random traffic compared with a Python copy of the memory, also after the flush |

There is no formal proof of this block.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
