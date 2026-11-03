# Line requests of the SDRAM controller

## 1. What a line request is

A request with `line = 1` moves the four words that start at the word address given (its two low bits are ignored), the 16 bytes of one cache line, in one opening of the row.

| Part | Word access | Line access |
| :--- | :--- | :--- |
| Commands | ACTIVE, one READ or WRITE with auto-precharge | ACTIVE, four READ or WRITE two clocks apart, auto-precharge on the last |
| Beats on the data pins | 2 | 8, with no gap |
| Handshakes between clock domains | 1 | 1 |
| Data | `wdata`, `be`, `rdata` | word 0 as before; words 1 to 3 on `wdata_x`, `be_x`, `rdata_x`, 32 bits each, word 1 in the lowest bits |

The four words of a line are in the same row and bank because a line is aligned to 16 bytes and the column is the low bits of the word address.

## 2. Timing

| Item | Rule |
| :--- | :--- |
| Spacing of the commands | 2 clocks, the length of a burst of two |
| Read data | Beat m (0 to 7) is sampled CAS latency + 2 + m clocks after the first READ |
| Next ACTIVE after a line | The longer of tRC, the last READ plus CAS latency and the burst, and the last WRITE plus the burst, tWR and tRP |
| Chip model | Accepts a second READ two clocks after the first in an open row; it fails the simulation on any broken timing |

## 3. Where it is used

The arbiter carries a line request from master A (the core's bridge) with the extra words and answers with the extra words; master B (the debug port) moves one word at a time. The bridge of the core (`sdram_cpu_bridge`) takes `line` with `rden` or `wren` and keeps the contract that `rdata` and `rdata_x` change only on `mem_advance`.

A line read takes 7 clocks of the core against 20 for four word reads in the system test (core clock 8 times slower than the SDRAM clock).
