# latency_counter

Latency counting machine of the emulated memory models. A leaf block counts the edges between the start of an access and the instant the model completes it, and it is the same in simulation and on the board.

## 1. Role of the component in the SoC

The emulated FLASH and RAM backend imitates the timing of a device by copying the same $n_{cycles}$ of the chip catalog into the `latency` generic. The counting of that time exists once, here, and three blocks reuse it.

| Block | Counts |
| :--- | :--- |
| [flash_chip](../rom/flash_chip.md) | One, loaded with `first_latency` on a new request and with `next_latency` between the words of a line |
| [ram_chip](../ram/ram_chip.md) | One per port (data and instruction), loaded with `latency` |
| [onchip_ram_port](../ram/onchip_ram_port.md) | One, loaded with `latency` when the generic is greater than zero |

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `max_count` | `positive` | 255 | Largest value of `i_count`, in edges; it sets the counter width |

### 2.2. Ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | Module clock |
| `i_rst` | input | 1 | Synchronous reset, active at `'1'`, which clears the count |
| `i_load` | input | 1 | One-cycle pulse that starts a count |
| `i_count` | input | `natural` from 0 to `max_count` | Edges of the count, read together with `i_load` |
| `o_last` | output | 1 | `'1'` on the last edge of the count |
| `o_wait` | output | 1 | `'1'` while more than one edge remains |

## 3. Behavior

Let $E_0$ be the edge on which `i_load` is `'1'` and $N$ the value of `i_count`, with $N = 0$ counting as 1. The count follows the table.

| Signal | Is `'1'` | How the owner reads it |
| :--- | :--- | :--- |
| `o_last` | Only on edge $E_N$ | The model acts on that edge: captures the data, completes the access or asks for the next count |
| `o_wait` | From $E_1$ to $E_{N-1}$ | The access cannot end yet |

A new load on the edge where `o_last` is `'1'` wins over the end and restarts the count, which is how the `flash_chip` chains the four words of a line. A load in the middle of a count replaces it. With no new load the count ends on $E_N$ and both signals return to `'0'`. A reset on any edge clears the count.

The counter holds the edges that remain, counting the current one, and decrements on every edge down to 1, so `o_last` is the comparison with 1 and `o_wait` the comparison with a value greater than 1.

## 4. Verification

| Check | Coverage |
| :--- | :--- |
| Entry `LatencyCounter` of `tests/python/tests.json`, module `tests.python.unittests.latency.latency_counter` | The last edge for every $N$ from 0 to 39, 100 and 255; silence without a load; a load on the last edge; a load in the middle; a reset in the middle |
| Formal proof `formal/latency_counter/run.sh` | An oracle written in the properties says on which edge each output rises, and the induction proof (unbounded, with `max_count` equal to 6) shows that the counter follows it under any sequence of loads and resets; cover of the situations and seven mutants of the VHDL, all caught |

The entries that exercise the block inside the models are those of the `flash_chip`, the `ram_chip` and the `onchip_ram_port`.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
