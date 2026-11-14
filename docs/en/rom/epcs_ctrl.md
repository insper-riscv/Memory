# epcs_ctrl

User access to the EPCS serial configuration flash: read, page program and sector erase over SPI, without touching the bitstream.

## 1. Role of the component in the SoC

The EPCS64 serial flash of the DE0-CV, DE2-115, DE0-Nano and DE10-Nano boards holds the FPGA configuration bitstream, and without this module only the programming tool reaches it. `epcs_ctrl` gives the software a 32-bit register bank that reads the whole chip and that programs and erases only the user region, above the configuration file. The module is a composition of three entities.

| Entity | Role |
| :--- | :--- |
| `epcs_cmd` | Registers, one-page buffer, user region guard and command sequencer |
| `epcs_spi` | SPI mode 0 master that builds one instruction frame per request |
| `epcs_ctrl` | Structural top: joins the two and exposes the bus and the four SPI pins |

The four SPI pins go to a device interface block (section 8) or to `epcs_model` in simulation.

## 2. Boards

| Board | Configuration flash | Source |
| :--- | :--- | :--- |
| DE0-CV | EPCS64 | DE0-CV manual, section 3.1 and the block diagram figure |
| DE2-115 | EPCS64 | DE2-115 manual, section 4.1 |
| DE0-Nano | Spansion EPCS64 | DE0-Nano manual, section 1.1 (the list in section 3 and the demonstration chapter repeat EPCS64; it is not EPCS16) |
| DE10-Nano | EPCS64 | DE10-Nano manual, sections 2.1, 2.2 and 3.2 |

The DE0-Nano manual says that the demonstration reaches the EPCS through pins that Quartus connects to an EPCS controller, and that the EPCS must be erased before it is written. None of the manuals gives the internal organization of the chip, the instruction codes or the bitstream footprint; that comes from the family datasheet (not included in `Docs`) and is marked as not confirmed where it is used.

## 3. Interface

### 3.1. `epcs_ctrl` generics

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `size_bytes` | `positive` | 8388608 | Chip size in bytes (EPCS64, 64 Mbits) |
| `user_base` | `natural` | 4194304 | Start of the user region in bytes, a multiple of the 64 KB sector |
| `clk_div` | `positive` | 2 | `i_clk` edges in each half period of `o_sck` |
| `gap_ticks` | `positive` | 8 | Half periods with `CS#` high after each frame |

The SPI clock frequency is

$$ f_{SCK} = \frac{f_{clk}}{2 \cdot \mathtt{clk\_div}} $$

and the default gives 12.5 MHz with the 50 MHz clock. The chip limit for each instruction is not in the board manuals (not confirmed).

### 3.2. Ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | Module clock |
| `i_rst` | input | 1 | Synchronous reset, active at `'1'` |
| `i_address` | input | 4 | Register index |
| `i_write` | input | 1 | Register write |
| `i_read` | input | 1 | Register read (only has an effect on `BUFDATA`) |
| `i_data_in` | input | 32 | Write data |
| `o_data_out` | output | 32 | Read data, combinational on `i_address` |
| `o_irq` | output | 1 | Done with the interrupt enabled |
| `o_sck` | output | 1 | SPI clock, low at rest |
| `o_cs_n` | output | 1 | Chip select, active at `'0'` |
| `o_mosi` | output | 1 | Data to the chip |
| `i_miso` | input | 1 | Data from the chip |

## 4. Registers

| Index | Name | Access | Content |
| ---: | :--- | :--- | :--- |
| 0 | `STATUS` | read and write 1 to clear | Bit 0 busy, bit 1 done, bit 2 error, bit 3 write enabled (WREN done), bit 4 operation in progress in the chip (WIP of the last RDSR), bits 15 to 8 last status register read. Writing `'1'` to bit 1 or 2 clears the bit |
| 1 | `CONTROL` | read and write | Bit 0 enables the interrupt, bit 1 makes the Read command use FAST_READ |
| 2 | `ADDRESS` | read and write | 24-bit byte address |
| 3 | `LENGTH` | read and write | Data bytes of Read and Program page, 1 to 256 |
| 4 | `COMMAND` | write | Command code (section 5) |
| 5 | `ID` | read | RDID answer: manufacturer in bits 23 to 16, then type and capacity |
| 6 | `USER_BASE` | read | Start of the user region |
| 7 | `SIZE` | read | Chip size in bytes |
| 8 | `BUFIDX` | read and write | Word index of the page buffer, 0 to 63 |
| 9 | `BUFDATA` | read and write | Buffer word at `BUFIDX`; each access advances `BUFIDX` |

The buffer holds the 256-byte page that Read fills and Program page sends, with byte 0 in bits 7 to 0 of word 0. The value read from `BUFDATA` reflects the index of two cycles earlier, so leave two cycles between consecutive accesses. While the controller is busy, reading `BUFDATA` returns zero and writing is ignored.

## 5. Commands

| Code | Command | SPI instruction | Effect |
| ---: | :--- | :--- | :--- |
| 1 | Identify | RDID (`0x9F`) | Reads 3 bytes into `ID` |
| 2 | Status | RDSR (`0x05`) | Reads the chip status register |
| 3 | Write enable | WREN (`0x06`) | On completion, raises the write-enabled bit |
| 4 | Read | READ (`0x03`) or FAST_READ (`0x0B`) | Reads `LENGTH` bytes from `ADDRESS` into the buffer |
| 5 | Program page | PP (`0x02`) | Writes `LENGTH` bytes of the buffer at `ADDRESS` |
| 6 | Erase sector | SE (`0xD8`) | Erases the 64 KB sector that contains `ADDRESS` |

The instruction codes are those of the M25P family that the EPCS follows, and are not in the board manuals (not confirmed). The module sends no other instruction: neither the whole-chip erase nor the status register write.

After Program page and Erase sector the module repeats RDSR until the chip WIP bit falls, and only then raises done and lowers write enabled. The Erase sector address is aligned to the start of the sector.

## 6. Bitstream guard

The user region goes from `user_base` to the end of the chip, and the configuration file lies below it.

| Command | Conditions to be accepted |
| :--- | :--- |
| Read | $1 \le \mathtt{LENGTH} \le 256$ and $\mathtt{ADDRESS} + \mathtt{LENGTH} \le \mathtt{size\_bytes}$ |
| Program page | Write enabled, $1 \le \mathtt{LENGTH} \le 256$, $\mathtt{ADDRESS} \ge \mathtt{user\_base}$, the program fits in the page ($\mathtt{ADDRESS} \bmod 256 + \mathtt{LENGTH} \le 256$) and inside the chip |
| Erase sector | Write enabled, sector start $\ge \mathtt{user\_base}$ and `ADDRESS` inside the chip |
| Write enable, Identify, Status | Always |

A refused command raises the error bit, lowers write enabled and generates no SPI frame. A command written while the controller is busy also raises the error, and the command in progress ends. Reading is valid over the whole chip, bitstream included, with no risk to it.

### 6.1. How to choose `user_base`

The bitstream occupies the start of the chip, and its size depends on the device and on compression. The board manuals do not give that size (not confirmed). The right value is the size of the programming file that Quartus generates for the project (the `.pof` or the `.jic`, and the `.rbf` as a cross-check), rounded up to a multiple of 64 KB:

$$ \mathtt{user\_base} = 65536 \cdot \left\lceil \frac{\text{file size}}{65536} \right\rceil $$

The 4 MB default reserves the lower half of the EPCS64 for the bitstream, which leaves ample room for the devices of the four boards (to be checked against the real file size of each project). A project that keeps more than one bitstream (factory and application image) adds the two sizes before rounding.

### 6.2. Care with the programming flow

The Erase step of the Quartus Programmer (DE10-Nano manual, section 8.4) erases the whole EPCS and takes the user data with it, so rewriting the bitstream through it requires saving the user region content first. Rewriting the configuration file without the Erase step only touches the sectors that the new file occupies (not confirmed in the manuals).

## 7. The SPI master

`epcs_spi` runs one frame per request, in SPI mode 0 (data leaves on the falling clock edge and the chip samples on the rising edge), with `CS#` low from the first to the last bit.

| Operation | Frame sent | Data |
| :--- | :--- | :--- |
| RDID | `0x9F` | Receives 3 bytes |
| RDSR | `0x05` | Receives 1 byte |
| WREN | `0x06` | None |
| READ | `0x03`, 24-bit address | Receives $n$ bytes |
| FAST_READ | `0x0B`, 24-bit address, 1 dummy byte | Receives $n$ bytes |
| PP | `0x02`, 24-bit address | Sends $n$ bytes |
| SE | `0xD8`, 24-bit address | None |

Each received byte leaves in a pulse with its index in the data, and each byte to send is requested by index, which the buffer owner answers within three edges. The frame ends with `CS#` high for `gap_ticks` half periods, which must cover the minimum `CS#` high time of the chip (not confirmed), and then the end pulse rises.

## 8. Interface with the configuration pins

The configuration flash pins (`DCLK`, `nCSO`, `ASDO` and `DATA0`) are dedicated, and the FPGA only reaches them through the ASMI block of the family. Each family has a thin shell that instantiates the block by `component`, with no logic, wired as the Altera `altserial_flash_loader` wires it in Quartus 25.1.

| Shell | Families and boards | Block | Wiring |
| :--- | :--- | :--- | :--- |
| `epcs_asmi_cyclone_iv_e` | Cyclone IV E: DE0-Nano, DE2-115 | `cycloneii_asmiblock` | `dclkin` to the clock, `scein` to the select, `sdoin` to the data to the chip, `data0out` to the data from the chip, `oe` at `'0'` |
| `epcs_asmi_cyclone_v` | Cyclone V: DE0-CV, DE10-Nano | `cyclonev_asmiblock` | `dclk` to the clock, `sce` to the select, `data0out` to the data to the chip, `data1in` to the data from the chip, `data2out` and `data3out` at `'1'`, `oe` at `'0'` |

Both shells are in `tree.vhdl_style.exclude` of `paths.yaml`, because the two primitives are not in `vendor_primitives.yaml` of `riscv-tools`.

### 8.1. Quartus project assignments

The ASMI block requires the project configuration scheme to be active serial.

| Family | Assignment |
| :--- | :--- |
| Cyclone IV E | The Quartus default is already active serial |
| Cyclone V (DE0-CV, DE10-Nano) | `set_global_assignment -name STRATIXV_CONFIGURATION_SCHEME "Active Serial x1"`; without it the fit fails with error 176289 |

On the DE10-Nano and the DE0-Nano, the FPGA configuration mode also depends on the MSEL switches of the board, which are outside the scope of this module.

### 8.2. What was not confirmed

| Item | State |
| :--- | :--- |
| Operation on a board | Not tested: simulation, formal proof and Quartus 25.1 synthesis only |
| Polarity of `scein` and `sce` | Taken from the Quartus `altserial_flash_loader`, with no pin test |
| Instruction codes, RDID bytes, chip times and maximum SCK frequency | The family datasheet is not in `Docs`; values from memory |
| Bitstream size of each project | Depends on the generated file, not on the manuals |

## 9. Simulation model

`epcs_model` is an SPI mode 0 slave that imitates the EPCS: status register with WIP and WEL, read (READ and FAST_READ), RDID, WREN, PP with page wrap and 64 KB sector SE, with the rule that programming only takes bits from 1 to 0. The content starts with an address-dependent pattern, and the part below `protect_below` pretends to be the bitstream. The model raises `o_violation` when the controller does what a real chip ignores or what the bitstream does not tolerate.

| Violation | Cause |
| :--- | :--- |
| PP or SE without WREN | Program or erase frame with write disabled in the chip |
| PP or SE below `protect_below` | Program or erase in the bitstream |
| Instruction outside the list | Any code that is not one of the seven |
| Instruction other than RDSR during a program | The controller did not wait for the end of the operation |
| Frame that ends off a byte | SPI master error |

## 10. C example

```c
#include <stdint.h>

/* Base of the peripheral in the platform map (set at integration). */
#define EPCS_BASE  ((volatile uint32_t *)0x40001000u)

enum { STATUS, CONTROL, ADDRESS, LENGTH, COMMAND, ID, USER_BASE, SIZE,
       BUFIDX, BUFDATA };
enum { CMD_RDID = 1, CMD_RDSR, CMD_WREN, CMD_READ, CMD_PP, CMD_SE };
enum { ST_BUSY = 1u << 0, ST_DONE = 1u << 1, ST_ERR = 1u << 2 };

static int epcs_run(uint32_t cmd)
{
    EPCS_BASE[COMMAND] = cmd;
    while (EPCS_BASE[STATUS] & ST_BUSY) {
    }
    uint32_t status = EPCS_BASE[STATUS];
    EPCS_BASE[STATUS] = ST_DONE | ST_ERR;
    return (status & ST_ERR) ? -1 : 0;
}

/* Reads the chip identifier (0 on error). */
uint32_t epcs_id(void)
{
    return epcs_run(CMD_RDID) == 0 ? EPCS_BASE[ID] & 0xFFFFFFu : 0;
}

/* Reads up to 256 bytes from any chip address. */
int epcs_read(uint32_t addr, uint8_t *dst, uint32_t len)
{
    EPCS_BASE[ADDRESS] = addr;
    EPCS_BASE[LENGTH] = len;
    if (epcs_run(CMD_READ) != 0) {
        return -1;
    }
    EPCS_BASE[BUFIDX] = 0;
    for (uint32_t i = 0; i < len; i += 4) {
        uint32_t word = EPCS_BASE[BUFDATA];
        for (uint32_t b = 0; b < 4 && i + b < len; b++) {
            dst[i + b] = (uint8_t)(word >> (8 * b));
        }
    }
    return 0;
}

/* Erases the 64 KB sector that contains addr (must be in the user region). */
int epcs_erase_sector(uint32_t addr)
{
    EPCS_BASE[ADDRESS] = addr;
    if (epcs_run(CMD_WREN) != 0) {
        return -1;
    }
    return epcs_run(CMD_SE);
}

/* Programs up to 256 bytes inside one page of the user region. */
int epcs_program_page(uint32_t addr, const uint8_t *src, uint32_t len)
{
    EPCS_BASE[BUFIDX] = 0;
    for (uint32_t i = 0; i < len; i += 4) {
        uint32_t word = 0xFFFFFFFFu;
        for (uint32_t b = 0; b < 4 && i + b < len; b++) {
            word &= ~(0xFFu << (8 * b));
            word |= (uint32_t)src[i + b] << (8 * b);
        }
        EPCS_BASE[BUFDATA] = word;
    }
    EPCS_BASE[ADDRESS] = addr;
    EPCS_BASE[LENGTH] = len;
    if (epcs_run(CMD_WREN) != 0) {
        return -1;
    }
    return epcs_run(CMD_PP);
}
```

A page only accepts bits that go from 1 to 0, so the region must have been erased before programming. A program address below `USER_BASE` (register 6) is refused.

## 11. Verification

| Verification | Coverage |
| :--- | :--- |
| `EpcsCtrl` entry of `tests/python/tests.json`, module `tests.python.unittests.rom.epcs_ctrl`, on the `epcs_ctrl_tb` bench | Constant registers; RDID and RDSR; Read and FAST_READ in several regions against the model pattern; Read outside the chip or with an invalid length; Program and Erase without WREN with no frame at all; sector erase and the wait for the chip; page program as a bitwise AND; a whole page; bitstream protected against Program and Erase; Program that crosses the page; command while busy; interrupt. Every test checks that the model raised no violation |
| Formal proof `formal/epcs_ctrl/run.sh` | See [blocks](../formal/blocks.md): on the SPI pins, only the seven instructions leave, PP and SE only after a finished WREN, only in the user region, SE aligned to the sector and PP inside the page, with mutants |
| Quartus 25.1 synthesis | Controller and shell, fitted in EP4CE22F17C6 (594 logic elements), EP4CE115F29C7 (580), 5CSEBA6U23I7 (244 ALMs) and 5CEBA4F23C7 (245 ALMs), 232 registers and 2048 memory bits in all |

## 12. Reference

| Source | Content |
| :--- | :--- |
| DE10-Nano manual, sections 2.1, 2.2 and 3.2 | EPCS64 configuration device |
| DE0-Nano manual, section 1.1 and the EPCS demonstration | Spansion EPCS64; the EPCS must be erased before it is written |
| DE0-CV (section 3.1) and DE2-115 (section 4.1) manuals | EPCS64 configuration device |
| Quartus 25.1 `altserial_flash_loader` | Wiring of the ASMI blocks of the Cyclone IV E and Cyclone V families |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
