# JTAG protocol of the SDRAM debug

## 1. Scope

This document defines what a host sends and receives through the Virtual JTAG instance of the SDRAM debug, precisely enough to write a load and dump tool. The hardware blocks that implement it are in [sdram_jtag_core.md](sdram_jtag_core.md) and [sdram_dbg_master.md](sdram_dbg_master.md), and the overview is in [sdram_debug.md](sdram_debug.md).

Every field is sent least significant bit first, as a shift of the data register of a Virtual JTAG instance. An address is always a 32-bit word address of the chip (the byte address divided by 4), with 24 bits in a 64 MiB chip and 25 bits in a 128 MiB chip.

## 2. Instructions

The instance has a 2-bit instruction register.

| Instruction | Data register | Shift length | Use |
| ---: | :--- | :--- | :--- |
| 0, and the unlisted ones | bypass | 1 bit | none, sends nothing to the memory |
| 1 | DEBUG | 64 bits | one command per shift, and the state of the previous one on the output |
| 2 | write burst | $32 \cdot N$ bits, $N$ from 1 to 128 | writes $N$ consecutive words to the SDRAM |
| 3 | read burst | $64 + 32 \cdot N$ bits, $N$ from 1 to 128 | returns $N$ consecutive words of the SDRAM |

A complete shift is Capture-DR, the Shift-DR bits and Update-DR. The instruction is loaded before, in an Update-IR, and holds until the next one.

## 3. The DEBUG register

### 3.1. Input and output

| Direction | Bits | Field | Meaning |
| :--- | :--- | :--- | :--- |
| in | 63 to 60 | `op` | command of section 3.3; with the 128 MiB chip, bit 63 is bit 24 of the address |
| in | 59 to 56 | `be` | byte enables of a write, or the subcommand of command 7 in bits 58 to 56 |
| in | 55 to 32 | `addr` | word address, the 24 low bits |
| in | 31 to 0 | `data` | value to write, count of a fill or of a CRC, or the level of the hold |
| out | 63 to 56 | `status` | table of section 3.2 |
| out | 55 to 32 | `word` | last word accessed |
| out | 31 to 0 | `data` | data of the last read, or the CRC after a command 7 with subcommand 1 |

### 3.2. Status

| Bit | Name | Meaning |
| ---: | :--- | :--- |
| 0 | `busy` | the previous command has not finished, so `word` and `data` are not valid yet |
| 1 | `error` | the controller did not answer the previous command |
| 2 | `initialized` | the SDRAM finished the power-up sequence |
| 3 | `overrun` | a command arrived with the port busy and was dropped |
| 4 | `stream error` | a word of a burst arrived late or was lost (section 5.3) |
| 5 | `hold` | the debug master keeps the core stopped |
| 7 and 6 | none | read 0 |

`overrun` stays at 1 until the next accepted command. `stream error` stays at 1 until the next accepted command, until a seek command or until the start of the next burst (the frame of that burst still shows the old value).

### 3.3. Commands

| `op` | Name | Effect |
| ---: | :--- | :--- |
| 0 | status | sends nothing, only reads the status |
| 1 | read | reads the word at `addr` |
| 2 | write | writes `data` to the word at `addr`, with the bytes given by `be` |
| 3 | fill | writes `data` (all bytes) to $\text{count}$ words from `addr` |
| 4 | set count | $\text{count} = \text{data}[24:0]$, up to $2^{24}$ words; it is 1 after the reset |
| 5 | read next | reads the word after the last one accessed |
| 6 | write next | writes `data` to the word after the last one accessed, with the bytes given by `be` |
| 7 | control | subcommand in bits 58 to 56 of `be`, table below |

| Subcommand of `op` 7 | Name | Effect |
| ---: | :--- | :--- |
| 0 | hold | the core hold takes `data[0]`; at 1, the SoC keeps the core in reset |
| 1 | crc32 | reads $\text{count}$ words from `addr`, with $\text{count} = \text{data}[24:0]$, and returns their CRC-32 |
| 2 | seek | points the burst pointer at `addr` (with bit 24 coming from bit 63) |
| 3 to 7 | none | only answer |

A command is accepted when the shift ends (Update-DR) with `op` other than 0 and `busy` equal to 0. With `busy` equal to 1 the command is dropped and `overrun` rises. The seek does not go through the debug master and is accepted even with `busy` equal to 1.

### 3.4. Waiting for the end of a command

The status of a command is only up to date a few JTAG clocks after it is sent. The host sends shifts with `op` 0 until `busy` is 0 and uses `word` and `data` of that shift.

## 4. Hold and CRC

### 4.1. Hold

Subcommand 0 of command 7 sets and clears `o_core_hold`, the output of the debug master that the top level takes to the reset of the core. The value persists between commands and returns to 0 on the reset of the debug master. Bit 5 of the status shows the current value.

### 4.2. CRC

Subcommand 1 of command 7 computes the CRC-32 of the words, on the controller clock, with no JTAG traffic. Each word enters with its bytes from the lowest to the highest address (little-endian word), the initial value and the final inversion are all 1 and the reflected polynomial is $\texttt{0xEDB88320}$, which gives the same value as `zlib.crc32` over the bytes of the image. With a count of zero the result is 0. The result comes in the `data` field of the shift after the command ends, and `word` carries the last word read.

The cost is one chip read per word.

## 5. Bursts

A burst moves up to 128 words (4096 bits) in a single shift, with no command per word and no status poll in between. Bursts use the burst pointer of the JTAG core, a 25-bit word address that the seek points and that advances one word per word moved.

### 5.1. Write burst (instruction 2)

1. The host sends a seek with the address of the first word.
2. It loads instruction 2.
3. It shifts $32 \cdot N$ data bits, the first word first, each word least significant bit first. At every 32 bits, the board writes the word at the pointer and advances it.
4. The first 64 bits that come out are the status frame of section 3.1, with `word` and `data` of the last command. With fewer than 64 bits shifted the frame comes out truncated.

Words beyond the 128th in one shift are ignored, and bits that do not complete a word write nothing. After the shift, the host returns to instruction 1 and waits for `busy` to be 0 before sending a command, because the last word may still be being written.

### 5.2. Read burst (instruction 3)

1. The host sends a seek with the address of the first word.
2. It loads instruction 3.
3. It shifts $64 + 32 \cdot N$ bits (what goes in is ignored). The first 64 bits that come out are the status frame, and then the $N$ words come out, the first word first, each least significant bit first.

The first word is read during the status frame and each following word is requested when the previous one goes to the output. The pointer advances when the first bit of a word comes out, so only the words shifted count, and a following burst, without a new seek, continues at the word after the last one shifted. The board reads one word beyond the last one delivered, without delivering it and without moving the pointer.

### 5.3. Timing and burst error

Each word of a burst is one access to the chip at a time, requested as soon as the previous one ends, and the access has to end before the next word is requested, 32 JTAG clocks later. With a JTAG clock of $f_{tck}$ and an access of $t_{acc}$, the condition is

$$
t_{acc} < \frac{32}{f_{tck}}
$$

With the 24 MHz clock of the USB-Blaster that is 1.33 microseconds, against the debug master access of about 15 controller clocks, plus the wait for one access of each of the other arbiter masters. If the condition fails, bit 4 of the status rises and the word is lost in a write or invalid in a read.

The host checks bit 4 after every burst (the status of a shift with `op` 0). With the bit at 1, it redoes the burst from the seek of its start address, which is safe, because writing the same words again and reading again have no side effect.

## 6. Host recipes

### 6.1. Loading an image

1. Seek to the start address and the hold subcommand with `data` equal to 1 (the core stops).
2. Write bursts of up to 128 words, each followed by a wait for `busy` equal to 0 and a check of bit 4.
3. CRC with the start address and the number of words, compared with the CRC computed on the host. The image is valid only if they are equal.
4. Hold subcommand with `data` equal to 0.

### 6.2. Dumping a region

1. Seek to the start address.
2. Read bursts of up to 128 words, each checked by bit 4 of the frame.
3. Optionally, the CRC of the region on the board, to check what was read.

Dumping is safe with the core running if the data cache writes through to the SDRAM. Writing a region that the core executes requires the hold of section 4.1.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
