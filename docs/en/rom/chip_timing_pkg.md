# chip_timing_pkg

Datasheet times of the device memory chips (NOR FLASH and asynchronous SRAM) and the conversion of a time into clock cycles, read by the controllers and by the chip models.

## 1. Role of the component in the SoC

A device controller counts, in cycles of the memory clock, every time the chip demands. The package gathers the times in one place, in nanoseconds, and is the default of the generics of [nor_flash_ctrl](nor_flash_ctrl.md), [nor_flash_model](nor_flash_model.md), [sram_ctrl](../ram/sram_ctrl.md) and [sram_model](../ram/sram_model.md). The controller and the model of one chip therefore start from the same numbers, and the model measures in simulation time what the controller counted in cycles.

The source of the values is the [chip catalog](../chips/catalogo.md), in `chips/S29GL064N90.yaml` and `chips/IS61WV102416BLL-10.yaml`. The package is the form VHDL reads, and `tests/python/check_chip_timing.py`, called by `make check`, fails when a constant differs from the catalog. Whoever uses another chip changes the generic value in the instance and does not edit a constant inside an entity.

## 2. Times

All values are in ns and hold for the DE2-115. None was read in a datasheet: the parts and the times are `inferido` in the board sheet, which deduces them from memory of the datasheets and from forums, and the schematic and the datasheet folder of the board CD confirm them.

### 2.1. NOR FLASH S29GL064N90 (byte mode)

| Constant | Value | Meaning |
| :--- | ---: | :--- |
| `NOR_T_ACC_NS` | 90 | Random and CE# access |
| `NOR_T_PACC_NS` | 25 | Access inside the 16-byte page |
| `NOR_T_OE_NS` | 35 | OE# low to data |
| `NOR_T_WC_NS` | 90 | Write cycle |
| `NOR_T_WP_NS` | 35 | WE# pulse width |
| `NOR_T_WPH_NS` | 30 | WE# high between two pulses |
| `NOR_T_DS_NS` | 45 | Data stable before WE# rises |
| `NOR_T_AH_NS` | 45 | Address stable after WE# falls |
| `NOR_T_BUSY_NS` | 90 | WE# rise to RY# fall |
| `NOR_T_RP_NS` | 500 | RESET# pulse width |
| `NOR_T_RH_NS` | 50 | RESET# rise to first access |
| `NOR_T_PROG_NS` | 60000 | Byte program, typical |
| `NOR_T_ERASE_NS` | 500000000 | Erase of a 64 KB sector, typical |

### 2.2. SRAM IS61WV102416BLL-10

| Constant | Value | Meaning |
| :--- | ---: | :--- |
| `SRAM_T_AA_NS` | 10 | Address access |
| `SRAM_T_RC_NS` | 10 | Read cycle |
| `SRAM_T_WC_NS` | 10 | Write cycle |
| `SRAM_T_SCE_NS` | 8 | CE# low to end of write |
| `SRAM_T_AW_NS` | 8 | Address valid to end of write |
| `SRAM_T_PWE_NS` | 8 | WE# pulse width |
| `SRAM_T_SD_NS` | 6 | Data valid before WE# rises |
| `SRAM_T_HA_NS` | 0 | Address held after WE# rises |
| `SRAM_T_HD_NS` | 0 | Data held after WE# rises |

## 3. Conversion into cycles

`cycles_of(t_ns, period_ns, margin_ns)` returns the number of cycles that cover the time $t$ plus the pin and board margin $m$, at least one:

$$ n = \max\left(1, \left\lceil \frac{t + m}{T} \right\rceil\right) $$

`max_natural(a, b)` returns the larger of two naturals, because Quartus Lite does not carry the VHDL-2008 `maximum` function for `natural`.

## 4. Reference

| Source | Content |
| :--- | :--- |
| `Plans/Multi-FPGA/placas/de2-115.md`, sections 5.2 and 5.3 | Parts, widths, addresses and times of the SRAM and of the FLASH, each marked `confirmado` or `inferido` |
| `chips/*.yaml` | `timing` field of each chip, with the names `access_ns`, `page_access_ns`, `write_cycle_ns` and the others |
| `Plans/Multi-FPGA/01-ARQUITETURA.md`, section 4 | The latency of a device backend, $n_{cycles} = \lceil t_{chip} / T \rceil$ |
| Spansion S29GL064N90 and ISSI IS61WV102416BLL-10 datasheets | Origin of the values, to check in the `DE2_115_datasheets` folder of the board CD |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
