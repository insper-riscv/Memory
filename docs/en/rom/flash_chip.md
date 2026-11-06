# flash_chip

Model of the external FLASH as the SoC sees it: a read-only chip that serves single-word or four-word line requests with configurable latency. The storage lives outside the entity.

## 1. Role of the component in the SoC

The FLASH occupies the region that starts at `0x20000000` when the ROM is external to the core (map in [02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md)). The instruction cache and the data cache reach it through a region router and an arbiter, and the chip answers with the same handshake contract that the SDRAM bridge gives the core.

### 1.1. Handshake contract

1. The request stays stable on `i_addr`, `i_rden` and `i_line` until `o_ready` rises.
2. `o_ready` stays high as a level until `i_advance` says the request was consumed.
3. The data read changes only on the next request.
4. An address outside the window of the chip reads zero (section 3.3), as in every block of the memory contract.

### 1.2. Request types

| `i_line` | Request | Address used | Words returned |
| :--- | :--- | :--- | :--- |
| `'1'` | Line | Start of the 16-byte line that contains `i_addr` | Four, word 0 on `o_rdata` and words 1 to 3 on `o_rdata_x` |
| `'0'` | Word | `i_addr` aligned to 4 bytes | One, on `o_rdata` |

Stores never reach the chip, because the FLASH ignores writes from the core.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `first_latency` | `natural` | 24 | Edges of `i_clk` until the first word is captured. Minimum 2 |
| `next_latency` | `natural` | 4 | Edges between one word and the next of the same line. Minimum 2 |
| `size_bytes` | `positive` | 1048576 | Chip size in bytes, a power of two from 16 bytes to 32 MB. Any other value aborts elaboration |

### 2.2. Ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | Module clock, the same as the storage memory |
| `i_rst` | input | 1 | Synchronous reset, active at `'1'` |
| `i_addr` | input | 32 | Byte address of the request |
| `i_rden` | input | 1 | Read request |
| `i_line` | input | 1 | Selects line (`'1'`) or word (`'0'`) |
| `i_advance` | input | 1 | The request was consumed this cycle and the chip may accept another |
| `o_ready` | output | 1 | Request complete, data valid |
| `o_busy` | output | 1 | `'1'` in every cycle spent waiting for a word |
| `o_rdata` | output | 32 | Requested word (word 0 of the line) |
| `o_rdata_x` | output | 96 | Words 1 to 3 of the line, word 1 in the lowest bits |
| `o_mem_addr` | output | 32 | Byte address given to the storage, coming from a register |
| `i_mem_data` | input | 32 | Word read from the storage, with a registered read |

## 3. Behavior

### 3.1. State machine

| State | Stay condition | Action | Next state |
| :--- | :--- | :--- | :--- |
| `S_IDLE` | `i_rden = '0'` | None | `S_WAIT` when `i_rden = '1'`; before that it registers the base, the last word index, the out-of-window mark and the address on `o_mem_addr` |
| `S_WAIT` | The [latency_counter](../latency/latency_counter.md) has not signalled the last edge | Waits | `S_DONE` when the last word of the request is captured |
| `S_DONE` | `i_advance = '0'` | `o_ready = '1'` | `S_IDLE` when `i_advance = '1'` |

`o_busy` is `'1'` in `S_WAIT` and `o_ready` is `'1'` in `S_DONE`. Reset goes to `S_IDLE`. Each capture writes the word to `o_rdata` (word 0) or to a 32-bit slice of `o_rdata_x`; after capturing a word that is not the last, the registered address advances 4 bytes and the `latency_counter` reloads with `next_latency`, on the same edge as the capture. A word request does not change `o_rdata_x`.

### 3.2. Latency

The address is registered on one edge and the storage memory answers only on the next, so both generics are at least 2. With $L_1$ the `first_latency` and $L_n$ the `next_latency`, the number of cycles with `o_busy` high is:

$$
T_{word} = L_1 \qquad T_{line} = L_1 + 3\,L_n
$$

`o_ready` rises in the cycle after the last capture.

### 3.3. Chip window

The chip occupies $2^{W}$ bytes with $W = \log_2(\text{size\_bytes})$. A request whose address bits from $W$ up to 25 are not all zero is outside the window. Bits 31 to 26 are not part of the check. An out-of-window request goes through the same latency and captures zero in every word, regardless of the storage content.

## 4. Integration

| Block | Relation to the chip |
| :--- | :--- |
| `icache` and `dcache` (`src/cache/`) | Line masters; see [dcache_axi.md](../barramento/dcache_axi.md) for the data cache |
| `mem_region_router` | Splits the request between SDRAM and FLASH, completes stores to the FLASH with no effect and returns zero for reads past the window without waking the chip |
| `flash_arbiter` | Serializes the two masters over the single chip; a request in progress is never interrupted |
| [latency_counter](../latency/latency_counter.md) | Counts the edges of both latencies; it is the same machine as in [ram_chip](../ram/ram_chip.md) and [onchip_ram_port](../ram/onchip_ram_port.md) |
| [flash_cmd_port](flash_cmd_port.md) | Port B of the model: erases, programs and protects the same storage while this chip reads |
| Storage | Registered-read memory driven by `o_mem_addr` and `i_mem_data`. On the board it is the IP [flash_store](flash_store.md); in the modular simulation it is the model [rom_simulation](rom_simulation.md) |

The DE0-CV board top, in Insper-RISC-V, instantiates the chip with latencies 24 and 4 and a `size_bytes` of 262144, wired to the 256 KB storage IP through bits 17 to 2 of `o_mem_addr`. The modular simulation top of Insper-RISC-V instantiates it with latencies and size taken from generics. In both cases the chip clock and the storage clock are the same.

## 5. Verification

| `tests/python/tests.json` entry | cocotb module | What it covers |
| :--- | :--- | :--- |
| `FlashChip` | `tests.python.unittests.external.flash_chip` | Whole aligned line, single word, latency following the generics, `o_ready` held until `i_advance`, back-to-back requests, an out-of-window request reading zero at the 1 MB default and `o_busy` covering $L_1 + 3\,L_n$ cycles |
| `FlashPath` | `tests.python.unittests.external.flash_path` | Instruction cache, routers, arbiter and chip together, including a store to the FLASH that never reaches the chip and a read past the window that does not wake it |
| `FlashArbiter` | `tests.python.unittests.external.flash_arbiter` | The arbiter in front of the chip |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
