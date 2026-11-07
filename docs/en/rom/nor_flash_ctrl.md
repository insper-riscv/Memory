# nor_flash_ctrl

Controller of an 8-bit parallel NOR FLASH with asynchronous and page reads, behind the contract of [flash_chip](flash_chip.md) and with the K4 commands of [flash_cmd_port](flash_cmd_port.md).

## 1. Role of the component in the SoC

The controller is the `dispositivo/nor` backend of the FLASH region. It serves the SoC with the handshake contract of `flash_chip` (a request for one word or for a line of four words) and drives the pins of an 8-bit NOR chip, such as the S29GL064N of the DE2-115: 23 address bits, `CE#`, `OE#`, `WE#`, `RESET#`, `RY` and `WP#`. Reading a 32-bit word is four byte reads in the same chip page, and reading a 16-byte line is sixteen.

Besides reading, the controller runs the K4 command face of `flash_cmd_port` on the real chip: erase a sector, program a page and protect. The program data comes from the page buffer of the FLASH controller in Peripherals, and the invalidation pulse at the end of each operation connects to the per-region invalidation inputs of the caches.

| Aspect | `flash_chip` with storage | `nor_flash_ctrl` |
| :--- | :--- | :--- |
| Storage | Registered-read memory outside the entity | Chip on the pins |
| Latency | `first_latency` and `next_latency` in edges | Cycles derived from the chip times and the clock |
| Write | Port B of the storage, through `flash_cmd_port` | Write cycles of the chip itself, by this entity |

## 2. Interface

### 2.1. Generics

The times are in ns, and the defaults come from [chip_timing_pkg](chip_timing_pkg.md), with the `inferido` mark of the DE2-115 sheet.

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `clk_period_ns` | `positive` | 20 | Period of the clock `i_clk` |
| `margin_ns` | `natural` | 0 | Margin added to each time for pin and board delay |
| `size_bytes` | `positive` | 8388608 | Chip size, power of two from 8 KB to 8 MB |
| `sector_bytes` | `positive` | 65536 | Erase and protect sector, power of two smaller than `size_bytes` |
| `page_bytes` | `positive` | 256 | Program page, power of two from 8 bytes up to `sector_bytes` |
| `base_addr` | 32-bit vector | `0x20000000` | Start of the chip in the SoC map, added to the offset in the invalidation region |
| `t_acc_ns` | `natural` | 90 | Random access |
| `t_pacc_ns` | `natural` | 25 | Access inside the page |
| `t_wc_ns` | `natural` | 90 | Write cycle |
| `t_wp_ns` | `natural` | 35 | `WE#` pulse |
| `t_wph_ns` | `natural` | 30 | `WE#` high |
| `t_ds_ns` | `natural` | 45 | Data stable before `WE#` rises |
| `t_ah_ns` | `natural` | 45 | Address stable after `WE#` falls |
| `t_busy_ns` | `natural` | 90 | `WE#` rise to `RY` fall |
| `t_rp_ns` | `natural` | 500 | `RESET#` pulse |
| `t_rh_ns` | `natural` | 50 | `RESET#` rise to first access |

Values outside the ranges abort the elaboration.

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
| `o_busy` | output | 1 | `'1'` in each cycle of waiting for the chip |
| `o_rdata` | output | 32 | Requested word (word 0 of the line) |
| `o_rdata_x` | output | 96 | Words 1 to 3 of the line |

### 2.3. K4 command ports

They are those of `flash_cmd_port`, without the storage ports. The busy flag is called `o_cmd_busy` so it does not collide with the read `o_busy`.

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_cmd_valid` | input | 1 | One-cycle pulse that delivers a command |
| `i_cmd_op` | input | 3 | Command code |
| `i_cmd_addr` | input | 32 | Byte address of the command |
| `o_cmd_busy` | output | 1 | Read, operation or reset in progress |
| `o_wel` | output | 1 | The write latch is armed |
| `o_refused` | output | 1 | The last erase or program with the latch armed was refused |
| `o_buf_idx` | output | $\log_2(\texttt{page\_bytes}) - 2$ | Page buffer word index, registered |
| `i_buf_data` | input | 32 | Page buffer word, registered read |
| `o_inval_valid` | output | 1 | One-cycle pulse at the end of an accepted erase or program |
| `o_inval_first` | output | 32 | First byte address of the changed region, in the SoC map |
| `o_inval_last` | output | 32 | Last byte address of the changed region |

### 2.4. Chip ports

| Port | Direction | Width | DE2-115 pin |
| :--- | :--- | ---: | :--- |
| `o_fl_addr` | output | 23 | `FL_ADDR[22:0]` |
| `o_fl_dq` | output | 8 | `FL_DQ[7:0]`, data to write |
| `o_fl_dq_oe` | output | 1 | The controller drives `FL_DQ`; the top does the tristate |
| `i_fl_dq` | input | 8 | `FL_DQ[7:0]`, data read |
| `o_fl_ce_n` | output | 1 | `FL_CE_N` |
| `o_fl_oe_n` | output | 1 | `FL_OE_N` |
| `o_fl_we_n` | output | 1 | `FL_WE_N` |
| `o_fl_rst_n` | output | 1 | `FL_RST_N` |
| `o_fl_wp_n` | output | 1 | `FL_WP_N`, kept at `'1'` |
| `i_fl_ry` | input | 1 | `FL_RY`, asynchronous to the clock |

## 3. Behavior

### 3.1. Cycles of each phase

With $T$ the period, $m$ the margin and $\lceil x \rceil$ the ceiling with a minimum of one (`cycles_of`), the phases are

$$ n_{first} = \left\lceil \frac{t_{acc} + m}{T} \right\rceil \qquad n_{next} = \left\lceil \frac{t_{pacc} + m}{T} \right\rceil \qquad n_{wl} = \left\lceil \frac{\max(t_{wp}, t_{ah}, t_{ds}) + m}{T} \right\rceil $$

$$ n_{wh} = \max\left( \left\lceil \frac{t_{wph} + m}{T} \right\rceil,\ \left\lceil \frac{t_{wc} + m}{T} \right\rceil - n_{wl} - 1 \right) \qquad n_{busy} = \left\lceil \frac{t_{busy} + m}{T} \right\rceil + 3 $$

The defaults at 50 MHz give $n_{first} = 5$, $n_{next} = 2$, $n_{wl} = 3$, $n_{wh} = 2$ and $n_{busy} = 8$.

### 3.2. Read

A word or line request starts when the controller is free and no command arrives in the same cycle. The address aligned to 4 bytes (word) or 16 bytes (line) leaves a register together with `CE#` and `OE#` low. The first byte is captured $n_{first}$ cycles later, and each following byte, with the address incremented by one, $n_{next}$ cycles after the previous one, so `o_busy` stays at `'1'` for

$$ T_{word} = n_{first} + 3\,n_{next} \qquad T_{line} = n_{first} + 15\,n_{next} $$

cycles. At 50 MHz that is 11 and 35 cycles. The bytes are in increasing address order, the lowest-address byte in the lowest bits. A request whose address bits 25 up to the end of the chip size are not all zero is out of the window: it returns zero in all words without touching the chip.

### 3.3. Chip write cycle

Each write cycle has three phases: the setup, with address, data and `CE#` already on the pins and `OE#` high, for one cycle; `WE#` low for $n_{wl}$ cycles; `WE#` high for $n_{wh}$ cycles. The $n_{wl}$ cycles cover the minimum pulse, the address hold and, with the setup cycle, the data stable before the rise. The whole cycle, from one `WE#` fall to the next, lasts $n_{wl} + n_{wh} + 1$ cycles and covers $t_{wc}$. The controller drives `FL_DQ` only in the three phases and releases the bus before any read.

### 3.4. K4 commands

The codes and the rules are those of `flash_cmd_port`, and the execution on the chip uses the byte-mode command sequence, with the unlock addresses `0xAAA` and `0x555`.

| Code | Command | Write cycles on the chip (address, data) |
| :--- | :--- | :--- |
| `001` | Write enable | None; arms the latch and clears the refusal |
| `010` | Erase sector | `(AAA,AA)` `(555,55)` `(AAA,80)` `(AAA,AA)` `(555,55)` `(SA,30)`, with SA the sector start |
| `011` | Program page | For each byte of the page other than `0xFF`, in address order: `(AAA,AA)` `(555,55)` `(AAA,A0)` `(PA,PD)` |
| `100` | Protect | None; marks the sector in the controller |
| `101` | Unprotect | None; unmarks the sector |

An erase or program without the latch armed is ignored entirely. With it armed, an address outside the window or in a protected sector is refused: nothing is written, the latch drops and `o_refused` rises. A command is accepted only with `o_cmd_busy` low, and a command that arrives with a read request has priority, while the request waits. Protection belongs to the controller and holds for the whole chip; the `WP#` pin stays at `'1'`.

### 3.5. Page program

The controller reads the buffer word of index $k$ (`o_buf_idx` and `i_buf_data`, registered read) and programs its four bytes. A `0xFF` byte does not change the chip, because the chip only takes bits from 1 to 0, and is skipped with no write cycle. The result of a page over an already programmed sector is, byte by byte, the bitwise AND of the content with the buffer, as in `flash_cmd_port`.

After the last write cycle of a sequence the controller waits $n_{busy}$ cycles, which cover $t_{busy}$ and the two-stage synchronization of the `RY` pin, and then waits for `RY` to rise. Only then does it go to the next byte or to the end of the operation.

### 3.6. End of the operation

At the end of an accepted erase or program, in the cycle in which `o_cmd_busy` falls, the latch drops and `o_inval_valid` is `'1'` for one cycle, with the changed region in `o_inval_first` and `o_inval_last` (the whole sector or page, plus `base_addr`).

### 3.7. Chip reset

`i_rst` lowers `RESET#` and the wait of $\lceil (t_{rp} + m)/T \rceil$ cycles sets the pulse. The controller accepts requests only $\lceil (t_{rh} + m)/T \rceil$ cycles after the rise. The reset also clears the latch, the refusal and the protection.

### 3.8. State machine

| State | Action | Next state |
| :--- | :--- | :--- |
| `S_RST_ARM`, `S_RST_LOW`, `S_RST_HIGH` | Chip reset: arm, `RESET#` low, wait after the rise | `S_IDLE` |
| `S_IDLE` | Accepts a command or a read request | `S_RD`, `S_RD_DONE` (out of window), `S_WSETUP` (erase) or `S_FETCH` (program) |
| `S_RD`, `S_RD_DONE` | Captures the bytes; waits for `i_advance` | `S_RD_DONE`, `S_IDLE` |
| `S_FETCH`, `S_PBYTE`, `S_NEXT` | Fetches the buffer word, chooses the byte, advances | `S_WSETUP` or `S_FIN` |
| `S_WSETUP`, `S_WLOW`, `S_WHIGH` | The three phases of the write cycle | Next cycle of the sequence or `S_BUSY` |
| `S_BUSY`, `S_POLL` | Wait for $t_{busy}$ and for `RY` | `S_NEXT` or `S_FIN` |
| `S_FIN` | Invalidation pulse, latch drops | `S_IDLE` |

All waits are counted by the [latency_counter](../latency/latency_counter.md).

## 4. Integration

| Block | Relation |
| :--- | :--- |
| Board top | Does the `FL_DQ` tristate with `o_fl_dq_oe` and connects the pins; the controller names no pin or family |
| `flash_arbiter` and `mem_region_router` | Serve the two read masters over the single chip, as over `flash_chip` |
| [nor_flash_model](nor_flash_model.md) | Chip model on the pins, which the testbench connects to the controller |
| FLASH controller of Peripherals | Delivers the K4 commands and the page buffer |
| `synchronizer` of Common-Components | Synchronizes `i_fl_ry`, which changes with no phase relation to the clock |

## 5. Verification

| Verification | Coverage |
| :--- | :--- |
| Entries `NorFlashCtrl`, `NorFlashCtrl100` and `NorFlashCtrlMargin` of `tests/python/tests.json`, module `tests.python.unittests.rom.nor_flash_ctrl`, on the `nor_flash_ctrl_tb` bench | Cycles of a word and of a line per the formulas; random word and line reads against a reference memory; out-of-window read; sector erase without touching the neighbors; page program with the bitwise AND, skipped `0xFF` byte and reprogram; latch, refusal, protection and reset; read requested during an operation; random mix of reads, erases and programs |
| Same entries | The chip times are checked by [nor_flash_model](nor_flash_model.md), which fails the simulation if the controller violates one; the three clocks (50 MHz, 100 MHz with 2 ns margin and 40 MHz with 7 ns) pass |
| Formal proof `formal/nor_flash_ctrl/run.sh` | See [blocks](../formal/blocks.md): pins, phases, command sequence, data, end of operation, read and commands, in two cycle configurations, with mutants |

## 6. Reference

| Source | Content |
| :--- | :--- |
| `Plans/Multi-FPGA/05-FRENTES-E-TRILHAS.md`, task M.5.4 | 8-bit NOR FLASH controller with page read, K4 commands and sector alignment |
| `Plans/Multi-FPGA/01-ARQUITETURA.md`, sections 3 and 4 | K2 and K4 contract, `dispositivo/nor` backend and latency $\lceil t / T \rceil$ |
| `Plans/Multi-FPGA/placas/de2-115.md`, section 5.3 | Pins, 8-bit width, 23 address bits and the `inferido` times of the S29GL064N90 |
| Spansion S29GL064N datasheet | Byte-mode command sequences, 8-word page, `RY` and `RESET#` (values from memory, to check) |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
