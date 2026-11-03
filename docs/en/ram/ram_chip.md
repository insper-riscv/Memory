# ram_chip

## 1. Role of the component in the SoC

The external RAM chip model plays, on the simulated platforms, the role of the board SDRAM, without the controller or the chip model. It is a vector of 32-bit words with two access ports, one for data and one for instructions, plus a per-word debug port. It uses the same request and completion contract as the SDRAM bridge, so the caches and the router between the core and the external memory cannot tell this model from the real SDRAM. The model is not synthesizable for the board, because it uses file reading and a protected variable.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `init_file` | string | empty | file with the initial image, one 32-bit word per line in hexadecimal, from the first address of the window; empty leaves everything at zero |
| `latency` | natural | 8 | edges of `i_clk` between the request and the completion of the access, minimum 2, maximum 255 |
| `size_bytes` | positive | 1048576 | size of the chip window in bytes, a power of two from 16 bytes to 32 MB |
| `base_kib` | natural | 0 | where the chip starts inside the 64 MB region, in KiB; the chip address is the region address minus this base |

### 2.2. Data port signals

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | module clock |
| `i_rst` | input | 1 | synchronous reset, active at `'1'` |
| `i_addr` | input | 32 | byte address of the access |
| `i_wdata` | input | 32 | write data (word 0 of the line) |
| `i_byteena` | input | 4 | byte enables of the write (word 0) |
| `i_rden` | input | 1 | read request |
| `i_wren` | input | 1 | write request, which prevails over the read if both come together |
| `i_mem_advance` | input | 1 | the pipeline advanced in this cycle, the completed access may end |
| `o_ready` | output | 1 | access completed, the read data is valid |
| `o_rdata` | output | 32 | read data (word 0 of the line) |
| `i_line` | input | 1 | line access, four consecutive words (default `'0'`) |
| `i_wdata_x` | input | 96 | words 1 to 3 of the line write data, word 1 in the lowest bits |
| `i_byteena_x` | input | 12 | byte enables of words 1 to 3, four bits per word |
| `o_rdata_x` | output | 96 | words 1 to 3 of the line read data |

### 2.3. Instruction port signals

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_ins_addr` | input | 32 | byte address of the access |
| `i_ins_rden` | input | 1 | read request |
| `i_ins_advance` | input | 1 | the pipeline advanced in this cycle |
| `o_ins_ready` | output | 1 | access completed, the read data is valid |
| `o_ins_rdata` | output | 32 | read data (word 0 of the line) |
| `i_ins_line` | input | 1 | line access (default `'0'`) |
| `o_ins_rdata_x` | output | 96 | words 1 to 3 of the line read data |

The instruction port only reads. The default values of the instruction port inputs and of `i_line`, `i_wdata_x` and `i_byteena_x` leave unconnected ports inactive.

### 2.4. Status and debug signals

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `o_init_done` | output | 1 | the chip accepts requests, at `'1'` from the edge after the end of reset |
| `i_dbg_word_addr` | input | 24 | index of the word read by the debug port, counted from the start of the window |
| `o_dbg_word_data` | output | 32 | chip word at that index, updated at every edge and at every index change |

## 3. Behavior

### 3.1. Address window

The chip uses the low 26 bits of the byte address, and the high bits are ignored. With $B$ equal to `base_kib` in bytes ($1024 \cdot$ `base_kib`) and $S$ equal to `size_bytes`, the word index is

$$\text{index} = \frac{a_{25..0} - B}{4}, \qquad B \le a_{25..0} < B + S$$

An address outside that interval is outside the window: a read returns zero and a write is dropped, with no error. In a line access, the words whose index is above the last one are not written and are read as zero.

### 3.2. Word and line access

The address of a word access is aligned to 4 bytes, and that of a line access to 16 bytes. A line moves the four words that follow the aligned address, word 0 on `i_wdata`, `i_byteena` and `o_rdata`, and words 1 to 3 on the `_x` vectors. A write updates only the enabled bytes of each word.

### 3.3. State machine of a port

The two ports have independent three-state machines over the same vector. A request is accepted only with `o_init_done` at `'1'`.

| State | Action | Next state |
| :--- | :--- | :--- |
| `S_IDLE` | with `i_rden` or `i_wren` (data port) or `i_ins_rden` (instruction port), captures address, data and masks and loads the counter with `latency` | `S_WAIT` |
| `S_WAIT` | while the counter is greater than 1, decrements; on the edge where it is 1, accesses the vector (write, or read into a pending register) | `S_DONE` |
| `S_DONE` | `o_ready` at `'1'`; when `i_mem_advance` (or `i_ins_advance`) is `'1'`, copies the pending data to the read output | `S_IDLE` |

### 3.4. Latency

Let $E_0$ be the edge where the request is accepted. The vector access happens on edge $E_L$, with $L$ equal to `latency`, and `o_ready` rises right after it, so $L$ edges pass between the request and the completion. The write and the read happen at the end of the latency, so a store of the data port is seen by a read of the instruction port requested after its completion.

`o_ready` stays high until the edge where `i_mem_advance` is `'1'`, and the read data (`o_rdata`, `o_rdata_x`) changes only on that same edge. The reason is that the load still in the write-back stage reads the previous value until then. The first `i_mem_advance` that counts is the one on edge $E_{L+1}$ or a later one, and the port accepts requests again on the edge after the advance.

### 3.5. Initial load and debug port

At time zero, a process reads `init_file` line by line and writes each valid word in sequence from index 0, the same format as the simulated SDRAM image file. Lines that are not hexadecimal are skipped. The debug port reads the vector without going through the access ports, and its index is not shifted by `base_kib`.

## 4. Integration

| Item | Description |
| :--- | :--- |
| Instantiated in | `src/simulation/modular/modular_sim_top.vhd` of the Insper-RISC-V repository, when `ram_external` is true, with `init_file` equal to `ram_file`, `latency` equal to `ext_ram_latency`, `size_bytes` equal to `ram_size_bytes` and `base_kib` equal to `ram_base_kib` modulo 65536 |
| Above it | the data cache (`src/cache/soc/dcache.vhd`), the instruction cache (`src/cache/soc/icache.vhd`) and, when the ROM is also external, the `mem_region_router` router; the line ports carry the cache lines |
| Contract | the same as the SDRAM bridge (`sdram_cpu_bridge`) and the external port of the core, described in [ext_interconnect.md](https://github.com/insper-riscv/Insper-RISC-V/blob/main/docs/en/interconnect/ext_interconnect.md) |
| Port list | the same as `sdram_system`, which lets the top swap one for the other |
| Debug port | in the modular top, the testbench reads the HTIF `tohost` through it when it is in the chip, without going through the caches |

The modular top feeds `ram_base_kib` and `ram_size_bytes` from the platform memory map. In the core map, the internal RAM spans `0x00008000` to `0x3FFFFFFF` by default and the external window starts at `0x40000000`, and the full map is in the bus and memory contract of the Core repository. The line access format, with word 1 in the lowest bits of the `_x` vectors, is that of the real SDRAM, described in [sdram_line.md](sdram_line.md), and the cache and bus path that leads to the SDRAM is in [dcache_axi.md](../barramento/dcache_axi.md).

## 5. Verification

The tests of `tests/python/unittests/ram/ram_chip.py` run in three configurations of `tests/python/tests.json`.

| Entry | Test module | Parameters |
| :--- | :--- | :--- |
| `RamChip` | `ram_chip` | default (1 MB, latency 8) |
| `RamChipSmall` | `ram_chip_small` | `SIZE_BYTES` equal to 4096 |
| `RamChipOffset` | `ram_chip_offset` | `SIZE_BYTES` equal to 4096 and `BASE_KIB` equal to 8 |

| Test | Checks |
| :--- | :--- |
| `test_a_word_is_written_and_read_back` | a written word comes back and each access takes at least `latency` edges, and the debug port sees it |
| `test_byte_enables_keep_the_other_bytes` | only the enabled bytes change |
| `test_a_line_is_written_and_read_back` | the line write and read move four words from the 16-byte boundary |
| `test_the_read_data_changes_on_advance` | `o_ready` waits for the advance and the old data is kept until then |
| `test_the_instruction_port_sees_the_stores_of_the_data_port` | the instruction port sees the stores, by word and by line |
| `test_outside_the_window_reads_zero_and_drops_stores` | outside the window the read is zero, the write vanishes and addresses do not wrap |

The modules `ram_chip_small` and `ram_chip_offset` bring their own tests.

| Test | Checks |
| :--- | :--- |
| `test_the_window_follows_the_generic` | with 4 KB, the last word is kept, the next one reads zero and nothing wraps the address |
| `test_the_debug_port_ends_with_the_window` | the debug port reads zero past the end of the chip |
| `test_the_chip_starts_at_the_base` | with `base_kib` equal to 8, the first word of the chip is the one at the base address, and the debug port sees it at index 0 |
| `test_outside_the_chip_is_zero` | the word before the base and the one after the end read zero, and the stores outside do not wrap the address |

There is no formal proof of this block.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
