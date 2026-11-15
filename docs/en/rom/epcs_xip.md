# epcs_xip

Direct read (XIP) adapter of the EPCS serial flash, behind the contract of [flash_chip](flash_chip.md), for instructions only.

## 1. Role of the component in the SoC

The [epcs_ctrl](epcs_ctrl.md) gives the serial flash to the software as a register bank, with no direct line read. The `epcs_xip` gives the SoC the handshake contract of `flash_chip`, the same as [nor_flash_ctrl](nor_flash_ctrl.md): a request for one word or for a line of four words, with `o_ready` held until `i_advance`. The `flash_arbiter`, the `mem_region_router` and the caches therefore serve the serial flash as they serve the parallel NOR, and each request becomes one read frame of the flash.

The adapter only reads. It builds only the READ and FAST_READ instructions, so it never programs, erases or enables writes; those operations stay in the `epcs_ctrl`. The serial flash only works behind a cache, because a frame takes hundreds of clocks (section 3.3).

| Aspect | `nor_flash_ctrl` | `epcs_xip` |
| :--- | :--- | :--- |
| Pins | 8-bit parallel bus with `CE#`, `OE#`, `WE#` | Four SPI pins |
| Latency per line | About 35 clocks at 50 MHz | Hundreds of clocks |
| Write | K4 commands | None |
| Window | Start of the chip | Starts at `chip_offset`, above the bitstream |

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `window_bytes` | `positive` | 4194304 | Size of the window the SoC sees, a power of two from 16 bytes to 16 MB |
| `chip_offset` | `natural` | 4194304 | Byte of the chip that is byte zero of the window, a multiple of 16 |
| `clk_div` | `positive` | 2 | `i_clk` edges in each half period of the SPI clock |
| `gap_ticks` | `positive` | 8 | Half periods with `CS#` high after each frame |
| `fast_read` | `boolean` | `false` | Reads with FAST_READ (one more dummy byte) instead of READ |

The defaults of `window_bytes` and `chip_offset` are the upper half of the EPCS64, which is the user region of the `epcs_ctrl`. The sum `chip_offset + window_bytes` does not pass 16 MB, the 24-bit address space of the instruction.

### 2.2. Read ports

They are those of `flash_chip`, without the storage ports.

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | Module clock |
| `i_rst` | input | 1 | Synchronous reset, active at `'1'` |
| `i_addr` | input | 32 | Byte address of the request |
| `i_rden` | input | 1 | Read request |
| `i_line` | input | 1 | Line (`'1'`) or word (`'0'`) |
| `i_advance` | input | 1 | The request was consumed in this cycle |
| `o_ready` | output | 1 | Request done, data valid, held until `i_advance` |
| `o_busy` | output | 1 | `'1'` from the frame request to its end |
| `o_rdata` | output | 32 | Requested word (word 0 of the line) |
| `o_rdata_x` | output | 96 | Words 1 to 3 of the line |

### 2.3. SPI pins

| Port | Direction | Meaning |
| :--- | :--- | :--- |
| `o_sck` | output | SPI clock, low at rest |
| `o_cs_n` | output | Chip select, active at `'0'` |
| `o_mosi` | output | Data to the chip |
| `i_miso` | input | Data from the chip |

The pins go to the interface block of the serial flash of the device (`epcs_asmi_cyclone_iv_e` or `epcs_asmi_cyclone_v`), or to the model in simulation. The adapter owns the pins; when the `epcs_ctrl` also programs the same chip, the top picks which of the two drives the pins at each moment.

## 3. Behavior

### 3.1. Window

The SoC sees the flash as a window of `window_bytes` bytes. Byte $a$ of the window is byte $chip\_offset + a$ of the chip, so with `chip_offset` equal to the start of the user region the bitstream, which lies below, is never reached by a read. A read whose bits 25 up to the end of the window size are not all zero is outside it: the request ends in the next cycle with zero in every word, without selecting the chip.

### 3.2. Frame

Each request that falls in the window becomes a frame, from `CS#` low to `CS#` high, through the SPI master of the `epcs_ctrl`.

| Request | Frame address | Data bytes | Instruction |
| :--- | :--- | ---: | :--- |
| Word | Address aligned to 4 bytes | 4 | `0x03` (READ) or `0x0B` (FAST_READ) |
| Line | Address aligned to 16 bytes | 16 | `0x03` (READ) or `0x0B` (FAST_READ) |

The lowest-address byte sits in the low bits of word 0, and the next word of the line sits in the low bits of `o_rdata_x`, as in the `nor_flash_ctrl`. `o_ready` rises after the `CS#` high interval of the SPI master, and the next request only starts after `i_advance`.

### 3.3. Latency

Let $d$ be `clk_div`, $g$ be `gap_ticks`, $h$ the header bytes (4 in READ and 5 in FAST_READ) and $n$ the data bytes (4 for a word and 16 for a line). Each byte takes 8 bits of $2d$ clocks plus one load clock, and the request from `i_rden` to `o_ready` takes

$$N = (h + n)\,(16\,d + 1) + (g + 1)\,d + 3 \text{ clocks.}$$

| `clk_div` | `gap_ticks` | Instruction | Word | Line |
| ---: | ---: | :--- | ---: | ---: |
| 2 | 8 | READ | 285 | 681 |
| 1 | 2 | FAST_READ | 159 | 363 |

A NOR line takes about 35 clocks at 50 MHz, so an instruction miss in the serial flash costs an order of magnitude more.

### 3.4. Choosing `clk_div`

The SPI clock is $f_{clk} / (2d)$ and does not pass the limit of the chip for the chosen instruction:

$$d \ge \left\lceil \frac{f_{clk}}{2\,f_{spi}} \right\rceil$$

The chip catalog carries `read_spi_mhz` (READ) and, when the chip has it, `fast_read_spi_mhz` (FAST_READ) in the `timing` field of each file (see the [catalog](../chips/catalogo.md)). With the EPCS64 at 50 MHz, $d = 1$ gives 25 MHz; at 100 MHz, $d = 2$ gives 25 MHz.

## 4. Integration

| Block | Relation |
| :--- | :--- |
| `flash_arbiter` | Serves the two read masters (instruction and data cache) on the single chip, with the same interface as the `nor_flash_ctrl` |
| `mem_region_router` | Routes the serial flash window as it routes the NOR one |
| `epcs_ctrl` | Programs and erases the user region; shares the chip and the pins with the adapter |
| `epcs_spi` | SPI master the adapter uses to build each frame |
| ASMI block of the device | Takes the SPI pins to the configuration pins of the flash |

## 5. Verification

| Verification | Coverage |
| :--- | :--- |
| Entries `EpcsXip` (READ, `clk_div` 2) and `EpcsXipFast` (FAST_READ, `clk_div` 1) of `tests/python/tests.json`, module `tests.python.unittests.rom.epcs_xip`, on the `epcs_xip_tb` bench and the `epcs_model` | Word and line against the pattern of the model from `chip_offset`; unaligned address aligned to the word or to the line; read outside the window with zero and `CS#` high; exact latency of the formula of section 3.3; random sequence of requests. Every test checks that the model raised no violation |
| Formal proof `formal/epcs_xip/run.sh` | See [blocks](../formal/blocks.md): on the SPI pins only the read instruction leaves, the address is that of the request inside the window and aligned, the frame has the size of the request, the data delivered is what was read from MISO and a read outside the window does not select the chip, with mutants |
| Quartus 25.1 synthesis | Adapter with the SPI master, fitted in EP4CE22F17C6 (356 logic elements) and 5CEBA4F23C7 (120 ALMs), 243 registers and no memory bits in both |

## 6. Reference

| Source | Content |
| :--- | :--- |
| DE0-CV (section 3.1) and DE2-115 (section 4.1) manuals | EPCS64 configuration device |
| [epcs_ctrl](epcs_ctrl.md), section 7 | Instructions and frame of the SPI master |
| [flash_chip](flash_chip.md), section 1.1 | Read handshake contract |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
