# flash_arbiter

## 1. Role of the component in the SoC

The FLASH chip serves one request at a time. The arbiter shares this chip between two read masters, master A (the memory side of the [icache](icache.md)) and master B (the memory side of a data cache). Both use the chip's contract, in which the request stays on the bus until `ready` and `ready` is a level until `advance`.

## 2. Interface

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | Module clock |
| `i_rst` | input | 1 | Reset, active at 1 |
| `i_a_addr` | input | 32 | Master A, request address |
| `i_a_rden` | input | 1 | Master A, read request |
| `i_a_line` | input | 1 | Master A, request for a line of four words |
| `i_a_advance` | input | 1 | Master A, the request was consumed in this cycle |
| `o_a_ready` | output | 1 | Master A, request completed |
| `o_a_rdata` | output | 32 | Master A, word read |
| `o_a_rdata_x` | output | 96 | Master A, words 1 to 3 of the line read |
| `i_b_addr` | input | 32 | Master B, request address |
| `i_b_rden` | input | 1 | Master B, read request |
| `i_b_line` | input | 1 | Master B, request for a line of four words |
| `i_b_advance` | input | 1 | Master B, the request was consumed in this cycle |
| `o_b_ready` | output | 1 | Master B, request completed |
| `o_b_rdata` | output | 32 | Master B, word read |
| `o_b_rdata_x` | output | 96 | Master B, words 1 to 3 of the line read |
| `o_addr` | output | 32 | Chip, request address |
| `o_rden` | output | 1 | Chip, read request |
| `o_line` | output | 1 | Chip, line request |
| `o_advance` | output | 1 | Chip, the request was consumed |
| `i_ready` | input | 1 | Chip, request completed |
| `i_rdata` | input | 32 | Chip, word read |
| `i_rdata_x` | input | 96 | Chip, words 1 to 3 of the line read |

The module has no generics.

## 3. Behavior

### 3.1. Grant

The grant is a register with three values, no owner, A or B. With the chip unowned, the decision follows the table.

| `i_a_rden` | `i_b_rden` | Last served | Next owner |
| :--- | :--- | :--- | :--- |
| 1 | 0 | Any | A |
| 0 | 1 | Any | B |
| 1 | 1 | B, or none since reset | A |
| 1 | 1 | A | B |
| 0 | 0 | Any | None |

The owner is registered and stays with the chosen master until its `advance`, when the chip answers with `i_ready` at 1 in the same cycle. In the next cycle the chip is unowned again, and the choice is made again on the edge after it. Thus a request in progress is never interrupted.

### 3.2. Forwarding

| Signal | Owner A | Owner B | No owner |
| :--- | :--- | :--- | :--- |
| `o_rden` | `i_a_rden` | `i_b_rden` | 0 |
| `o_advance` | `i_a_advance` | `i_b_advance` | 0 |
| `o_addr` and `o_line` | Those of A | Those of B | Those of B |
| `o_a_ready` | `i_ready` | 0 | 0 |
| `o_b_ready` | 0 | `i_ready` | 0 |

The data read (`i_rdata` and `i_rdata_x`) reaches both masters unconditionally, but only the owner receives the `ready` that validates it.

### 3.3. Latency and fairness

The grant costs one cycle between the first `i_*_rden` seen and the owner taking the chip, and there is one unowned cycle between two consecutive requests. Since the master just served loses the tie, no master waits for more than one request of the other.

## 4. Integration

| Instance | File | Connection |
| :--- | :--- | :--- |
| `u_arbiter` | `src/cache/SoC/sim/flash_path_system.vhd` | Master A wired to the FLASH output of the icache's router; master B wired to the FLASH output of port B's router; output wired to the `flash_chip` chip |

The routers that feed the arbiter are the [mem_region_router](mem_region_router.md). The arbiter knows nothing about writes, because the router completes any FLASH write without forwarding it.

## 5. Verification

The tests are cocotb tests in `tests/python/unittests/cache`, registered in `tests/python/tests.json`. The FLASH arbiter has no formal proofs.

| `tests.json` entry | Test module | What it covers |
| :--- | :--- | :--- |
| `FlashArbiter` | [flash_arbiter.py](../../../tests/python/unittests/cache/flash_arbiter.py) | Single requests from each master, A wins the first tie and B follows, a grant is never cut, B is not starved by back-to-back requests from A |
| `FlashPath` | [flash_path.py](../../../tests/python/unittests/cache/flash_path.py) | Both masters at once each get their own data, B reads a line while the icache is idle, instruction fetch from the FLASH end to end |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
