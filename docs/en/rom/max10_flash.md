# max10_flash

Bus controller of the MAX 10 internal user flash of the DE10-Lite, over the Quartus `altera_onchip_flash` megafunction.

## 1. Role of the component in the SoC

The DE10-Lite MAX 10 10M50DA has 5,888 Kbits of internal flash (DE10-Lite manual, section 1.3), which holds the bitstream and, in what is left, user data. The `altera_onchip_flash` megafunction exposes that flash through two Avalon-MM interfaces, a data one (read and write of a 32-bit word) and a control and status register one (CSR). `max10_flash` gives the software a bank of eight registers over both, so that reading a word, programming a word and erasing a sector are one-register commands, with a busy state and an end-of-operation interrupt.

| Aspect | Value |
| :--- | :--- |
| Device | 10M50DAF484C7G |
| Generated IP configuration | Single uncompressed image and parallel data interface |
| Data space | 17 bits of address of 32-bit words |
| Sector 1 (UFM1) | Words 0 to 8191, read and write |
| Sector 2 (UFM0) | Words 8192 to 16383, read and write |
| Sector 3 (CFM2, used as user flash) | Words 16384 to 114687, read only in this generation |
| Sectors 4 and 5 (CFM1 and CFM0) | Hidden in this mode; the IP classifies them as configuration flash |

The controller only erases the sectors that the `erase_allowed` generic enables, which defaults to sectors 1 and 2. Sector 3 is read only in the generated IP, and sectors 4 and 5, which the IP classifies as configuration flash, do not appear in the data space.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `data_addr_bits` | `positive` | 17 | Width of the word address of the megafunction data interface |
| `erase_allowed` | 5-bit vector | `00011` | Bit $k-1$ enables the erase of sector $k$ |

### 2.2. Bus ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | Module clock, the same as the megafunction |
| `i_rst` | input | 1 | Synchronous reset, active at `'1'` |
| `i_address` | input | 3 | Register index |
| `i_write` | input | 1 | Register write |
| `i_read` | input | 1 | Register read |
| `i_data_in` | input | 32 | Write data |
| `o_data_out` | output | 32 | Read data, combinational on `i_address` |
| `o_irq` | output | 1 | Done with the interrupt enabled |

### 2.3. Megafunction ports

| Port | Direction | Meaning |
| :--- | :--- | :--- |
| `o_data_read`, `o_data_write` | output | Data request, held until `i_data_wait` falls |
| `o_data_addr`, `o_data_wdata` | output | Word address and word to write |
| `i_data_wait` | input | The request has not been accepted yet |
| `i_data_rvalid`, `i_data_rdata` | input | Word read and its validity |
| `o_csr_read`, `o_csr_write` | output | One-cycle CSR request |
| `o_csr_addr` | output | `'0'` status register, `'1'` control register |
| `o_csr_wdata` | output | Control word to write |
| `i_csr_rdata` | input | CSR word read, valid one cycle after the read request |

## 3. Registers

| Index | Name | Access | Content |
| ---: | :--- | :--- | :--- |
| 0 | `STATUS` | read and write 1 to clear | Bit 0 busy, bit 1 done, bit 2 error, bit 3 write enabled. Writing `'1'` to bit 1 or 2 clears the bit |
| 1 | `CONTROL` | read and write | Bit 0 enables the interrupt |
| 2 | `ADDRESS` | read and write | Word address in the data space |
| 3 | `DATA` | read and write | Word to program, and after a read, the word read |
| 4 | `SECTOR` | read and write | Number of the sector to erase, 1 to 5 |
| 5 | `COMMAND` | write | Command code (section 4) |
| 6 | `IP_STATUS` | read | Raw status register of the megafunction (10 bits) |
| 7 | reserved | read | Reads zero |

## 4. Commands

| Code | Command | Effect |
| ---: | :--- | :--- |
| 1 | Read | Reads the word at `ADDRESS` into `DATA` and checks the read-passed bit of the megafunction |
| 2 | Program | Writes `DATA` at `ADDRESS` and checks the write-passed bit |
| 3 | Erase | Erases the sector in `SECTOR`, waits for the end through the control and status registers, checks the erase-passed bit and protects everything again |
| 4 | Enable | Releases the write of the five sectors in the megafunction control register and raises the write-enabled bit |
| 5 | Disable | Protects the five sectors and lowers the write-enabled bit |

Any other code is ignored. The megafunction starts with every sector protected.

### 4.1. Refusal rules

A refused command raises the error bit and does not touch the megafunction.

| Situation | Result |
| :--- | :--- |
| Command written while the controller is busy | Error; the command in progress ends normally |
| Program or erase with the write disabled | Error |
| Erase of a sector outside 1 to 5 or outside `erase_allowed` | Error |
| The megafunction reports a read, write or erase failure | Done with error |

The erase ends by giving the protection back, so the write-enabled bit falls and the next program or erase needs a new Enable command.

## 5. Sequence of a command

1. The software writes `ADDRESS`, `DATA` and `SECTOR` as the command requires.
2. The software writes the code to `COMMAND`.
3. The busy bit rises and only falls at the end of the operation, when the done bit rises (and the error bit, if there was a failure).
4. The software reads `DATA` (for Read), clears the done and error bits and goes on.

The megafunction holds the data request until the wait falls, and the state of a program or erase operation is polled by repeated CSR reads. The duration of a program and of an erase is the megafunction's, which carries the chip time limits (for the 10M50, 305 µs for a program and 350 ms for an erase, values from the generated code and not from the board manual).

## 6. Generated IP and shell

The controller does not instantiate the megafunction. The thin shell `max10_flash_ip` (`src/ROM/MAX-10/max10_flash_ip.vhd`) declares by `component` the `max10_flash_core` IP, generated by Platform Designer from `src/ROM/MAX-10/max10_flash_core.tcl`, and exposes the ports with the polarity of the controller. To generate the IP:

```bash
qsys-script --script=src/ROM/MAX-10/max10_flash_core.tcl
qsys-generate max10_flash_core.qsys --synthesis=VHDL --part=10M50DAF484C7G
```

The Quartus project includes the generated `max10_flash_core.qip`. The shell is in `tree.vhdl_style.exclude` of `paths.yaml`, because the primitive is not in `vendor_primitives.yaml` of `riscv-tools`.

## 7. Simulation model

`max10_flash_model` reproduces, at the Avalon-MM ports and the CSR registers, the behaviour described in section 5: the flash starts erased, a program only takes bits from 1 to 0 and the sector erase gives the ones back, a write or erase on a protected sector leaves the content unchanged and keeps the passed bit at zero, and the CSR read arrives one cycle after the request. The program and erase times are generics. The model does not represent the page erase, the per-sector read protection, the burst and the real chip times.

## 8. C example

```c
#include <stdint.h>

/* Base of the peripheral in the platform map (set at integration). */
#define MAX10_FLASH_BASE  ((volatile uint32_t *)0x40000000u)

enum { STATUS, CONTROL, ADDRESS, DATA, SECTOR, COMMAND, IP_STATUS };
enum { CMD_READ = 1, CMD_WRITE, CMD_ERASE, CMD_ENABLE, CMD_DISABLE };
enum { ST_BUSY = 1u << 0, ST_DONE = 1u << 1, ST_ERR = 1u << 2 };

static int flash_run(uint32_t cmd)
{
    MAX10_FLASH_BASE[COMMAND] = cmd;
    while (MAX10_FLASH_BASE[STATUS] & ST_BUSY) {
    }
    uint32_t status = MAX10_FLASH_BASE[STATUS];
    MAX10_FLASH_BASE[STATUS] = ST_DONE | ST_ERR;
    return (status & ST_ERR) ? -1 : 0;
}

/* Reads a word of the user flash; returns 0 and the word in *out. */
int flash_read_word(uint32_t word_addr, uint32_t *out)
{
    MAX10_FLASH_BASE[ADDRESS] = word_addr;
    if (flash_run(CMD_READ) != 0) {
        return -1;
    }
    *out = MAX10_FLASH_BASE[DATA];
    return 0;
}

/* Erases the sector (1 or 2) and programs a word in it. */
int flash_erase_and_write(uint32_t sector, uint32_t word_addr, uint32_t value)
{
    if (flash_run(CMD_ENABLE) != 0) {
        return -1;
    }
    MAX10_FLASH_BASE[SECTOR] = sector;
    if (flash_run(CMD_ERASE) != 0) {
        return -1;
    }
    if (flash_run(CMD_ENABLE) != 0) {
        return -1;
    }
    MAX10_FLASH_BASE[ADDRESS] = word_addr;
    MAX10_FLASH_BASE[DATA] = value;
    int rc = flash_run(CMD_WRITE);
    flash_run(CMD_DISABLE);
    return rc;
}
```

## 9. Verification

| Verification | Coverage |
| :--- | :--- |
| `Max10Flash` entry of `tests/python/tests.json`, module `tests.python.unittests.rom.max10_flash`, on the `max10_flash_tb` bench | State after reset; read of an erased word; read outside the flash with error; program refused without enable; enable, program, read back and disable; program as a bitwise AND; erase of one sector without touching the other; erase refusals; command while busy; interrupt |
| Formal proof `formal/max10_flash/run.sh` | See [blocks](../formal/blocks.md): the megafunction never receives a program, an erase or a control word outside the three allowed ones, whatever the software and its own response, with mutants |
| Quartus 25.1 synthesis | `10M50DAF484C7G`, controller and IP: 661 logic elements, 338 registers and the user flash block (1 of 1) |

## 10. Reference

| Source | Content |
| :--- | :--- |
| DE10-Lite manual, section 1.3 and chapter 6 | 5,888 Kbits of user flash and the MAX 10 internal configuration |
| Quartus 25.1 `altera_onchip_flash` (header `altera_onchip_flash_regs.h` and the IP Verilog) | Status and control CSR registers and the Avalon-MM interface protocol |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
