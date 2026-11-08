# sram_model

Simulation model of the 16-bit asynchronous SRAM, which checks the datasheet times and fails the simulation when [sram_ctrl](sram_ctrl.md) violates one.

## 1. Role of the component in the SoC

The model plays the IS61WV102416BLL-10 of the DE2-115 on the controller pins: 1M 16-bit words, asynchronous read by address and write driven by `WE#`, with `LB#` and `UB#` choosing the low and high byte. The content starts at zero. The model is not synthesizable, because it measures simulation time. The `sram_ctrl_tb` bench connects the controller to the model and does the data bus tristate; the model receives only what the controller drives, to catch a contention.

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `size_bytes` | `positive` | 2097152 | Chip size, power of two from 16 bytes to 2 MB |
| `t_aa_ns`, `t_rc_ns` | `natural` | 10, 10 | Address access and read cycle |
| `t_wc_ns`, `t_sce_ns`, `t_aw_ns` | `natural` | 10, 8, 8 | Write cycle, `CE#` and address to the end of the write |
| `t_pwe_ns`, `t_sd_ns` | `natural` | 8, 6 | `WE#` pulse and data before the rise |
| `t_ha_ns`, `t_hd_ns` | `natural` | 0, 0 | Address and data held after the rise |
| `abort_on_violation` | `boolean` | `true` | A violation aborts the simulation; false only warns |

### 2.2. Ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_sram_addr` | input | 20 | 16-bit word address |
| `i_sram_dq` | input | 16 | Data driven by the controller, `'Z'` when released |
| `o_sram_dq` | output | 16 | Data driven by the chip, `'Z'` in the disabled byte lanes |
| `i_sram_ce_n`, `i_sram_oe_n`, `i_sram_we_n`, `i_sram_lb_n`, `i_sram_ub_n` | input | 1 | Controls, active at `'0'` |
| `o_violation` | output | 1 | 1 ns pulse at each violation |

## 3. Behavior

On a read, with `CE#` and `OE#` low and `WE#` high, `o_sram_dq` is `'X'` until $\max(t_{addr}, t_{ce}, t_{oe}) + t_{aa}$ and then the word at the address, with `'Z'` in the lane whose `LB#` or `UB#` is high. On the rise of `WE#` with `CE#` low, the chip writes only the bytes that `LB#` and `UB#` enabled at the fall.

| Violation | Rule |
| :--- | :--- |
| Read ended too early | Change of address, `CE#`, `OE#` or `WE#` before `t_aa_ns` |
| Address cycle | Address change in less than `t_rc_ns` during a read or a write |
| `WE#` pulse | Smaller than `t_pwe_ns` |
| Write setup | Address stable for less than `t_aw_ns`, `CE#` low for less than `t_sce_ns` or data stable for less than `t_sd_ns` before the rise |
| Write cycle | From one `WE#` fall to the next, less than `t_wc_ns` |
| Hold | Address or data changing before `t_ha_ns` or `t_hd_ns` after the rise, or the address changing with `WE#` low |
| Data | Undefined at the `WE#` rise, or `LB#`/`UB#` changing during the pulse |
| Contention | The controller driving the data while the chip drives the read |

## 4. Verification

| Entry of `tests/python/tests.json` | cocotb module | Coverage |
| :--- | :--- | :--- |
| `SramModel` | `tests.python.unittests.ram.sram_model` | Write and read at the datasheet times with no violation, byte lanes, and the cut-short read, the short pulse, the late data and the contention pulsing `o_violation` |
| `SramCtrl`, `SramCtrl100`, `SramCtrlSlow` | `tests.python.unittests.ram.sram_ctrl` | The model with `abort_on_violation` true inside `sram_ctrl_tb`: a test that finishes proves the controller respected the times |

## 5. Reference

| Source | Content |
| :--- | :--- |
| `Plans/Multi-FPGA/05-FRENTES-E-TRILHAS.md`, task M.5.5 | SRAM controller with model and tests |
| `Plans/Multi-FPGA/placas/de2-115.md`, section 5.2 | `inferido` times of the IS61WV102416BLL-10 |
| `chips/IS61WV102416BLL-10.yaml` | Catalog times, mirrored in [chip_timing_pkg](../rom/chip_timing_pkg.md) |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
