# sdram_model

## 1. Role of the component in the SoC

Behavioral model of the board's SDR SDRAM, used only in simulation. The generics fix the width of the data bus and the widths of row, bank and column, and the default is the 32M x 16 chip of the DE0-CV. It stores the written data in a sparse table and fails the simulation (`severity failure`) when the controller breaks a chip rule. A test that ends without a failure therefore proves that the controller meets the times of [sdram_pkg](sdram_pkg.md), the command order, the power-up, the mode register and the refresh interval. The model also offers debug ports that read and corrupt the stored memory.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `tck_ps` | natural | `T_CK_PS` (7000) | clock period in ps, converted into simulation time |
| `init_file` | string | empty | file with the initial image of the chip, empty for a zeroed chip |
| `dq_width` | natural | 16 | width of the data bus in bits, 16 or 32, which sets the burst of $32 / \text{dq\_width}$ beats |
| `row_bits` | natural | 13 | row address bits |
| `bank_bits` | natural | 2 | bank address bits |
| `col_bits` | natural | 10 | column address bits |

### 2.2. Chip ports

| Port | Dir. | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | in | 1 | chip clock |
| `i_cke` | in | 1 | clock enable, and without it the command is ignored |
| `i_cs_n` | in | 1 | chip select, active at `'0'` |
| `i_ras_n` | in | 1 | row address strobe, active at `'0'` |
| `i_cas_n` | in | 1 | column address strobe, active at `'0'` |
| `i_we_n` | in | 1 | write enable, active at `'0'` |
| `i_ba` | in | `bank_bits` | bank |
| `i_a` | in | larger of `row_bits` and `col_bits` + 1 | row or column address |
| `i_dqm` | in | `dq_width` / 8 | data byte mask, which masks at `'1'` |
| `io_dq` | inout | `dq_width` | DQ data pins |
| `i_reinit` | in | 1 | at `'1'` while the controller is in reset, and restarts the chip's power-up sequence |

### 2.3. Debug ports

| Port | Dir. | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_dbg_word_addr` | in | $AW$ (24 by default, 25 with `dq_width` equal to 32) | word address read directly from the stored memory |
| `o_dbg_word_data` | out | 32 | word stored at that address, registered on the chip clock |
| `i_dbg_flip` | in | 1 | a rising edge flips one bit of a stored word |
| `i_dbg_flip_addr` | in | $AW$ | word address whose bit is flipped |
| `i_dbg_flip_bit` | in | 5 | position of the flipped bit in the word |
| `o_dbg_refreshes` | out | 32 | number of AUTO REFRESH commands received |
| `o_dbg_init_ok` | out | 1 | `'1'` when the mode register was loaded after an accepted power-up sequence |

## 3. Behavior

### 3.1. Storage

The memory is a sparse table of units of `dq_width` bits, the width of one beat, with 65536 buckets of linked lists. The key of each unit is

$$
k = (\text{row} \cdot 2^{\text{bank\_bits}} + \text{bank}) \cdot 2^{\text{col\_bits}} + \text{column}
$$

and a position never written reads as zero. The word at address $w$ occupies the units $Bw$ to $Bw + B - 1$, lowest bits first, with $B = 32 / \text{dq\_width}$. On a write, a byte is stored only when its bit of `i_dqm` is `'0'`.

### 3.2. Initial image

With a non-empty `init_file`, the model reads the file at time zero. Each line with at least 8 characters is a 32-bit word in hexadecimal, stored from word address 0. The image stands for the host that loaded the chip through the debug port before the core was released.

### 3.3. Commands

The chip recognizes a command only when `i_cke` is `'1'`, `i_cs_n` is `'0'` and `i_reinit` is `'0'`. The last condition makes the model ignore the command that the controller still carries in its registers on the first edge of a reset, as detailed in [SDRAM_MODEL_RESET_COMMAND.md](../bugs/SDRAM_MODEL_RESET_COMMAND.md).

With `i_reinit` equal to `'1'`, the model restarts the power-up instant, forgets the PRECHARGE and the refreshes seen, closes every bank and clears the refresh check.

### 3.4. Rules checked

Each violation below fails the simulation.

| Command | Rule |
| :--- | :--- |
| first command | only after `T_INIT_PS` since the start of power-up |
| LOAD MODE REGISTER | after a PRECHARGE of all banks and at least two refreshes, outside the interval of a refresh, with the value `MODE_REG` |
| PRECHARGE | outside the interval of a refresh; an open bank closes only after `T_RAS_PS` and, in a single-bank PRECHARGE, after `T_WR_PS` since the last write data |
| AUTO REFRESH | after a PRECHARGE of all banks, with every bank closed and outside the PRECHARGE time, and outside the interval of another refresh |
| ACTIVE | after the mode register, after `T_MRD_CK` clocks, outside a refresh, with the bank closed, after `T_RP_PS` from the bank closing and `T_RC_PS` from the previous ACTIVE of the same bank |
| READ or WRITE | after the mode register, with the bank open, after `T_RCD_PS` from the ACTIVE, without overlapping the previous burst and with an even column |
| periodic refresh | after the mode register, two refreshes are never more than `T_REFI_PS` apart |

The model does not check the interval between ACTIVE commands of different banks. The controller keeps one row open at a time, and the $t_{RRD}$ time does not apply.

### 3.5. Read and write

A READ puts the $B = 32 / \text{dq\_width}$ beats from the column into a read pipeline. The first beat appears on the DQ pins $CL$ edges after the edge on which the chip samples the command, and each following one an edge after the previous. Outside those clocks the model releases the pins (high impedance). The column of the command must be a multiple of $B$, and the model fails the simulation otherwise.

On a WRITE the first beat is stored on the command edge and the second, when $B = 2$, on the next edge, each with the byte mask of that clock.

With address bit 10 at `'1'`, the command does an auto-precharge. The bank closes and accepts an ACTIVE only after the instant

$$
t_{idle} = t_{pre} + T_{RP}, \quad t_{pre} = \max\left(t_{cmd} + B\,T_{CK},\; t_{act} + T_{RAS}\right)
$$

for the READ. For the WRITE, $t_{cmd} + B\,T_{CK}$ is replaced by $t_{cmd} + (B - 1)\,T_{CK} + T_{WR}$. Each burst command occupies the bus for $B\,T_{CK}$, so the second READ of a line must come $B$ clocks after the first.

### 3.6. Debug

`o_dbg_word_data` delivers the stored word one clock after `i_dbg_word_addr`. A rising pulse on `i_dbg_flip` flips bit `i_dbg_flip_bit` of the word at `i_dbg_flip_addr`, and a second pulse undoes the flip. The flip serves to prove that a check notices a corrupted memory.

## 4. Integration

| Instance | Where | Connection |
| :--- | :--- | :--- |
| `u_chip` in `sdram_system` | simulation top of the subsystem | `tck_ps` and `init_file` from the top generics, `i_reinit` tied to the controller-side reset, debug ports taken to the top port |
| `u_chip` in `teste_sdram_system` | simulation top of the self test | default generics and `i_reinit` tied to the self-test reset |

The top joins the DQ pins. The [sdram_ctrl](sdram_ctrl.md) drives them when `o_dram_dq_oe` is `'1'`, and the model drives them otherwise. The top of the subsystem is in turn used by the tops of the data cache and of the AXI slave.

## 5. Verification

The model has no dedicated test. It is the judge of the controller tests, and the debug ports are the means to check the contents of the chip.

| `tests.json` entry | Test module | Use of the model |
| :--- | :--- | :--- |
| `SdramSystem` | [sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py) | checks each word read against the chip contents, requires `o_dbg_init_ok` and at least 8 refreshes after power-up, counts refreshes in 60 µs and uses `i_dbg_flip` to prove that a flipped bit shows up on the read |
| `SdramBist` and `SdramBistRegisteredPins` | [sdram_bist.py](../../../tests/python/unittests/ram/sdram_bist.py) | the self test over the model, with the control of a bit flipped in the chip |
| `SdramDebugPort` | [sdram_debug_port.py](../../../tests/python/unittests/ram/sdram_debug_port.py) | host reads and writes checked in the chip |
| `DataCache`, `DataCacheWriteThrough` and `AxiSdramSlave` | [axi_sdram_slave.py](../../../tests/python/unittests/barramento/axi_sdram_slave.py) and the cache modules | check of the chip contents after line and word accesses |

No test fills the chip through `init_file`.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
