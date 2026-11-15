# Formal verification of the other blocks

🌐 [Português](../../pt-br/formal/blocks.md) · [English](../../en/formal/blocks.md)

Besides the SDRAM arbiter and the AXI bridges (`formal.md`), the proofs cover the SDRAM controller, the core bridge, the two caches, the region router, the flash arbiter, the command port of the FLASH chip, the NOR FLASH and SRAM controllers and the latency counting machine of the memory models. The method is the one of `formal.md` (GHDL synthesizes the netlist, Yosys reads the properties in SystemVerilog, SymbiYosys runs the chosen engine), each block has its own `formal/<block>/` folder with `props.sv` and `run.sh`, and the proofs share the slots of `formal/common.sh`. The small memories of the caches become registers (`memory_map` after `prep`) before any engine runs, because yices treats each inferred memory as an SMT array and does not finish the `icache` and `dcache` proofs in 600 s; with registers `make formal` takes about 2 min with yices and 1 min with the others. A proof an engine does not finish in `FORMAL_TIMEOUT` seconds (600 by default) becomes a skip for that engine and is left to the others.

## 1. What is proved

| Block | Proof | Properties |
| :--- | :--- | :--- |
| `flash_arbiter` | induction, bounded (40 cycles) and cover | The two masters never receive the answer together; only the owner receives the answer and drives the flash channel; the flash data reaches both masters whole; every request is served within 6 cycles, and 5 are not enough, whatever the other master does (no starvation) |
| `flash_cmd_port` | bounded (40 cycles) and cover | It writes only while busy, with the latch armed and in an unprotected sector; the erase writes only ones and the program writes the bitwise AND of the content with the page buffer word; a command without the latch is ignored entirely; a protected sector or an address outside the window is refused, drops the latch and raises the refusal; protect and unprotect touch only the bit of the sector; the operation keeps the chip busy for at most 14 cycles (erase) or 8 (program); in the cycle in which the chip becomes idle the pulse comes, with the exact region of the written words, in order and aligned to the sector or page |
| `latency_counter` | induction and cover | The end of the count rises only on edge $N$ after the load (a count of 0 is 1), the wait covers the earlier edges, a load on the end edge restarts the count, with no load the block becomes free again and a reset clears it; the count register holds the edges that remain |
| `nor_flash_ctrl` | bounded and cover, per scenario (read, erase, program of one byte, commands) in two cycle configurations | Never `WE#` and `OE#` together, `CE#` low when one of them is, data driven only on write; each phase of the write cycle, the wait for $t_{busy}$ and the `RESET#` pulse last the number of cycles of the generics; the chip cycle sequence (unlock, command, sector or byte and buffer data, in order, no `0xFF` byte) and the wait for `RY` high before going on; write only with the latch armed and in an unprotected sector; the invalidation pulse carries the exact region and drops the latch; on read, the address advances by one every $n_{next}$ cycles after $n_{first}$, the byte read is the pin value in the last cycle and the `flash_chip` contract holds; refusal, ignored command and protection as in `flash_cmd_port` |
| `max10_flash` | bounded (40 cycles) and cover | The megafunction never receives a program without write enabled, nor an erase without it or outside sectors 1 and 2, nor a control word other than release, protect or erase a sector (never a page); one request at a time; write enabled rises only after a release write and falls only with reset or with the protection |
| `epcs_ctrl` | bounded (120 and 150 cycles) and cover, per scenario (erase, program) | On the SPI pins, only the seven instructions leave (no whole-chip erase, no status register write); PP and SE only after a finished WREN and with no other PP or SE in between; the PP and SE address in the user region and inside the chip; the SE one at a sector start; the four-byte SE and the PP of one to 256 data bytes without leaving the page; the clock low while the chip is deselected |
| `sram_ctrl` | bounded and cover, per scenario (read, write) in two cycle configurations | Never `WE#` and `OE#` together, `CE#` low when one of them is, data driven only on write; the read enables both bytes and the write only those of the byte enable, never none; each phase lasts the number of cycles of the generics; half words go out in increasing order inside the request, the watched one with the right byte enable and data, once; the data the core receives is the pin value in the last cycle of the half word and changes only on advance; an out-of-window access does not touch the chip |
| `mem_region_router` | induction and cover | Outside the flash the whole access goes to the rest of the memory; in the flash only reads inside the window reach the flash; a write to the flash and a read beyond the window end in the router, return zero and answer in the next cycle; at most one destination per access |
| `sdram_cpu_bridge` | bounded (30 cycles) and cover | A new request leaves only with the bridge free, the core asking and the initialization synchronized, and every request becomes a toggle inversion; the payload the controller sees is the core's and holds; the ready comes only after the answer, lasts until the advance and there is one answer per request; the answer is seen two cycles after the ack (the crossing goes through the `synchronizer`); the read data is the one captured when the answer was seen |
| `sdram_ctrl` | bounded (150 cycles) and cover | Initialization wait, PRECHARGE of all banks, eight REFRESH and LOAD MODE with the mode register, in this order and before the first access; tRP, tRFC, tMRD, tRCD and tRC between the commands; refresh within the period plus the time of an access in progress; every request answered, only with the right toggle |
| `icache` | bounded (28 cycles) and cover, at the tag window widths 26 and 27 (`FORMAL_WINDOWS`) | A hit on the watched address returns the data the lower memory gave; the request to the lower memory is of an aligned line; after an invalidation, no hit before a new fill; after a region invalidation that covers the watched line and changes its data, the hit returns the new data (including a fill that was under way), and a region off the line's index does not drop a hit the cache already had |
| `dcache` (write-through) | bounded (24 cycles) and cover, at the tag window widths 26 and 27 (`FORMAL_WINDOWS`) | Every accepted store reaches the lower memory once, with the right bytes, before it is acknowledged; a load of the watched word returns the last write, from a hit or from a fill; the requests to the lower memory are well formed; a flush with invalidation leaves the lines invalid; after a region invalidation that covers the watched line and changes its data, a load returns the new data, even when the fill was under way |

## 2. Assumptions about the environment

| Block | Assumption |
| :--- | :--- |
| All | One reset clock at the start and none after; the core holds the request and the address until the answer and consumes the answer in the cycle it arrives |
| `flash_arbiter` | The flash answers only an active request, within 2 cycles |
| `flash_cmd_port` | A 64-byte chip, 16-byte sectors, 8-byte pages and waits of 1 cycle; any watched word of the storage keeps the value the write gives it and the registered read returns it, and the page buffer returns any value at its position; the other words are free |
| `latency_counter` | `max_count` equal to 6; the load pulse, the value and the reset are free, with the value up to 6 and one reset clock at the start |
| `nor_flash_ctrl` | 8 KB chip with two 4 KB sectors and 8-byte pages; configuration A with one cycle in each phase and B with 3, 2, 2, 3, 5, 2 and 3; the chip data, `RY`, the command and the read request are free, and the page buffer returns any word at the watched position and `0xFFFFFFFF` at the other; each scenario turns on only the inputs it uses and, on program, limits the buffer to one byte to program |
| `max10_flash` | The register bus, the wait, the read data validity, the read data and the megafunction CSR read are free; 4-bit data address |
| `epcs_ctrl` | 128 KB chip (two 64 KB sectors), user region from 64 KB and SPI clock at half the system clock; MISO is free, the bus only writes `ADDRESS`, `LENGTH` and `COMMAND` and never reads (the buffer stays fixed) |
| `sram_ctrl` | 64-byte chip; configuration A with one cycle in each phase and B with three; address, data, byte enable and chip data are free, and the advance comes only with ready |
| `sdram_cpu_bridge` | The controller flips the ack only for a pending request, within 3 cycles, and holds the answer data until the next request |
| `sdram_ctrl` | The master flips the toggle only after the answer and holds the payload until then; the 200 us wait and the refresh period shrink to 6 and 24 cycles, and the chip timings are those of `sdram_pkg` at 7 ns and, in a second round with the netlist of `tck_ps` = 10000, at 10 ns (tRCD and tRP in 2 cycles, tRC in 6 and tRFC in 7) |
| `icache`, `dcache` | The two clocks of the `icache` connect to the same signal; the cache has two lines of 128 bits (`size_bits = 256`); any watched address plays the lower memory, which returns its word whenever it returns its line; the core addresses stay in the 64 MiB window of the watched address; the lower memory answers within 3 cycles (2 in the `dcache`) |
| `icache` | The core holds the address until the cache answers; in region mode, the watched word of the lower memory changes only at the pulse of a region that covers its line |
| `dcache` | Write-through mode, no bypass, and the watched address outside the flash region; in region mode the core only reads and the watched word of the lower memory changes only at the pulse of a region that covers its line |

## 3. Mutants

Each deliberate defect of the VHDL must make a proof fail. The `run.sh` of each block applies the edit with `sed` to a copy of the file and requires the `fail` verdict.

| Block | Mutants |
| :--- | :--- |
| `flash_arbiter` | `a_always_first`, `ready_to_both`, `b_release_wrong`, `owner_b_gets_a`, `data_swapped`, `rden_without_owner` |
| `flash_cmd_port` | `program_overwrites`, `erase_writes_zero`, `ignores_the_latch`, `protection_ignored`, `window_ignored`, `latch_stays`, `refusal_keeps_latch`, `short_by_one`, `stride_of_eight`, `unprotect_all`, `region_one_short`, `page_unaligned` |
| `latency_counter` | `zero_hangs`, `one_too_long`, `restart_ignored`, `last_never_ends`, `reset_ignored`, `wait_from_zero`, `last_at_two` |
| `nor_flash_ctrl` | `unlock_wrong`, `program_cmd_wrong`, `erase_cmd_wrong`, `sector_cmd_wrong`, `sector_unaligned`, `ff_not_skipped`, `window_ignored`, `protection_ignored`, `latch_ignored`, `ry_not_awaited`, `hardware_protect`, `read_stride_two`, `line_unaligned`, `region_one_short`, `data_bus_in_read`, `oe_with_we`, `we_width_wp_only`, `we_high_wc_only`, `busy_not_waited`, `page_uses_random`, `first_uses_page`, `reset_pulse_short` |
| `max10_flash` | `write_without_enable`, `erase_without_enable`, `erase_allowed_ignored`, `sector_below_allowed`, `sector_above_allowed`, `page_erase_requested`, `refusal_enables`, `disable_keeps_enable`, `enable_unprotects_none` |
| `epcs_ctrl` | `se_without_wren_frame`, `se_without_latch`, `se_below_user_region`, `se_unaligned`, `se_past_the_chip`, `pp_without_latch`, `pp_below_user_region`, `pp_crosses_the_page`, `pp_past_the_chip`, `pp_empty`, `bulk_erase_instruction`, `status_write_instruction`, `address_order_swapped` |
| `sram_ctrl` | `lanes_swapped`, `empty_half_written`, `stride_two`, `data_early`, `window_ignored`, `data_bus_in_read`, `oe_with_we`, `we_pulse_dropped`, `we_high_wc_dropped`, `read_wait_rc_only` |
| `mem_region_router` | `end_inclusive`, `write_not_local`, `slave_sees_flash`, `local_not_zero`, `local_hangs`, `flash_gets_local`, `window_by_base`, `advance_to_both` |
| `sdram_cpu_bridge` | `wrong_rdata`, `rdata_x_zero`, `init_ignored`, `ack_unsynced`, `no_advance_wait`, `write_as_read`, `address_shifted`, `request_lost`, `write_updates_rdata` |
| `sdram_ctrl` | `no_precharge`, `few_refreshes`, `init_wait_short`, `mode_wrong`, `init_done_early`, `trcd_short`, `trp_short`, `trfc_short`, `trc_short`, `refresh_never` |
| `icache` | `dropped_fill_valid`, `invalidate_keeps`, `tag_always_matches`, `ready_without_addr`, `fill_word_swapped`, `hit_without_sel`, `partial_line`, `region_ignored`, `fill_not_dropped`, `region_too_wide`, `region_one_short`, `big_region_partial` |
| `dcache` | `hit_store_not_cached`, `write_back_on_hit`, `byteena_lost`, `fill_word_swapped`, `hit_ignores_tag`, `store_acked_early`, `store_data_lost`, `inv_inverted`, `region_ignored`, `fill_stays_valid`, `fill_not_marked`, `region_one_short` |

## 4. What the proofs do not cover

1. The tRAS has no command of its own: the controller uses auto-precharge, and the time between two ACTIVE is at least the tRC, which adds tRAS and tRP.
2. The `dcache` in write-back mode, the bypass, the flash region and the flush without invalidation: the platform mode is write-through.
3. The first word of a line read right after an invalidation: the valid bit read has a one-cycle delay, and the proof holds from the second cycle after the invalidation.
4. The fill of a line while the core asks for another address of the same index: the core must hold the address until the answer, because the new words of the incoming line are seen with the tag and the valid bit of the old line while it is written.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
