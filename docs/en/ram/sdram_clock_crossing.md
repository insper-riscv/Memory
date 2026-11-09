# Clock domain crossing between the core and the SDRAM

## 1. The two domains

The core and the SDRAM controller run on clocks with no phase relation. Every memory access crosses the boundary twice, once for the request and once for the response.

| Domain | Clock | Blocks |
| :--- | :--- | :--- |
| Core | `i_clk_cpu` | `sdram_cpu_bridge` (one instance for data and one for instructions) |
| Memory | `i_clk_mem` | `sdram_arbiter`, `sdram_ctrl`, debug master and chip model |

The boundary sits between the bridge and the arbiter. The arbiter and the controller share a clock, so the controller uses the arbiter's toggle directly, with the `sync_req` parameter set to `false`.

## 2. Mechanism

A 1-bit signal that changes level can cross safely through a chain of flip-flops in series. A wide bus cannot, because each bit would be sampled at a different instant. The crossing combines both cases.

| Signal | Width | Source | Destination | How it crosses |
| :--- | ---: | :--- | :--- | :--- |
| `req_tog` | 1 | bridge | arbiter | two-flip-flop synchronizer |
| `ack_tog` | 1 | arbiter | bridge | two-flip-flop synchronizer |
| `init_done` | 1 | controller | bridge | two-flip-flop synchronizer |
| address, write data, byte enables, `we`, `line`, words 1 to 3 | 24 + 32 + 4 + 1 + 1 + 96 + 12 | bridge | arbiter | direct, held stable |
| read data, words 1 to 3 | 32 + 96 | arbiter | bridge | direct, held stable |

### 2.1. Two-flip-flop synchronizer

The first flip-flop can go metastable when the input changes near the destination clock edge. The second flip-flop samples the first one's output a period later, and only it drives logic. With $N$ stages, the destination logic sees the signal after $N$ destination clock edges, counted from the first edge that captures the transition, and the failure probability falls exponentially with the time available to resolve.

The `synchronizer` entity from Common-Components implements the chain with $N$ stages (minimum 2) and marks the registers for Quartus, which keeps them unmerged and unremoved and includes them in the MTBF report. The arbiter instantiates the `synchronizer` with two stages and one bit for each request toggle (`u_sync_a` for the data master and `u_sync_ins` for the instruction master), with the arbiter reset wired to `i_rst`. The `sdram_jtag_core` and the `flash_jtag_core` instantiate it, also with two stages, as `u_sync_done`, for the acknowledge that arrives at `i_tck`, and the `flash_loader` instantiates it as `u_sync_cmd` for the command that arrives at `i_clk`.

### 2.2. Toggle handshake

Each request is an inversion of the `req_tog` level, and the response is an inversion of `ack_tog`. An access is in progress when the two levels differ, and it is complete when they are equal again.

| Situation | `req_tog` and `ack_tog` |
| :--- | :--- |
| idle | equal |
| request in progress | different |
| response delivered | equal again |

A level, not a pulse, is what guarantees the crossing: the toggle stays at the new value until the response, however slow the destination clock is. A one-cycle core pulse could be missed by a slower memory clock.

## 3. Sequence of an access

Steps 1 to 7 follow time order.

| Step | Domain | Action |
| ---: | :--- | :--- |
| 1 | core | the bridge, idle and with the synchronized `init_done` at `'1'`, copies address, data, byte enables and extra words into output registers |
| 2 | core | on the same edge, the bridge inverts `req_tog` and enters `ST_WAIT` |
| 3 | memory | the toggle goes through the arbiter's two flip-flops, and the arbiter sees `req_tog` different from `ack_tog` |
| 4 | memory | the arbiter reads the request buses, already stable, and forwards the access to the controller |
| 5 | memory | the controller moves the data, registers the read data and the arbiter inverts `ack_tog` |
| 6 | core | `ack_tog` goes through the bridge's two flip-flops, which sees equal toggles and stores the read data |
| 7 | core | the bridge raises `o_ready` and waits for `i_mem_advance` to deliver the data and return to `ST_IDLE` |

The first stage of each synchronizer can capture the transition on the nearest edge or the next one, so the crossing costs between $N$ and $N+1$ destination clock edges, plus one edge for the state machine to act. The cycle counts per access are in [sdram_cpu_bridge](sdram_cpu_bridge.md).

## 4. Why the wide buses have no synchronizer

The bits of a bus cross through paths of different delays, and a synchronizer per bit could deliver a word with bits of two values. The protocol avoids the problem because no bus is read while it changes.

| Bus | When it changes | When it is read |
| :--- | :--- | :--- |
| request (bridge to arbiter) | on the same core edge that inverts `req_tog` | after the arbiter sees the synchronized inversion |
| read data (arbiter to bridge) | before the inversion of `ack_tog` | after the bridge sees the synchronized inversion |

Both buses stay stable until the next request, which is only born after the bridge sees the response. For the read to be always correct, the data delay must be shorter than the minimum latency of the matching toggle:

$$
t_{data} + t_{setup} < N \cdot T_{dest}
$$

with $N = 2$ in both directions. The reader is the arbiter for the request and the bridge for the response, so $T_{dest}$ is $T_{mem}$ for the request and $T_{cpu}$ for the response.

## 5. Timing constraints

With no phase relation between the clocks, the timing analyzer cannot check these paths as synchronous. The platform `.sdc` file bounds every crossing between the memory clocks and the core clocks.

| Constraint | Effect |
| :--- | :--- |
| `set_max_delay` of 10 ns in both directions | the data path must arrive before the toggle shows up at the destination |
| `set_min_delay` of -10 ns in both directions | removes the hold check on these paths |

The 10 ns value must stay smaller than $N \cdot T_{dest}$ of the slowest clock that receives a bus. If the core clock or the memory clock changes, this inequality is revalidated.

## 6. Reset and initialization

| Item | Rule |
| :--- | :--- |
| Toggle reset | both toggles return to `'0'` and the synchronizers are cleared, so the pair starts at "idle" |
| Reset domains | `i_rst_cpu` clears the bridge and `i_rst_mem` clears the arbiter and the controller; both sides are reset together, because a toggle at `'1'` with the other side not reset would be read as a request or a response |
| End of initialization | `init_done` rises once and crosses through its own synchronizer; while the bridge sees it at `'0'`, it accepts no accesses |

## 7. Access order

The handshake keeps one access in progress per bridge. The bridge accepts no new access before the pipeline advances, and the arbiter serves one request at a time among the masters, in round-robin order. The crossing therefore neither reorders nor interleaves accesses.

| Property | Status |
| :--- | :--- |
| Order between accesses of the same master | preserved |
| Line access (four words) | a single request and a single response, with no intermediate state visible to the core |
| Atomic read-modify-write | not provided; it would need a reservation or lock in the core or the controller |

## 8. Verification

The `SdramSystem` test ([sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py)) runs writes, reads and line accesses with the core clock at 14 ns, at 53 ns with an offset and at 100 ns with an offset, against the 7 ns memory clock, and the `SdramSystem100MHz` variant repeats the test with the controller and the chip model at 10 ns (`tck_ps` = 10000). This covers different phase and frequency relations in both directions of the crossing, including the 1 to 1 ratio between the 100 MHz core clock and the controller clock.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
