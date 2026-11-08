# sdram_ctrl

## 1. Role of the component in the SoC

Controller of the SDR SDRAM. The generics default to the 32M x 16 chip (64 MB) of the DE0-CV board, and the width of the data bus and the widths of row, bank and column are generics, which also covers the 32-bit chip of the DE2-115. It receives requests for one 32-bit word, or for one line of four words (16 bytes), through a toggle handshake and generates the chip's command sequence. The policy is closed page. Every access activates its row and reads or writes with auto-precharge, so no row stays open and the order of the commands does not depend on the previous access. The controller also runs the power-up sequence and issues the periodic refreshes.

The chip times come from [sdram_pkg](sdram_pkg.md) and are compared with the datasheet in [sdram_timings.md](sdram_timings.md). The line request is described from the system's point of view in [sdram_line.md](sdram_line.md).

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `tck_ps` | natural | `T_CK_PS` (7000) | clock period in ps, the base for converting the chip times into cycles |
| `init_cycles` | natural | `cycles(T_INIT_PS, T_CK_PS)` (28572) | wait cycles after reset before the first command |
| `refresh_cycles` | natural | `cycles(T_REFI_PS, T_CK_PS) * 9 / 10` (1005) | count of the interval between two refreshes |
| `capture_extra` | natural | 0 | extra clocks before sampling the read data, to compensate the phase of the board |
| `sync_req` | boolean | true | true sends the request toggle through a synchronizer, false uses it directly because it comes from this clock |
| `dq_width` | natural | 16 | width of the chip data bus in bits, 16 or 32, which sets the burst of $B = 32 / \text{dq\_width}$ beats per word |
| `row_bits` | natural | 13 | row address bits of the chip |
| `bank_bits` | natural | 2 | bank address bits of the chip |
| `col_bits` | natural | 10 | column address bits of the chip, at most 10 because bit 10 of `o_dram_addr` is the auto-precharge |

### 2.2. Request ports

| Port | Dir. | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | in | 1 | controller clock |
| `i_rst` | in | 1 | synchronous reset, active at `'1'` |
| `i_req_tog` | in | 1 | each flip is a new request |
| `o_ack_tog` | out | 1 | equal to `i_req_tog` once the request is served |
| `o_init_done` | out | 1 | `'1'` after the power-up finished |
| `i_we` | in | 1 | write (`'1'`) or read (`'0'`) |
| `i_addr` | in | $AW$ | 32-bit word address, with $AW$ defined in section 3.2 (24 by default) |
| `i_wdata` | in | 32 | write data (word 0) |
| `i_be` | in | 4 | byte enables of word 0, one bit per byte |
| `o_rdata` | out | 32 | read data (word 0) |
| `i_line` | in | 1 | `'1'` requests a line of four words (default `'0'`) |
| `i_wdata_x` | in | 96 | words 1 to 3 of the write data, word 1 in the lowest bits (default zero) |
| `i_be_x` | in | 12 | byte enables of words 1 to 3 (default zero) |
| `o_rdata_x` | out | 96 | words 1 to 3 of the read data |

### 2.3. Chip ports

| Port | Dir. | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `o_dram_cke` | out | 1 | clock enable of the chip, fixed at `'1'` |
| `o_dram_cs_n` | out | 1 | chip select, active at `'0'` |
| `o_dram_ras_n` | out | 1 | row address strobe, active at `'0'` |
| `o_dram_cas_n` | out | 1 | column address strobe, active at `'0'` |
| `o_dram_we_n` | out | 1 | write enable, active at `'0'` |
| `o_dram_ba` | out | `bank_bits` | bank |
| `o_dram_addr` | out | larger of `row_bits` and `col_bits` + 1 | row or column address |
| `o_dram_dqm` | out | `dq_width` / 8 | data byte mask, one bit per byte, masks at `'1'` |
| `o_dram_dq_out` | out | `dq_width` | data the controller places on the DQ pins |
| `o_dram_dq_oe` | out | 1 | `'1'` when the controller drives the DQ pins |
| `i_dram_dq_in` | in | `dq_width` | data read from the DQ pins |

Every chip output comes from a register. A command decided on one edge appears on the pins right after it, and the chip samples it on the next edge. Without a command, the pins carry NOP with address and mask at zero, and `o_dram_dq_oe` stays at `'0'`.

## 3. Behavior

### 3.1. Request handshake

The requester places the request fields on the buses and flips `i_req_tog`. The buses stay stable from the flip of `i_req_tog` until the flip of `o_ack_tog`. A request is pending while the effective request toggle differs from `o_ack_tog`. The controller accepts a request only in the idle state and with the minimum command interval already met (section 3.4). On acceptance it copies every field into internal registers and flips `o_ack_tog` at the end of the access.

With `sync_req` true, the request toggle crosses a synchronizer from Common-Components, which allows a requester on another clock. With `sync_req` false the toggle is used directly, without the latency of the synchronizer.

Reset takes `o_ack_tog` to `'0'`. The read data changes only when a read is sampled, and a write request changes neither `o_rdata` nor `o_rdata_x`.

### 3.2. Addressing

The word address has $AW = \text{row\_bits} + \text{bank\_bits} + \text{col\_bits} - \log_2 B$ bits. With $B = 2$ the chip column is always even, and with $B = 1$ the word column is the chip column. With $WC = \text{col\_bits} - \log_2 B$, the width of the word column, the fields of `i_addr` are those of the table.

| Bits of `i_addr` | Field | Destination |
| :--- | :--- | :--- |
| $AW - 1$ to $WC + \text{bank\_bits}$ | row | `o_dram_addr` at ACTIVE |
| $WC + \text{bank\_bits} - 1$ to $WC$ | bank | `o_dram_ba` |
| $WC - 1$ to 0 | word column | bits $\text{col\_bits} - 1$ to $\log_2 B$ of `o_dram_addr` at READ and WRITE, with the low $\log_2 B$ bits at zero |

By default (the DE0-CV) $AW = 24$ and $WC = 9$, and the row, bank and column are bits 23 to 11, 10 to 9 and 8 to 0. With the 32-bit chip of the DE2-115, $AW = 25$ and $WC = 10$, and they are bits 24 to 12, 11 to 10 and 9 to 0.

At READ and WRITE, bit 10 of `o_dram_addr` is the auto-precharge. In a word access it is `'1'`. In a line access it is `'1'` only on the fourth command, and the two bits of `o_dram_addr` just above the burst bits carry the word index (0 to 3) in place of the two low bits of `i_addr`. The four words of a line fall in the same row and bank of the chip because the line has 16 bytes and is aligned.

### 3.3. State machine

| State | What it does |
| :--- | :--- |
| `ST_INIT_WAIT` | counts `init_cycles` clocks after reset |
| `ST_INIT_PRE` | issues PRECHARGE of all banks |
| `ST_INIT_REF` | issues AUTO REFRESH, `INIT_REFRESHES` times |
| `ST_INIT_MRS` | issues LOAD MODE REGISTER with the package value and signals `o_init_done` |
| `ST_WAIT` | counts the clocks until the next command |
| `ST_IDLE` | issues the due refresh or accepts a request and issues the ACTIVE |
| `ST_RW` | issues the READ or the WRITE of one word |
| `ST_RDGAP` | gap clock between two READs of a line |
| `ST_WRITE2` | places the second beat of a write on the pins |
| `ST_READ` | waits for the data sampling, which ends the access |

A wait of $n$ clocks means the next command goes out $n$ edges after the current command.

### 3.4. Minimum intervals between commands

With $C_x = \lceil T_x / T_{CK} \rceil$ and $T_{CK} = 7000$ ps, the values are $C_{RCD} = 3$, $C_{RP} = 3$, $C_{RC} = 9$, $C_{RFC} = 9$ and $C_{WR} = 2$. The controller defines two intervals between one ACTIVE and the next, one for the word and one for the line.

$$
N_{word} = \max\left(C_{RC},\; C_{RCD} + CL + B + 2,\; C_{RCD} + B + C_{WR} + C_{RP}\right) = 10
$$

$$
N_{line} = \max\left(C_{RC},\; C_{RCD} + 3B + CL + B + 2,\; C_{RCD} + 4B + C_{WR} + C_{RP}\right) = 16
$$

The numeric values are those of $B = 2$. With $B = 1$ they are $N_{word} = 9$ and $N_{line} = 12$.

At ACTIVE, a counter is loaded with $N_{word}$ or $N_{line}$ and decrements every clock. A new ACTIVE or a refresh goes out only when the counter reaches zero, which happens $N + 1$ clocks after the ACTIVE. The same counter protects the $C_{RFC}$ interval after a refresh and the `T_MRD_CK` after the mode register.

### 3.5. Power-up

1. After reset, wait `init_cycles` clocks with no command.
2. Issue PRECHARGE of all banks (address bit 10 at `'1'`) and wait $C_{RP}$.
3. Issue `INIT_REFRESHES` AUTO REFRESH commands, each followed by a wait of $C_{RFC}$.
4. Issue LOAD MODE REGISTER with the value defined in [sdram_pkg](sdram_pkg.md), set `o_init_done` to `'1'` and load the refresh counter.
5. Wait `T_MRD_CK` clocks and go to the idle state.

### 3.6. Accesses

The instants below are counted in edges from $t_0$, the edge on which the controller decides the ACTIVE. Each command is on the pins right after the edge on which it is decided.

| Access | Commands (decision edge) | Data | `o_ack_tog` flips at | Next ACTIVE from |
| :--- | :--- | :--- | :--- | :--- |
| word read | READ at $t_0+3$ | beats 0 and 1 sampled at $t_0+8$ and $t_0+9$ | $t_0+9$ | $t_0+11$ |
| word write | WRITE at $t_0+3$ | beat 0 with the WRITE, beat 1 one clock later | $t_0+4$ | $t_0+11$ |
| line read | READ at $t_0+3$, $t_0+5$, $t_0+7$ and $t_0+9$ | beats 0 to 7 sampled from $t_0+8$ to $t_0+15$ | $t_0+15$ | $t_0+17$ |
| line write | WRITE at $t_0+3$, $t_0+5$, $t_0+7$ and $t_0+9$ | two beats per word, the last at $t_0+10$ | $t_0+10$ | $t_0+17$ |

The first READ or WRITE goes out $C_{RCD}$ clocks after the ACTIVE. In a line, the following commands go out every $B$ clocks, the length of a burst, and the $4B$ beats occupy the pins with no gap. The table holds for $B = 2$. With $B = 1$ (32-bit chip) the burst has one beat, the four commands of a line go out from $t_0+3$ to $t_0+6$, the states `ST_RDGAP` and `ST_WRITE2` are not used and a word request ends at beat 0.

On a read, beat $m$ (0 to $4B - 1$, that is, 0 to 7 by default) is sampled $CL + 2 + m + \text{capture\_extra}$ clocks after the edge of the first READ. Beat $m$ takes the slice of `dq_width` bits that starts at bit `dq_width` $\cdot\, m$ of the vector made of `o_rdata` and, above it, `o_rdata_x`. By default beats 0 and 1 form `o_rdata` and beats 2 to 7 form, two by two, words 1 to 3 of `o_rdata_x`. The request ends at the sampling of the last beat, beat $B - 1$ in a word access and beat $4B - 1$ in a line access.

On a write, the beats of each word carry the slices of `dq_width` bits of the word, lowest first, and the mask of each beat is the complement of the bits of `i_be` (or `i_be_x`) of that slice. The chip does not change a masked byte. A read uses no mask.

### 3.7. Refresh

After power-up, a counter marks a refresh as due every $\text{refresh\_cycles} + 1$ clocks. In the idle state, a due refresh has priority over a pending request, as long as the minimum command interval is met. After the refresh, the next command waits $C_{RFC}$.

With the default values the period is 1006 clocks, about 7.04 µs, and the chip model fails the simulation when two refreshes are more than $T_{REFI} = 7.8125$ µs apart.

## 4. Integration

| Instance | Where | How it connects the controller |
| :--- | :--- | :--- |
| `u_ctrl` in `sdram_system` | simulation top of the subsystem | behind [sdram_arbiter](sdram_arbiter.md), with `sync_req` false and `tck_ps`, `init_cycles` and `refresh_cycles` passed from the top generics |
| `u_ctrl` in `teste_sdram_system` | simulation top of the self test | connected directly to the self test, with default `sync_req` and `capture_extra` from the top generic |

With `capture_extra` equal to 1, the top of the self test registers the data pins once before they enter the controller. The DQ pins are resolved outside the controller. The top places `o_dram_dq_out` on the pins when `o_dram_dq_oe` is `'1'`, and the chip model ([sdram_model](sdram_model.md)) drives the pins otherwise. The synchronizer instantiated comes from Common-Components (`src/common/src/synchronizer.vhd`), which the tests compile before the controller.

## 5. Verification

The chip model fails the simulation on any violation of timing, command order, power-up or refresh interval. A test that passes therefore also proves that the controller obeys the chip. The formal proof of the controller is in `formal/sdram_ctrl/` and runs on the netlist of each width, the 16-bit one (at the 7 ns and 10 ns clocks) and the 32-bit one.

| `tests.json` entry | Test module | What it exercises in the controller |
| :--- | :--- | :--- |
| `SdramSystem` | [sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py) | power-up, write and read, every byte-enable mask, bank, row and column decoding, random traffic, refresh with the bus idle for 60 µs, different relations between the core clock and the controller clock, a corrupted bit in the chip, line accesses (write, read, masks and cost against four words) and a mix of lines and words |
| `SdramCtrl32` and `SdramSystem32` | [sdram_ctrl.py](../../../tests/python/unittests/ram/sdram_ctrl.py) and [sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py) | the same power-up, word, mask, line, refresh and random traffic tests with `dq_width` equal to 32, on the model of the 32-bit chip |
| `SdramBist` | [sdram_bist.py](../../../tests/python/unittests/ram/sdram_bist.py) | the controller connected directly to the self test, in the quick, patterns, sweep and random address modes, plus the control of a bit flipped in the chip |
| `SdramBistRegisteredPins` | [sdram_bist.py](../../../tests/python/unittests/ram/sdram_bist.py) | the same tests with `capture_extra` equal to 1 and the data pins registered |
| `SdramDebugPort` | [sdram_debug_port.py](../../../tests/python/unittests/ram/sdram_debug_port.py) | accesses from the core and the host at the same time, a long fill and the wait bound of the core |
| `DataCache`, `DataCacheWriteThrough` and `AxiSdramSlave` | `data_cache.py`, `data_cache_write_through.py` and [axi_sdram_slave.py](../../../tests/python/unittests/barramento/axi_sdram_slave.py) | word and line accesses coming from the cache and from the AXI slave, through the same subsystem |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
