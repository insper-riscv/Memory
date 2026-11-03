# Memory Debug

This guide describes how the host (the computer connected to the board) reaches the memories of the SoC over JTAG, to change the program between tests and to read the results after the run. Each memory has at most one path, and each block that has no path is listed with the reason.

## 1. Who has JTAG

| Memory | Has JTAG | Path | Read | Write | Use |
| :--- | :---: | :--- | :---: | :---: | :--- |
| BOOT_ROM ([boot_rom1port](../rom/boot_rom1port.md)) | no | Programmed once at compile time, with `boot_rom_init.mif` | no | no | Boot loader |
| FLASH ([flash_store1port](../rom/flash_store1port.md)) | yes | Quartus memory editor (section 2) | yes | yes | Changing the program between tests |
| Internal RAM ([ram1port](../ram/ram1port.md)) | yes | Quartus memory editor (section 2) | yes | yes | Zeroing the RAM and checking the result in designs without SDRAM |
| SDRAM ([sdram_ctrl](../ram/sdram_ctrl.md)) | yes | SDRAM debug port (section 3) | yes | yes | Checking the result and loading data |
| Caches ([dcache](../cache/dcache.md) and [icache](../cache/icache.md)) | no | They sit between the core and the memory and have no JTAG logic | no | no | Not applicable |
| Arbiters ([sdram_arbiter](../ram/sdram_arbiter.md) and [flash_arbiter](../cache/flash_arbiter.md)) | no | The `sdram_arbiter` carries the debug access as master B, and the `flash_arbiter` is on the path of no rewrite | no | no | Not applicable |

## 2. Memory editor (FLASH and internal RAM)

The FPGA memory IPs that declare `ENABLE_RUNTIME_MOD=YES` and an `INSTANCE_NAME` show up as instances of the Quartus In-System Memory Content Editor. The host opens a session with `quartus_stp`, chooses the instance by its index and reads or writes the content of the block. No pin of the IP takes part, because the editor reaches the block from inside.

| Operation | What it does |
| :--- | :--- |
| Full write | Overwrites the whole depth of an instance from a `.mif`, including several instances in one session |
| Single-word write | Replaces one word at an offset |
| Word read | Reads a range back |
| Dump | Saves the whole content of an instance to a `.mif` |

Two rules hold for the editor.

1. The index of each instance follows the instantiation order in the platform top, and the platform fixes the indexes in `config.yaml` (`quartus.rom_mem_instances` for the FLASH and `quartus.ram_mem_instance` for the internal RAM). An IP without `ENABLE_RUNTIME_MOD` takes no index.
2. The write goes straight into the memory block, without passing through a cache, an arbiter or the chip model. The hardware does not coordinate it with the core. The test flow does it between runs and restarts the core afterwards, by writing `fromhost` through the HTIF.

The FLASH of the internal memory design has two physical copies with the same content ([flash1port](../rom/flash1port.md) and [flash_mem1port](../rom/flash_mem1port.md)), and the write updates both in the same session. The host tools are the Tools modules [mem_edit](https://github.com/insper-riscv/Tools/blob/main/docs/en/modules/mem_edit.md), [rom_writer](https://github.com/insper-riscv/Tools/blob/main/docs/en/modules/rom_writer.md) and [ram_dump](https://github.com/insper-riscv/Tools/blob/main/docs/en/modules/ram_dump.md).

## 3. SDRAM debug port

The SDRAM sits outside the FPGA, so the memory editor does not reach it. The debug port is a second access to the controller, wired to the same arbiter as the core, and the host drives it through a Virtual JTAG instance.

| Stage | Block | Clock | Function |
| :---: | :--- | :--- | :--- |
| 1 | `sdram_jtag_shell` | JTAG | Shell with the Virtual JTAG instance, for the board only |
| 2 | [sdram_jtag_core](../ram/sdram_jtag_core.md) | JTAG | Shifts the 64-bit command, returns the state of the previous command and asks the master for the command |
| 3 | [sdram_dbg_master](../ram/sdram_dbg_master.md) | Controller | Runs the command, reading, writing or filling words |
| 4 | [sdram_arbiter](../ram/sdram_arbiter.md) | Controller | Serializes the debug access (master B) with those of the core |
| 5 | [sdram_ctrl](../ram/sdram_ctrl.md) | Controller | Accesses the chip |

The hand-off from stage 2 to stage 3 crosses the clock domains by toggling a signal, as the [memory contract](../contracts/contrato-de-memoria.md) describes. The data register has 64 bits, and the full format is in [sdram_jtag_core](../ram/sdram_jtag_core.md). The commands of the master are the following.

| Command | Effect |
| :---: | :--- |
| 0 | Nothing, only returns the state |
| 1 | Reads the word at the address |
| 2 | Writes the data to the word at the address, with the bytes chosen by the mask |
| 3 | Fills a number of consecutive words with the data |
| 4 | Sets the number of the fill, up to the whole SDRAM |
| 5 | Reads the word after the last one accessed |
| 6 | Writes to the word after the last one accessed |

The returned state carries, among other bits, bit 0 (`busy`, the previous command has not finished) and bit 1 (the controller did not answer). The address is a 32-bit word address counted from the base of the SDRAM. The host uses the Tools modules [sdram_debug](https://github.com/insper-riscv/Tools/blob/main/docs/en/modules/sdram_debug.md) and [ram_target](https://github.com/insper-riscv/Tools/blob/main/docs/en/modules/ram_target.md), and the platform selects this path with `quartus.ram_backend: sdram_debug`. The full protocol is in [SDRAM_DEBUG.md](../../SDRAM_DEBUG.md).

## 4. Coherence with the caches

The debug port reads and writes the SDRAM underneath the data cache. Two consequences hold for the host.

| Direction | Situation | How it is handled |
| :--- | :--- | :--- |
| The host reads what the program wrote | A write-back cache would keep the data in dirty lines, and the read would see the old memory | The data cache of the platform is write-through, so every store reaches the SDRAM before it completes |
| The host writes and the core reads later | The cache may hold an old line of the same address | The cache starts empty after reset, and the load is done before the core runs |

The first case was the defect described in [CACHE_HOST_COHERENCE.md](../../bugs/CACHE_HOST_COHERENCE.md).

## 5. Flow of a test

| Step | Action | Path |
| :---: | :--- | :--- |
| 1 | Write the program to the FLASH | Memory editor |
| 2 | Load the test data into the SDRAM, if any | SDRAM debug port |
| 3 | Restart the core | Write of `fromhost` through the HTIF |
| 4 | Wait for the end of the program | Read of `tohost` through the HTIF |
| 5 | Read the result | RAM dump, which in the SDRAM keeps only the words the golden names |
| 6 | Compare with the golden | `mem_validator` module |

`tohost` and `fromhost` live inside the RAM, so they use the same access path as the RAM, which is the memory editor in designs without SDRAM and the debug port in designs with SDRAM.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
