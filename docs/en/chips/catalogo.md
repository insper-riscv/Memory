# Memory chip catalog

## 1. Purpose

The `chips/` folder keeps one file per memory chip that some board carries. The controller that owns the timings lives in this repository, so the chip data lives here too, without depending on the repository that chooses the board. The Tools reads the folder with the `board_schema` module and checks it with the `check-boards` command.

## 2. Fields

| Field | Meaning |
| :--- | :--- |
| `chip` | Name, equal to the file name |
| `extends` | Optional, name of another chip whose fields this one inherits and overrides |
| `kind` | `sdram`, `sram`, `nor` or `serial_flash` |
| `organization` | `words` and `width`, and for the SDRAM also `banks`, `row_bits` and `col_bits` |
| `cas_latency` | Column latency of the SDRAM |
| `timing` | Timings with the datasheet names, in picoseconds when the name ends in `_ps` |
| `io_timing` | Setup, hold and access times of the pins, in nanoseconds, used in the `.sdc` |
| `sector_bytes`, `boot_sector_bytes` | Erase sector of the FLASH |
| `max_mhz` | Clock ceiling of the grade |
| `source` | `datasheet` or `inferido` |

## 3. Chips in the catalog

| Chip | Kind | Capacity | Origin of the values |
| :--- | :--- | ---: | :--- |
| `IS42S16320D-7` | `sdram` | 64 MiB | Datasheet; values of the DE0-CV controller |
| `IS42S16320B-7` | `sdram` | 64 MiB per chip | Inherits `IS42S16320D-7`; inferred |
| `IS42S16160B-7` | `sdram` | 32 MiB | Inferred from the `-7` series |
| `AS4C4M16SA-7BCN` | `sdram` | 8 MiB | Part and organization by the schematic; timings inferred from the `-7` series |
| `IS61WV102416BLL-10` | `sram` | 2 MiB | Inferred |
| `S29GL064N90` | `nor` | 8 MiB | Inferred; part suffix not verified |
| `EPCS64` | `serial_flash` | 8 MiB | Inferred |
| `W25Q16DV` | `serial_flash` | 2 MiB | Inferred; part confirmed by the schematic |

The SDRAM capacity of a board is the chip capacity times the number of chips in parallel.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
