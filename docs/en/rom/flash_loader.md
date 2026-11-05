# flash_loader

Loader of the internal FLASH: a host writes the image of each test into the single copy of the [flash](flash.md) over JTAG, only while the core is halted.

## 1. Role of the component in the SoC

The internal FLASH has a single, dual-port copy. Port B belongs to the MEM stage, which reads the FLASH as data, until the host sends the halt command. The `o_halt` output of the loader is wired to the core reset in the top, so halting the loader halts the core. With the core halted, port B belongs to the loader, which writes and reads words on request of the host. The core only reads the FLASH, because the write exists only on port B.

| Block | Clock | Role |
| :--- | :--- | :--- |
| [flash_jtag_core](flash_jtag_core.md) | JTAG clock | Instruction and data registers and the handing over of a command |
| `flash_loader` | Clock of the FLASH port B | Runs the command, switches port B and keeps the halt state |
| `flash_jtag_shell` (`src/ROM/Cyclone-V/`) | | Instance of Intel's `sld_virtual_jtag`, FPGA only |

### 1.1. Guarantee that the core does not read during the write

1. The write enable of port B is the pulse of the loader combined with the halt state, so with the core running it is `'0'` by construction, whatever command arrives.
2. A write or a read requested with the core running is refused, does not change the memory and raises the refusal bit of the status until the next halt.
3. With the core halted the port B selector picks the loader, and the address of the MEM stage is ignored.

## 2. Interface

### 2.1. Generic

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `addr_width` | `positive` | 13 | Width in bits of the FLASH word index |

### 2.2. Ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | clock of the FLASH port B |
| `i_rst` | input | 1 | reset, active at `'1'`; must not depend on `o_halt` |
| `i_cmd_tog` | input | 1 | toggle that requests a command |
| `o_done_tog` | output | 1 | toggle that confirms the command |
| `i_op` | input | 4 | command code |
| `i_addr` | input | 24 | word index of the command |
| `i_data` | input | 32 | write data |
| `o_rsp_addr` | output | 24 | index of the last read or count of writes |
| `o_rsp_data` | output | 32 | data of the last read or checksum |
| `o_rsp_status` | output | 8 | bit 0 core halted, bit 1 request refused |
| `o_halt` | output | 1 | core halted, to wire to the core reset |
| `i_mem_address` | input | `addr_width` | word index requested by the MEM stage |
| `i_mem_rden` | input | 1 | read enable of the MEM stage |
| `o_address_b` | output | `addr_width` | word index of the FLASH port B |
| `o_rden_b` | output | 1 | read enable of port B |
| `o_wren_b` | output | 1 | write enable of port B |
| `o_data_b` | output | 32 | write data of port B |
| `i_q_b` | input | 32 | word read by port B |

## 3. Host protocol

The Virtual JTAG instance has a 2-bit instruction register.

| Instruction | Register | Use |
| ---: | :--- | :--- |
| 1 | CMD, 64 bits | one command per shift |
| 2 | STREAM, free length | a start bit and, after it, one word per 32 bits shifted, written at the cursor |
| other | bypass, 1 bit | sends nothing |

### 3.1. CMD register

| Direction | Bits | Field | Meaning |
| :--- | :--- | :--- | :--- |
| in | 63 to 60 | op | command |
| in | 55 to 32 | addr | word index |
| in | 31 to 0 | data | write data |
| out | 63 to 56 | status | table below |
| out | 55 to 32 | addr | index of the last read or count of writes |
| out | 31 to 0 | data | data of the last read or checksum |

| Status bit | Meaning |
| ---: | :--- |
| 0 | busy: the previous command has not finished, and `addr` and `data` are not valid yet |
| 1 | halted: the core is halted and port B belongs to the loader |
| 2 | refused: a request arrived with the core running (cleared by the next halt) |
| 3 | overrun: a word or a command arrived with the loader busy and was dropped |

The command leaves when the shift ends. The status of a command is only up to date a few JTAG clocks after it is sent, so the first shift after a command may still show busy and the next one will not.

### 3.2. Commands

| op | Name | Effect |
| ---: | :--- | :--- |
| 0 | status | Sends nothing, only reads the status |
| 1 | halt | Halts the core, clears the checksum and the count |
| 2 | run | Releases the core, which restarts from the BOOT_ROM |
| 3 | write | Writes `data` to word `addr`, and the cursor becomes `addr + 1` |
| 4 | read | Reads word `addr`, and the cursor becomes `addr + 1` |
| 5 | summary | Returns the checksum in `data` and the number of words written in `addr` |
| 6 | cursor | Sets the STREAM cursor to `addr` |

### 3.3. Checksum

On every write the loader accumulates the data and the word index.

$$\text{sum} = \sum_{i} \left( \text{data}_i + \text{address}_i \right) \bmod 2^{32}$$

The host computes the same sum over the image it sent and compares it with that of command 5 and with the count. A word that is lost, repeated or misplaced changes the sum.

### 3.4. STREAM register

A scan of $32N + 1$ bits writes $N$ consecutive words from the cursor, which advances on every word. The first bit is the start bit, with value 1, and the words follow it, the first one in the least significant bits. The host sends a whole image in a single scan, without one scan per word. Bits before the start bit and bits that do not complete a word are discarded, so the framing does not depend on the clocks the Virtual JTAG hub puts between the state signals and the data. A word that arrives with the loader busy is dropped and raises the overrun bit, which only happens if the loader clock is too slow for the JTAG clock.

## 4. Step by step of a load

1. The host sends command 1, and the core halts.
2. It sends command 6 with the index of the first word and a STREAM scan with the image.
3. It sends command 5 and compares the sum and the count with those of the image.
4. It sends command 2, and the core restarts from the BOOT_ROM and runs the new test.

## 5. Behavior

### 5.1. Synchronization

The command crosses from `i_tck` to `i_clk` through the toggle of `i_cmd_tog`, synchronized by three register stages. `i_op`, `i_addr` and `i_data` stay stable from the toggle until the response, which is a toggle of `o_done_tog`. `o_rsp_*` stay stable from before that toggle until the next command is accepted.

### 5.2. Port timing

| Command | `i_clk` cycles between acceptance and response |
| :--- | :--- |
| write | 1 (the write happens in the cycle after acceptance) |
| read | 3 (address applied, capture in port B, word on the output) |
| the others | 1 |

## 6. Verification

The `FlashLoader` entry of `tests/python/tests.json` runs `tests/python/unittests/rom/flash_loader.py` on the `flash_system` simulation top, which wires the [flash_simulation](flash_simulation.md) model, the loader and the [flash_jtag_core](flash_jtag_core.md) as in the FPGA top. The tests cover the read of the same copy by both ports, the write and read back with the core halted, the refusal of a write with the core running, the STREAM with a cursor, the checksum, the overrun and the ownership of port B.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
