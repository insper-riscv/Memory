# sdram_bist

## 1. Role of the component in the SoC

The built-in SDRAM self test writes known data over a range of words, reads it back and counts the words that differ. It connects straight to the request port of the SDRAM controller, with no core, bridge or arbiter in the path, so it validates the pins, the clock phase and the controller without depending on anything else in the system. The result leaves on status ports (end, failure, error count and the data of the first difference).

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `window_log2` | natural | 16 | $\log_2$ of the number of words of the window of modes 0 and 1 |
| `sweep_log2` | natural | 24 | $\log_2$ of the number of words of the sweep of mode 2 (24 covers the $2^{24}$ words of the SDRAM) |
| `random_log2` | natural | 20 | $\log_2$ of the number of words of the random mode |
| `timeout_cycles` | natural | 4096 | cycles of waiting for a controller answer before the run is declared failed |

### 2.2. Ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | module clock, the same as the controller's |
| `i_rst` | input | 1 | synchronous reset, active at `'1'` |
| `i_start` | input | 1 | a rising edge starts a run |
| `i_mode` | input | 2 | run mode (section 3.2), latched at the start |
| `i_init_done` | input | 1 | the SDRAM initialization has finished |
| `o_busy` | output | 1 | a run is in progress |
| `o_done` | output | 1 | a run has finished, stays at `'1'` until the next start |
| `o_fail` | output | 1 | a word differed or the controller did not answer |
| `o_timeout` | output | 1 | the controller did not answer in time |
| `o_phase` | output | 5 | index of the phase in progress |
| `o_err_count` | output | 32 | number of read words that differed |
| `o_first_addr` | output | 24 | word address of the first difference |
| `o_first_exp` | output | 32 | expected value at the first difference |
| `o_first_got` | output | 32 | value read at the first difference |
| `o_ops_done` | output | 32 | number of words already moved, writes and reads |
| `o_c_req_tog` | output | 1 | request toggle to the controller, each flip is a new request |
| `i_c_ack_tog` | input | 1 | acknowledge toggle, equal to `o_c_req_tog` when the request has been served |
| `o_c_we` | output | 1 | write (`'1'`) or read (`'0'`) |
| `o_c_addr` | output | 24 | word address |
| `o_c_wdata` | output | 32 | write data |
| `o_c_be` | output | 4 | byte enables of the write |
| `i_c_rdata` | input | 32 | read data |

The line ports of the controller (four-word access) do not exist in this component, which moves single words only.

## 3. Behavior

### 3.1. State machine

| State | Action | Next state |
| :--- | :--- | :--- |
| `ST_IDLE` | waits for a rising edge of `i_start` with `i_init_done` at `'1'`; on accepting, latches `i_mode`, clears the phase index, the counts and the registers of the first difference, and clears `o_done`, `o_fail` and `o_timeout` | `ST_PHASE` |
| `ST_PHASE` | loads the phase definition, clears the current word, reloads the seed and computes the limit $2^{n} - 1$; if the phase is the end of the list, raises `o_done` and lowers `o_busy` | `ST_ISSUE`, or `ST_IDLE` at the end of the list |
| `ST_ISSUE` | computes the address and registers `o_c_we`, `o_c_addr`, `o_c_be` and `o_c_wdata` (the expected data of the phase pattern) | `ST_TOG` |
| `ST_TOG` | flips `o_c_req_tog` | `ST_WAIT` |
| `ST_WAIT` | waits for `i_c_ack_tog` to equal `o_c_req_tog`; on receiving it, counts the word and, on a read, compares `i_c_rdata` with the expected value; moves to the next word or the next phase | `ST_ISSUE` or `ST_PHASE` |

A rising edge of `i_start` with `i_init_done` at `'0'` is discarded, because the edge is not remembered. `i_start` is only accepted in `ST_IDLE`.

On the self test side, each word costs 2 cycles (`ST_ISSUE` and `ST_TOG`) plus the `ST_WAIT` cycles until the acknowledge, which depend on the controller. Each phase costs 1 more cycle in `ST_PHASE`. The request outputs are registered and are stable one cycle before `o_c_req_tog` flips.

When a read word differs, `o_err_count` increments and `o_fail` rises. The registers of the first difference are only written while `o_err_count` is zero, so they keep the first occurrence of the run.

If `i_c_ack_tog` does not reach `o_c_req_tog` within $\text{timeout\_cycles} + 1$ cycles of `ST_WAIT`, `o_timeout` and `o_fail` rise, the run ends with `o_done` at `'1'` and the state returns to `ST_IDLE`. The request toggle returns to its initial value only on reset.

### 3.2. Modes and phases

Each phase is a write or a read of $2^{n}$ words, with $n$ given by the generic of the mode (window, sweep or random). The table lists the phase sequence of each mode, and the total number of words moved is the sum of the phase sizes.

| Mode | Name | Phases (kind, pattern, byte mask) | Words moved |
| ---: | :--- | :--- | :--- |
| 0 | quick | write P6 `1111`; write P7 `0101`; read P8; write P1 `1010`; read P9; write P6 `1111`; read P6 | $7 \cdot 2^{\text{window\_log2}}$ |
| 1 | patterns | for each pattern P0 to P7, one write and one read, mask `1111` | $16 \cdot 2^{\text{window\_log2}}$ |
| 2 | sweep | write P6; read P6; write P7; read P7, mask `1111` | $4 \cdot 2^{\text{sweep\_log2}}$ |
| 3 | random | write P6 and read P6 at pseudo-random addresses | $2 \cdot 2^{\text{random\_log2}}$ |

The addresses of modes 0 to 2 are the current word itself, from 0 up to the phase limit.

### 3.3. Data patterns

Let $w$ be the 24-bit word address, $h(w)$ the data derived from the address and $\overline{x}$ the bitwise complement.

$$h(w) = \big(w_{7..0} \oplus w_{15..8} \oplus w_{23..16}\big)\ \Vert\ \big(w \oplus \texttt{5AC3A5}_{16}\big)$$

The low 24 bits of $h(w)$ are a bijection of $w$, so the data of a word never repeats within the chip, and a stuck or swapped address line moves the data of one word to another, which the read reveals.

| Pattern | Data of word $w$ |
| ---: | :--- |
| P0 | `00000000` |
| P1 | `FFFFFFFF` |
| P2 | `AAAAAAAA` |
| P3 | `55555555` |
| P4 | a single bit at `1` at position $w_{4..0}$ (a walking one) |
| P5 | complement of P4 (a walking zero) |
| P6 | $h(w)$ |
| P7 | $\overline{h(w)}$ |
| P8 | bytes 1 and 3 of $h(w)$, bytes 0 and 2 of $\overline{h(w)}$ (what remains of P6 after writing P7 with mask `0101`) |
| P9 | bytes 1 and 3 at `FF`, bytes 0 and 2 of $\overline{h(w)}$ (what remains after writing P1 with mask `1010`) |

Mode 0 proves the byte masks because a masked byte keeps its old value and an enabled byte changes.

### 3.4. Random addresses

In mode 3 the address is made of the low 24 bits of a 32-bit xorshift generator, with shifts of 13 left, 17 right and 5 left, which advances once per word. The seed is `2545F491` in hexadecimal and is reloaded at the start of each phase, so the read phase walks the same addresses as the write phase. Since the data depends only on the address, an address repeated in the sequence does not cause a false error.

## 4. Integration

| Item | Description |
| :--- | :--- |
| Instantiated in | `src/tests/sdram_bist_system.vhd`, which connects the self test to the SDRAM controller and to the chip model on a single clock (the bring-up configuration) |
| Talks to | the SDRAM controller (`sdram_ctrl`) through the request and acknowledge toggle protocol, the same port the core bridge uses through the arbiter |
| Does not go through | arbiter, core bridge, debug master |

The 24-bit word address covers the $2^{24}$ 32-bit words of the SDRAM. The chip timings the controller respects are in [sdram_timings.md](sdram_timings.md), and the JTAG debug path, which uses the same chip through another port, is in [sdram_debug.md](sdram_debug.md).

## 5. Verification

The cocotb tests live in `tests/python/unittests/ram/sdram_bist.py` and run over the real controller and the chip model, which fails the simulation on any violated chip rule. A passing run therefore also proves that the controller obeys the chip.

| `tests.json` entry | What changes |
| :--- | :--- |
| `SdramBist` | `CAPTURE_EXTRA` equal to 0, no extra clock before sampling the read data |
| `SdramBistRegisteredPins` | `CAPTURE_EXTRA` equal to 1, with one extra clock before sampling the read data |

| Test | Checks |
| :--- | :--- |
| `test_quick_with_byte_masks` | mode 0 ends without failure and moves $7 \cdot 2^{8}$ words |
| `test_patterns` | mode 1 ends without failure and moves $16 \cdot 2^{8}$ words |
| `test_sweep` | mode 2 ends without failure and moves $4 \cdot 2^{10}$ words |
| `test_random_addresses` | mode 3 ends without failure and moves $2 \cdot 2^{8}$ words |
| `test_a_flipped_bit_is_found` | a bit flipped in the chip between the write and the read is reported with the exact address and bit |

The simulation system uses a window of $2^{8}$, a sweep of $2^{10}$ and a random size of $2^{8}$ words. There is no formal proof of this block, and the proofs in [formal.md](../formal/formal.md) cover the arbiter and the AXI bridges.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
