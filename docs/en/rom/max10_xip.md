# max10_xip

Direct read (XIP) adapter of the internal flash of the MAX 10 of the DE10-Lite, behind the contract of [flash_chip](flash_chip.md), for instructions only.

## 1. Role of the component in the SoC

The [max10_flash](max10_flash.md) gives the internal flash to the software as a register bank, with no direct line read. The `max10_xip` gives the SoC the handshake contract of `flash_chip`, the same as [nor_flash_ctrl](nor_flash_ctrl.md): a request for one word or for a line of four words, with `o_ready` held until `i_advance`. Each request becomes word reads on the Avalon-MM data interface of the `altera_onchip_flash` megafunction, and the caches and the `flash_arbiter` serve the internal flash as they serve the parallel NOR.

The adapter only reads. It has no write or CSR port, so it never programs, erases or changes the protection of the sectors; those operations stay in the `max10_flash`.

| Aspect | `nor_flash_ctrl` | `max10_xip` |
| :--- | :--- | :--- |
| Interface with the storage | 8-bit parallel pins | Avalon-MM data, one 32-bit word per read |
| 32-bit word | Four byte reads | One read |
| 16-byte line | Sixteen byte reads | Four word reads, in sequence |
| Write | K4 commands | None |

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `data_addr_bits` | `positive` | 17 | Width of the word address of the data interface of the megafunction |
| `window_bytes` | `positive` | 262144 | Size of the window the SoC sees, a power of two from 16 bytes up |
| `base_word` | `natural` | 16384 | Word of the data space of the megafunction that is word zero of the window |

The default is the first half of the CFM2 (words 16384 to 81919), the read-only user sector of the generated IP. The sum of `base_word` and the words of the window fits the data space of `2^data_addr_bits` words.

### 2.2. Read ports

They are those of `flash_chip`, without the storage ports.

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | Module clock, the same as the megafunction |
| `i_rst` | input | 1 | Synchronous reset, active at `'1'` |
| `i_addr` | input | 32 | Byte address of the request |
| `i_rden` | input | 1 | Read request |
| `i_line` | input | 1 | Line (`'1'`) or word (`'0'`) |
| `i_advance` | input | 1 | The request was consumed in this cycle |
| `o_ready` | output | 1 | Request done, data valid, held until `i_advance` |
| `o_busy` | output | 1 | `'1'` in each wait cycle of the megafunction |
| `o_rdata` | output | 32 | Requested word (word 0 of the line) |
| `o_rdata_x` | output | 96 | Words 1 to 3 of the line |

### 2.3. Megafunction ports

They are the data ports of the `max10_flash`, the read ones only.

| Port | Direction | Meaning |
| :--- | :--- | :--- |
| `o_data_read` | output | Read request, held until `i_data_wait` falls |
| `o_data_addr` | output | Word address |
| `i_data_wait` | input | The request was not accepted yet |
| `i_data_rvalid`, `i_data_rdata` | input | Word read and its validity |

## 3. Behavior

### 3.1. Window

The SoC sees the flash as a window of `window_bytes` bytes. Word $w$ of the window is word $base\_word + w$ of the data space. A read whose bits 25 up to the end of the window size are not all zero is outside it: the request ends in the next cycle with zero in every word, without touching the megafunction.

### 3.2. Read

The requested word is the one at the address aligned to 4 bytes, and the line starts at the address aligned to 16 bytes. The words come out in increasing address order, one Avalon read per word:

1. `o_data_read` rises with the word address and stays active until `i_data_wait` falls, which is the accept.
2. The module waits for `i_data_rvalid` and stores `i_data_rdata` in the position of the word.
3. At the last word of the request `o_ready` rises and stays high until `i_advance`; at the other words the address advances by one and the cycle restarts.

A read beyond the sectors of the megafunction returns ones, as the IP does.

### 3.3. Latency

The latency of each word is that of the megafunction, from the accept to the data valid; in the simulation model it is two edges after the accept. The request takes the time of one Avalon read per word in total, so a line costs four times a word.

### 3.4. Sharing the megafunction with the `max10_flash`

The data interface of the megafunction has one owner at a time. When the `max10_flash` (which programs and erases) uses the same megafunction, the top connects the Avalon ports to the `max10_xip` or to the `max10_flash` and gives `'1'` on `i_data_wait` to the one that was not chosen, which keeps its request stopped.

## 4. Integration

| Block | Relation |
| :--- | :--- |
| `flash_arbiter` | Serves the two read masters (instruction and data cache) on the megafunction, with the same interface as the `nor_flash_ctrl` |
| `mem_region_router` | Routes the internal flash window as it routes the NOR one |
| `max10_flash` | Programs and erases the user sectors; shares the data interface with the adapter (section 3.4) |
| `max10_flash_ip` | Shell of the megafunction generated in Platform Designer, or the `max10_flash_model` in simulation |

## 5. Verification

| Verification | Coverage |
| :--- | :--- |
| Entry `Max10Xip` of `tests/python/tests.json`, module `tests.python.unittests.rom.max10_xip`, on the `max10_xip_tb` bench and the `max10_flash_model`, with the `max10_flash` programming the content | Word and line against the programmed content from `base_word`; unaligned address aligned to the word or to the line; read outside the window with zero; a line takes four reads; the adapter never requests a write; random sequence of requests |
| Formal proof `formal/max10_xip/run.sh` | See [blocks](../formal/blocks.md): each read carries the word address of the request inside the window, one at a time and in order, the request holds until the accept, the data delivered is that of the words read and a read outside the window does not touch the megafunction, with mutants |

## 6. Reference

| Source | Content |
| :--- | :--- |
| DE10-Lite manual, section 1.3 and chapter 6 | 5,888 Kbits of user flash and the internal configuration of the MAX 10 |
| [max10_flash](max10_flash.md), sections 1 and 2.3 | Sectors of the generated IP and Avalon-MM data interface |
| [flash_chip](flash_chip.md), section 1.1 | Read handshake contract |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
