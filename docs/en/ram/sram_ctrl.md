# sram_ctrl

Controller of a 16-bit asynchronous SRAM behind the data contract of [ram_chip](ram_chip.md).

## 1. Role of the component in the SoC

The controller is the `dispositivo/sram` backend of the RAM region. It serves the SoC with the data contract of `ram_chip` (a request for one word or for a line of four words, byte enables on write, an out-of-window address reads zero) and drives the pins of a 1M x 16 SRAM, such as the IS61WV102416BLL-10 of the DE2-115: 20 address bits of 16-bit words, `CE#`, `OE#`, `WE#`, `LB#` and `UB#`. A 32-bit word is two half-word accesses, and a line is eight. The controller has a single port, and the arbiter in front of it shares the masters.

## 2. Interface

### 2.1. Generics

The times are in ns, and the defaults come from [chip_timing_pkg](../rom/chip_timing_pkg.md).

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `clk_period_ns` | `positive` | 20 | Clock period |
| `margin_ns` | `natural` | 0 | Margin added to each time for pin and board delay |
| `size_bytes` | `positive` | 2097152 | Chip size, power of two from 16 bytes to 2 MB |
| `base_kib` | `natural` | 0 | Where the chip starts inside the 64 MB of the region, in KiB |
| `t_aa_ns`, `t_rc_ns` | `natural` | 10, 10 | Address access and read cycle |
| `t_wc_ns`, `t_sce_ns`, `t_aw_ns` | `natural` | 10, 8, 8 | Write cycle, `CE#` and address to the end of the write |
| `t_pwe_ns`, `t_sd_ns` | `natural` | 8, 6 | `WE#` pulse and data before the rise |
| `t_ha_ns`, `t_hd_ns` | `natural` | 0, 0 | Address and data held after the rise |

### 2.2. SoC ports

They are those of the `ram_chip` data port, with the advance called `i_advance` (contract K2).

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk`, `i_rst` | input | 1 | Clock and synchronous reset, active at `'1'` |
| `i_addr` | input | 32 | Byte address of the access |
| `i_wdata`, `i_byteena` | input | 32, 4 | Data and byte enable of word 0 |
| `i_rden`, `i_wren` | input | 1 | Read and write request; the write prevails |
| `i_advance` | input | 1 | The pipeline advanced in this cycle |
| `o_ready` | output | 1 | Access done, held until `i_advance` |
| `o_rdata` | output | 32 | Data read, which changes only on the edge of `i_advance` |
| `i_line` | input | 1 | Four-word line access |
| `i_wdata_x`, `i_byteena_x` | input | 96, 12 | Words 1 to 3 of the data and of the byte enable |
| `o_rdata_x` | output | 96 | Words 1 to 3 of the data read |

### 2.3. Chip ports

| Port | Direction | Width | DE2-115 pin |
| :--- | :--- | ---: | :--- |
| `o_sram_addr` | output | 20 | `SRAM_ADDR[19:0]` |
| `o_sram_dq` | output | 16 | `SRAM_DQ[15:0]`, data to write |
| `o_sram_dq_oe` | output | 1 | The controller drives `SRAM_DQ`; the top does the tristate |
| `i_sram_dq` | input | 16 | `SRAM_DQ[15:0]`, data read |
| `o_sram_ce_n`, `o_sram_oe_n`, `o_sram_we_n` | output | 1 | `SRAM_CE_N`, `SRAM_OE_N`, `SRAM_WE_N` |
| `o_sram_lb_n`, `o_sram_ub_n` | output | 1 | `SRAM_LB_N`, `SRAM_UB_N` |

## 3. Behavior

### 3.1. Cycles of each phase

With $T$ the period, $m$ the margin and $\lceil x \rceil$ the ceiling with a minimum of one (`cycles_of`),

$$ n_{rd} = \left\lceil \frac{\max(t_{aa}, t_{rc}) + m}{T} \right\rceil \qquad n_{wl} = \max\left( \left\lceil \frac{t_{pwe} + m}{T} \right\rceil,\ \left\lceil \frac{\max(t_{sd}, t_{aw}, t_{sce}) + m}{T} \right\rceil - 1 \right) $$

$$ n_{wh} = \max\left( \left\lceil \frac{\max(t_{ha}, t_{hd}) + m}{T} \right\rceil,\ \left\lceil \frac{t_{wc} + m}{T} \right\rceil - n_{wl} - 1 \right) $$

At 50 MHz the defaults give $n_{rd} = n_{wl} = n_{wh} = 1$. When the period is smaller than the access time, $n_{rd}$ rises and each half word takes more than one cycle.

### 3.2. Read

For each half word the address leaves a register together with `CE#`, `OE#`, `LB#` and `UB#` low, and the data is captured $n_{rd}$ cycles later, with the next address leaving on the same edge. A word takes $2\,n_{rd}$ cycles and a line $8\,n_{rd}$, besides the cycle that accepts the request, and `o_ready` rises in the cycle after the last capture. The data waits in a pending register and moves to `o_rdata` on the edge of `i_advance`, because the load still in the write stage reads the previous value until then.

### 3.3. Write

Only the half words with some byte enabled are written, in address order, with `LB#` and `UB#` following the byte-enable bits: a byte store does not touch the neighbor byte. Each write has the half-word selection cycle, a setup cycle with address, data, `CE#`, `LB#` and `UB#` already on the pins and `OE#` high, `WE#` low for $n_{wl}$ cycles and `WE#` high for $n_{wh}$ cycles. The controller drives `SRAM_DQ` only in the write.

### 3.4. Window

An access outside the interval $[B,\ B + S)$, with $B$ equal to `base_kib` in bytes and $S$ equal to `size_bytes`, ends without touching the chip: the read returns zero and the write is discarded.

### 3.5. State machine

| State | Action | Next state |
| :--- | :--- | :--- |
| `S_IDLE` | Captures address, data and masks | `S_RD`, `S_WSEL` or `S_DONE` (out of window) |
| `S_RD` | Waits $n_{rd}$ cycles and captures the half word | `S_RD` or `S_DONE` |
| `S_WSEL` | Chooses the next half word with an enabled byte | `S_WSETUP` or `S_DONE` |
| `S_WSETUP`, `S_WLOW`, `S_WHIGH` | The three write phases | `S_WSEL` |
| `S_DONE` | `o_ready` high until `i_advance` | `S_IDLE` |

The waits are counted by the [latency_counter](../latency/latency_counter.md).

## 4. Integration

The board top does the `SRAM_DQ` tristate with `o_sram_dq_oe`. The [sram_model](sram_model.md) model plays the chip in simulation, inside the `sram_ctrl_tb` bench.

## 5. Verification

| Verification | Coverage |
| :--- | :--- |
| Entries `SramCtrl`, `SramCtrl100` and `SramCtrlSlow` of `tests/python/tests.json`, module `tests.python.unittests.ram.sram_ctrl`, on `sram_ctrl_tb` | Clocks to ready of a word and of a line per the formula; stores with the 16 byte masks and byte accumulation; lines with masks; random mix of accesses against a reference memory; window above and below the chip; ready held and data only on advance |
| Same entries | The [sram_model](sram_model.md) fails the simulation if the controller violates a time; 50 MHz, 100 MHz with 2 ns margin and `base_kib` of 64, and 250 MHz with 1 ns margin pass |
| Formal proof `formal/sram_ctrl/run.sh` | See [blocks](../formal/blocks.md): pins, bytes, phases, data and contract, in two cycle configurations, with mutants |

## 6. Reference

| Source | Content |
| :--- | :--- |
| `Plans/Multi-FPGA/05-FRENTES-E-TRILHAS.md`, task M.5.5 | SRAM controller with model and tests |
| `Plans/Multi-FPGA/01-ARQUITETURA.md`, sections 4 and 4.1 | `dispositivo/sram` backend, two accesses per word and double cycle when $T$ is smaller than the access time |
| `Plans/Multi-FPGA/placas/de2-115.md`, section 5.2 | Pins, 16-bit width and `inferido` times of the IS61WV102416BLL-10 |
| `chips/IS61WV102416BLL-10.yaml` | Catalog times, mirrored in [chip_timing_pkg](../rom/chip_timing_pkg.md) |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
