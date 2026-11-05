# Formal verification of the other blocks

🌐 [Português](../../pt-br/formal/blocks.md) · [English](../../en/formal/blocks.md)

Besides the SDRAM arbiter and the AXI bridges (`formal.md`), the proofs cover the SDRAM controller, the core bridge, the two caches, the region router and the flash arbiter. The method is the one of `formal.md` (GHDL synthesizes the netlist, Yosys reads the properties in SystemVerilog, SymbiYosys runs the chosen engine), each block has its own `formal/<block>/` folder with `props.sv` and `run.sh`, and the proofs share the slots of `formal/common.sh`.

## 1. What is proved

| Block | Proof | Properties |
| :--- | :--- | :--- |
| `flash_arbiter` | induction, bounded (40 cycles) and cover | The two masters never receive the answer together; only the owner receives the answer and drives the flash channel; the flash data reaches both masters whole; every request is served within 6 cycles, and 5 are not enough, whatever the other master does (no starvation) |
| `mem_region_router` | induction and cover | Outside the flash the whole access goes to the rest of the memory; in the flash only reads inside the window reach the flash; a write to the flash and a read beyond the window end in the router, return zero and answer in the next cycle; at most one destination per access |
| `sdram_cpu_bridge` | bounded (30 cycles) and cover | A new request leaves only with the bridge free, the core asking and the initialization synchronized, and every request becomes a toggle inversion; the payload the controller sees is the core's and holds; the ready comes only after the answer, lasts until the advance and there is one answer per request; the answer is seen two cycles after the ack (the crossing goes through the `synchronizer`); the read data is the one captured when the answer was seen |
| `sdram_ctrl` | bounded (200 cycles) and cover | Initialization wait, PRECHARGE of all banks, eight REFRESH and LOAD MODE with the mode register, in this order and before the first access; tRP, tRFC, tMRD, tRCD and tRC between the commands; refresh within the period plus the time of an access in progress; every request answered, only with the right toggle |
| `icache` | bounded (28 cycles) and cover | A hit on the watched address returns the data the lower memory gave; the request to the lower memory is of an aligned line; after an invalidation, no hit before a new fill |
| `dcache` (write-through) | bounded (24 cycles) and cover | Every accepted store reaches the lower memory once, with the right bytes, before it is acknowledged; a load of the watched word returns the last write, from a hit or from a fill; the requests to the lower memory are well formed; a flush with invalidation leaves the lines invalid |

## 2. Assumptions about the environment

| Block | Assumption |
| :--- | :--- |
| All | One reset clock at the start and none after; the core holds the request and the address until the answer and consumes the answer in the cycle it arrives |
| `flash_arbiter` | The flash answers only an active request, within 2 cycles |
| `sdram_cpu_bridge` | The controller flips the ack only for a pending request, within 3 cycles, and holds the answer data until the next request |
| `sdram_ctrl` | The master flips the toggle only after the answer and holds the payload until then; the 200 us wait and the refresh period shrink to 6 and 40 cycles, and the chip timings are those of `sdram_pkg` at 7 ns |
| `icache`, `dcache` | The two clocks of the `icache` connect to the same signal; the cache has two lines of 128 bits (`size_bits = 256`); any watched address plays the lower memory, which returns its word whenever it returns its line; the core addresses stay in the 64 MiB window of the watched address; the lower memory answers within 3 cycles (2 in the `dcache`) |
| `icache` | The core holds the address until the cache answers |
| `dcache` | Write-through mode, no bypass, and the watched address outside the flash region |

## 3. Mutants

Each deliberate defect of the VHDL must make a proof fail. The `run.sh` of each block applies the edit with `sed` to a copy of the file and requires the `fail` verdict.

| Block | Mutants |
| :--- | :--- |
| `flash_arbiter` | `a_always_first`, `ready_to_both`, `b_release_wrong`, `owner_b_gets_a`, `data_swapped`, `rden_without_owner` |
| `mem_region_router` | `end_inclusive`, `write_not_local`, `slave_sees_flash`, `local_not_zero`, `local_hangs`, `flash_gets_local`, `window_by_base`, `advance_to_both` |
| `sdram_cpu_bridge` | `wrong_rdata`, `rdata_x_zero`, `init_ignored`, `ack_unsynced`, `no_advance_wait`, `write_as_read`, `address_shifted`, `request_lost`, `write_updates_rdata` |
| `sdram_ctrl` | `no_precharge`, `few_refreshes`, `init_wait_short`, `mode_wrong`, `init_done_early`, `trcd_short`, `trp_short`, `trfc_short`, `trc_short`, `refresh_never` |
| `icache` | `dropped_fill_valid`, `invalidate_keeps`, `tag_always_matches`, `ready_without_addr`, `fill_word_swapped`, `hit_without_sel`, `partial_line` |
| `dcache` | `hit_store_not_cached`, `write_back_on_hit`, `byteena_lost`, `fill_word_swapped`, `hit_ignores_tag`, `store_acked_early`, `store_data_lost`, `inv_keeps` |

## 4. What the proofs do not cover

1. The tRAS has no command of its own: the controller uses auto-precharge, and the time between two ACTIVE is at least the tRC, which adds tRAS and tRP.
2. The `dcache` in write-back mode, the bypass, the flash region and the flush without invalidation: the platform mode is write-through.
3. The first word of a line read right after an invalidation: the valid bit read has a one-cycle delay, and the proof holds from the second cycle after the invalidation.
4. The fill of a line while the core asks for another address of the same index: the core must hold the address until the answer, because the new words of the incoming line are seen with the tag and the valid bit of the old line while it is written.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
