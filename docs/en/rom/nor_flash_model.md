# nor_flash_model

Simulation model of the 8-bit parallel NOR FLASH chip, which checks the datasheet times and fails the simulation when [nor_flash_ctrl](nor_flash_ctrl.md) violates one.

## 1. Role of the component in the SoC

The model plays the S29GL064N of the DE2-115 on the controller pins: asynchronous read with random and page access, and the chip command write cycles in byte mode, with the internal operation lasting `t_prog_ns` or `t_erase_ns` and the `RY` pin low while it lasts. The `nor_flash_ctrl_tb` bench connects the controller to the model and does the data bus tristate, as the board top does.

The model is not synthesizable, because it measures simulation time. The controller counts cycles and the model measures nanoseconds, so a conversion error in the controller shows up as a violation.

## 2. Interface

### 2.1. Generics

The times are in ns, and the defaults come from [chip_timing_pkg](chip_timing_pkg.md).

| Generic | Type | Default | Meaning |
| :--- | :--- | ---: | :--- |
| `size_bytes` | `positive` | 8388608 | Chip size, power of two from 8 KB to 8 MB |
| `sector_bytes` | `positive` | 65536 | Erase sector |
| `t_acc_ns`, `t_pacc_ns`, `t_oe_ns` | `natural` | 90, 25, 35 | Random and `CE#` access, page access and `OE#` access |
| `t_wc_ns`, `t_wp_ns`, `t_wph_ns` | `natural` | 90, 35, 30 | Cycle, pulse and `WE#` high |
| `t_ds_ns`, `t_ah_ns` | `natural` | 45, 45 | Data before and address after the pulse |
| `t_busy_ns`, `t_rp_ns`, `t_rh_ns` | `natural` | 90, 500, 50 | `RY` fall, `RESET#` pulse and wait |
| `t_prog_ns`, `t_erase_ns` | `natural` | 60000, 500000000 | Duration of a byte program and of a sector erase |
| `erased_init` | `boolean` | `false` | Initial content all `0xFF`, instead of the deterministic pattern |
| `abort_on_violation` | `boolean` | `true` | A violation aborts the simulation; false only warns |

### 2.2. Ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_fl_addr` | input | 23 | Byte address |
| `i_fl_dq` | input | 8 | Data driven by the controller, `'Z'` when released |
| `o_fl_dq` | output | 8 | Data driven by the chip, `'Z'` when released |
| `i_fl_ce_n`, `i_fl_oe_n`, `i_fl_we_n`, `i_fl_rst_n`, `i_fl_wp_n` | input | 1 | Controls, active at `'0'` |
| `o_fl_ry` | output | 1 | Ready (`'1'`) or busy (`'0'`) |
| `o_violation` | output | 1 | 1 ns pulse at each violation |

## 3. Behavior

### 3.1. Read

With $t_{addr}$, $t_{ce}$ and $t_{oe}$ the instants of the last address change and of the last `CE#` and `OE#` falls, the data becomes valid at

$$ t_{valid} = \max(t_{addr} + t_{a},\ t_{ce} + t_{acc},\ t_{oe} + t_{oe\_ns}) $$

with $t_a$ equal to `t_acc_ns` when the address page (bits 22 to 4) changed or `CE#` just fell, and to `t_pacc_ns` inside the page. Before that `o_fl_dq` is `'X'`, and afterwards it is the content byte. With `CE#` or `OE#` high, or `WE#` low, the chip releases the bus.

### 3.2. Commands

The write cycles are decoded in byte mode, with the unlock addresses `0xAAA` and `0x555` compared on the low 12 bits.

| Sequence (address, data) | Effect |
| :--- | :--- |
| `(AAA,AA)` `(555,55)` `(AAA,A0)` `(PA,PD)` | Programs the byte: the new content is the bitwise AND of the content with `PD`, after `t_prog_ns` |
| `(AAA,AA)` `(555,55)` `(AAA,80)` `(AAA,AA)` `(555,55)` `(SA,30)` | Erases the sector of `SA`, after `t_erase_ns` |
| Any cycle with data `0xF0` at rest | Ignored |

`RY` falls `t_busy_ns` after the `WE#` rise of the last cycle and rises at the end of the operation. A read during the operation returns the status: in bit 7, the complement of bit 7 of the programmed data (program) or `'0'` (erase), and zero in the others; the toggle bit 6 is not modeled. `RESET#` low aborts the operation and leaves the content as it was. `WP#` low ignores program and erase in the last sector.

### 3.3. Violations

Each line below makes `o_violation` pulse and, with `abort_on_violation` true, fails the simulation.

| Violation | Rule |
| :--- | :--- |
| Read ended too early | Address change, `CE#` or `OE#` high before $t_{valid}$ |
| `WE#` pulse | Width smaller than `t_wp_ns` |
| `WE#` high | Less than `t_wph_ns` since the previous rise |
| Write cycle | From one `WE#` fall to the next, less than `t_wc_ns` |
| Data before the rise | Stable for less than `t_ds_ns`, or undefined |
| Address after the fall | Changes before `t_ah_ns` |
| Usage | `WE#` without `CE#`, `WE#` and `OE#` low together, write out of sequence or during the operation |
| `RESET#` | Pulse smaller than `t_rp_ns`, or `CE#` low before `t_rh_ns` after the rise |

### 3.4. Initial content

The byte at address $a$ starts as byte 3 of the `pattern_word` of [sim_util_pkg](../sim/sim_util_pkg.md), $\left\lfloor ((a \cdot \texttt{0x9E3779B1}) \bmod 2^{32}) \oplus \texttt{0x5A5A1234} \right\rfloor \gg 24$, which the tests reproduce, or at `0xFF` with `erased_init`.

## 4. Verification

| Entry of `tests/python/tests.json` | cocotb module | Coverage |
| :--- | :--- | :--- |
| `NorFlashModel` | `tests.python.unittests.rom.nor_flash_model` | Random and page reads at the exact times with no violation, `'X'` data before the page time, program and erase with `RY` and status, and each violation of section 3.3 pulsing `o_violation` |
| `NorFlashCtrl`, `NorFlashCtrl100`, `NorFlashCtrlMargin` | `tests.python.unittests.rom.nor_flash_ctrl` | The model with `abort_on_violation` true inside the `nor_flash_ctrl_tb` bench: a test that finishes proves the controller respected every time |

## 5. Reference

| Source | Content |
| :--- | :--- |
| `Plans/Multi-FPGA/05-FRENTES-E-TRILHAS.md`, task M.5.4 | Chip model that reads the catalog times and fails if the controller violates one |
| `Plans/Multi-FPGA/placas/de2-115.md`, section 5.3 | `inferido` times of the S29GL064N90 |
| `chips/S29GL064N90.yaml` | Catalog times, mirrored in [chip_timing_pkg](chip_timing_pkg.md) |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
