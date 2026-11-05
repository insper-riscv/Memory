# flash_cmd_port

Port B of the FLASH chip model: it executes the programming commands of a real chip (write enable, sector erase, page program, protect) on the two-port storage while port A ([flash_chip](flash_chip.md)) keeps serving reads.

## 1. Role of the component in the SoC

A real FLASH does not accept a store: its content changes through commands that erase a whole sector to 1 and program a page by taking bits from 1 to 0. The `flash_cmd_port` reproduces these rules so that the program update software is tested against a chip that enforces them. The command comes from the FLASH controller (Peripherals repository), the program data comes from the page buffer of the controller, and the result is written on port B of the storage, the [flash](flash.md) IP or the [flash_simulation](flash_simulation.md) model.

| Model port | Who uses it | Function |
| :--- | :--- | :--- |
| A (read) | Line requests of the caches, through [flash_chip](flash_chip.md) | Instruction fetch and data reads |
| B (programming) | The FLASH controller, through this entity | Erase, program and protect |

Reads go on while port B writes. A read of a region being programmed returns the current content of the storage, word by word, so a word read is always the old value or the new one, never a mix.

### 1.1. Commands

| Code | Command | Needs the latch | Effect |
| :--- | :--- | :--- | :--- |
| `001` | Write enable | No | Arms the write latch and clears the refusal |
| `010` | Sector erase | Yes | Sets every bit of the sector that contains the address to 1 |
| `011` | Page program | Yes | For each word of the page, writes the bitwise AND of the current content with the word of the page buffer |
| `100` | Protect | No | Marks the sector that contains the address; erase and program on it are refused |
| `101` | Unprotect | No | Unmarks the sector |
| others | Reserved | No | Ignored |

### 1.2. Rules the model enforces

1. An erase or program without the latch armed is ignored entirely: it does not occupy the chip, writes nothing and does not change the refusal.
2. With the latch armed, an address outside the window or in a protected sector is refused: nothing is written, the latch drops and `o_refused` rises.
3. An accepted command keeps `o_busy` high until the last word is written. The latch drops and the invalidation pulse comes in the same cycle in which `o_busy` falls.
4. A command that arrives while `o_busy` is high is ignored, whatever its code.
5. Programming over a bit at 0 does not take it to 1; only an erase of the sector does.
6. Reset clears the latch, the refusal and the protection.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `size_bytes` | `positive` | 1048576 | Chip size in bytes, a power of two greater than `sector_bytes` and up to 32 MB |
| `sector_bytes` | `positive` | 4096 | Size of the erase and protect sector, a power of two |
| `page_bytes` | `positive` | 256 | Size of the program page, a power of two from 8 bytes up to `sector_bytes` |
| `base_addr` | 32-bit vector | `0x20000000` | Address of the start of the chip in the SoC map, added to the offset in the invalidation region |
| `erase_latency` | `natural` | 2000 | Wait edges of an erase before the sector sweep |
| `program_latency` | `natural` | 200 | Wait edges of a program before the page sweep |

Values outside the ranges abort elaboration.

### 2.2. Ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | Module clock, the same as the storage memory |
| `i_rst` | input | 1 | Synchronous reset, active at `'1'` |
| `i_cmd_valid` | input | 1 | One-cycle pulse that delivers a command |
| `i_cmd_op` | input | 3 | Command code (section 1.1) |
| `i_cmd_addr` | input | 32 | Byte address of the command |
| `o_busy` | output | 1 | An erase or a program is in progress |
| `o_wel` | output | 1 | The write latch is armed |
| `o_refused` | output | 1 | The last erase or program with the latch armed was refused; drops at the next write enable |
| `o_buf_idx` | output | $\log_2(\texttt{page\_bytes}) - 2$ | Index of the page buffer word read by the program, registered |
| `i_buf_data` | input | 32 | Page buffer word, with a registered read |
| `o_mem_addr` | output | 32 | Byte address delivered to port B of the storage, registered |
| `o_mem_we` | output | 1 | Write enable of port B of the storage |
| `o_mem_wdata` | output | 32 | Word to write on port B of the storage |
| `i_mem_data` | input | 32 | Word read from port B of the storage, with a registered read |
| `o_inval_valid` | output | 1 | One-cycle pulse at the end of an accepted erase or program |
| `o_inval_first` | output | 32 | First byte address of the changed region, in the SoC map |
| `o_inval_last` | output | 32 | Last byte address of the changed region |

## 3. Behavior

### 3.1. Addresses and window

The chip occupies $2^{W}$ bytes with $W = \log_2(\texttt{size\_bytes})$. An address whose bits from $W$ up to 25 are not all zero is outside the window, as in [flash_chip](flash_chip.md); bits 31 to 26 are not checked. The bits below the sector size (erase and protect) or the page size (program) are ignored, so the command acts on the sector or page that contains the address.

### 3.2. State machine

| State | Action | Next state |
| :--- | :--- | :--- |
| `S_IDLE` | Accepts a command on `i_cmd_valid` | `S_WAIT` on an accepted erase or program; stays in `S_IDLE` otherwise |
| `S_WAIT` | Counts the initial wait (`erase_latency` or `program_latency`) | `S_RUN` when the counter reaches zero; registers the address of the start of the region |
| `S_RUN` | Sweeps the words of the region in three phases per word | `S_IDLE` after the write of the last word |

`o_busy` is `'1'` outside `S_IDLE`.

### 3.3. Sweep of one word

The storage memory and the page buffer have a registered read, so the address issued on one edge yields data only two edges later. Each word takes three edges.

| Phase | What happens |
| :--- | :--- |
| 0 | `o_mem_addr` and `o_buf_idx` show the word; the memory and the buffer capture the address |
| 1 | `i_mem_data` and `i_buf_data` are valid; the module registers the new word and raises `o_mem_we` |
| 2 | The memory writes; the module lowers `o_mem_we` and issues the address of the next word, or finishes |

The new word is $\texttt{0xFFFFFFFF}$ in an erase and $\texttt{i\_mem\_data} \wedge \texttt{i\_buf\_data}$ in a program. The last write happens on the same edge in which `o_busy` falls.

### 3.4. Latency

With $L_e$ the `erase_latency`, $L_p$ the `program_latency`, $S$ the sector size and $P$ the page size, the number of cycles `o_busy` stays high is:

$$
T_{erase} = L_e + 1 + 3\,\frac{S}{4} \qquad T_{program} = L_p + 1 + 3\,\frac{P}{4}
$$

### 3.5. Invalidation pulse

In the cycle in which `o_busy` falls, `o_inval_valid` is `'1'` for one cycle, with the changed region on `o_inval_first` and `o_inval_last` (the whole sector or page, added to `base_addr`). The pulse connects to the region invalidation inputs of the caches (see [icache](../cache/icache.md) and [dcache](../cache/dcache.md)). An ignored or refused command produces no pulse.

## 4. Integration

The `flash_dual_system` system (`src/cache/SoC/sim/`) connects [flash_chip](flash_chip.md), this entity and the [flash_simulation](flash_simulation.md) model as in the FPGA top, with a registered-read page buffer that plays the role of the controller buffer. Port A of the storage serves the read chip through the word address `o_mem_addr(W-1 downto 2)`, and port B serves this entity the same way.

## 5. Verification

| `tests/python/tests.json` entry | cocotb module | What it covers |
| :--- | :--- | :--- |
| `FlashCmdPort` | `tests.python.unittests.cache.flash_cmd_port` | Erase sets only the sector to 1; program does the bitwise AND and never takes a bit to 1 without an erase; a command without the latch is ignored; the latch drops with the operation; a protected sector refuses and unprotect releases it; an address outside the window is refused; `o_busy` duration according to the generics; commands ignored while the chip is busy; region and instant of the pulse; reset |
| `FlashDual` | `tests.python.unittests.cache.flash_dual` | Port A reads the content programmed through port B; reads go on during an erase of another sector; a word read during the erase is whole, old or new; region of the pulse in the system |

The formal proof is in `formal/flash_cmd_port/` (see [blocks](../formal/blocks.md)), with a 64-byte chip, 16-byte sectors and 8-byte pages, and twelve mutants of the VHDL.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
