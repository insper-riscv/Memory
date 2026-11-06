# Memory

🌐 [Português](README.md) · [English](README.en.md)

Memories of the RISC-V RV32 SoC: the memory blocks that the core reads and writes. The core, the peripherals, the top levels that wire them together, and the test programs live in other repositories of the [insper-riscv](https://github.com/insper-riscv) organization.

## 1. Documentation

- [AUTHORS.en.md](AUTHORS.en.md): authors with commits in the repository, with name and GitHub account.
- [CONTRIBUTING.en.md](CONTRIBUTING.en.md): mandatory contribution rules, VHDL-2008 standard, naming, headers, Python standards, and verification before opening a Pull Request.
- [CITATION.cff](CITATION.cff): software citation metadata.
- [contracts/02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/en/contracts/02-barramento-e-memoria.md): bus and memory protocol shared by every family.
- [contrato-de-memoria.md](docs/en/contracts/contrato-de-memoria.md): memory contract (pins, timing, clock and a word of a width different from the core one).
- Per-component documentation, one per block, in Portuguese (`docs/pt-br/`) and in English (`docs/en/`), grouped by type.
  - `docs/en/cache/` (caches and region routing): [dcache](docs/en/cache/dcache.md), [icache](docs/en/cache/icache.md), [ifetch_bridge](docs/en/cache/ifetch_bridge.md), [mem_region_router](docs/en/cache/mem_region_router.md), [flash_arbiter](docs/en/cache/flash_arbiter.md).
  - `docs/en/block_ram/` (FPGA block memory): [block_ram](docs/en/block_ram/block_ram.md).
  - `docs/en/ram/` (SDRAM, external RAM and internal RAM): [sdram_ctrl](docs/en/ram/sdram_ctrl.md), [sdram_arbiter](docs/en/ram/sdram_arbiter.md), [sdram_cpu_bridge](docs/en/ram/sdram_cpu_bridge.md), [sdram_pkg](docs/en/ram/sdram_pkg.md), [sdram_model](docs/en/ram/sdram_model.md), [sdram_bist](docs/en/ram/sdram_bist.md), [sdram_dbg_master](docs/en/ram/sdram_dbg_master.md), [sdram_jtag_core](docs/en/ram/sdram_jtag_core.md), [ram_chip](docs/en/ram/ram_chip.md), [ram](docs/en/ram/ram.md), [ram_simulation](docs/en/ram/ram_simulation.md), [onchip_ram_port](docs/en/ram/onchip_ram_port.md).
  - `docs/en/rom/` (FLASH, BOOT_MEMORY and the ROM model): [flash_chip](docs/en/rom/flash_chip.md), [flash_cmd_port](docs/en/rom/flash_cmd_port.md), [boot_memory](docs/en/rom/boot_memory.md), [flash](docs/en/rom/flash.md), [flash_loader](docs/en/rom/flash_loader.md), [flash_jtag_core](docs/en/rom/flash_jtag_core.md), [flash_simulation](docs/en/rom/flash_simulation.md), [flash_store](docs/en/rom/flash_store.md), [rom_simulation](docs/en/rom/rom_simulation.md).
  - `docs/en/latency/` (latency counting of the emulated models): [latency_counter](docs/en/latency/latency_counter.md).
  - `docs/en/barramento/` (AXI4 bridges): [axi_master_bridge](docs/en/barramento/axi_master_bridge.md), [axi_slave_word_bridge](docs/en/barramento/axi_slave_word_bridge.md).
- Design documents (decisions, protocol, verification and fixed defects) in `docs/en/barramento/` ([dcache_axi](docs/en/barramento/dcache_axi.md), [dcache_axi_decisions](docs/en/barramento/dcache_axi_decisions.md)), in `docs/en/ram/` ([sdram_debug](docs/en/ram/sdram_debug.md), [sdram_line](docs/en/ram/sdram_line.md), [sdram_subword_read](docs/en/ram/sdram_subword_read.md), [sdram_timings](docs/en/ram/sdram_timings.md), [sdram_clock_crossing](docs/en/ram/sdram_clock_crossing.md)), in `docs/en/formal/` ([formal](docs/en/formal/formal.md), [blocks](docs/en/formal/blocks.md)) and in `docs/en/bugs/` (one document per defect). The per-component documents link to them. The external interconnect and the UART over JTAG are documented in Insper-RISC-V and in Peripherals.

## 2. Repository Structure

| Path | Contents |
| :--- | :--- |
| `src/common/` | Common-Components submodule, edited only at its source |
| `src/cache/SoC/` | The instruction cache, the cacheless instruction fetch bridge and the data cache of the SDRAM, the region router, the FLASH arbiter, the FLASH chip model and its command port (`flash_cmd_port`, which erases, programs and protects); `sim/` holds the cache test systems |
| `src/RAM/SoC/` | The controller of the board's SDRAM (32M x 16, 64 MB), the bridge between the core clock and the controller clock, an arbiter that shares the SDRAM between the core and the debug master ([docs/en/ram/sdram_debug.md](docs/en/ram/sdram_debug.md)), and a package with the chip's timings. `src/RAM/SoC/sim/` holds the chip model, which fails the simulation when the controller breaks a rule of the chip, and the tops that wire it to the controller. The `onchip_ram_port` puts the internal FPGA RAM block behind the same line contract as the external memory, so an internal RAM can sit behind a cache ([docs/en/ram/onchip_ram_port.md](docs/en/ram/onchip_ram_port.md)) |
| `src/block_ram/altera/` | `block_ram`, the single instance of Intel's `altsyncram`, with one or two ports, board only |
| `src/latency/SoC/` | Latency counting machine (`latency_counter`) shared by the FLASH chip model, the external RAM model and the internal RAM adapter |
| `src/RAM/FPGA/Cyclone-V/` | The `RAM` Quartus IP, board only |
| `src/RAM/FPGA/debug/sdram/` | The Virtual JTAG core (`sdram_jtag_core`) and the debug master (`sdram_dbg_master`) that let a host read and write the SDRAM through JTAG, board only |
| `src/ROM/SoC/` | Simulation model of the ROM in plain VHDL with an array that cocotb can read (`rom_simulation`), model of the dual-port FLASH (`flash_simulation`), JTAG loader of the FLASH (`flash_loader`, with the JTAG port `flash_jtag_core`) and, in `sim/`, the top that wires them (`flash_system`) |
| `src/ROM/Cyclone-V/` | Quartus IPs of the ROM, instances of `block_ram`: `BOOT_MEMORY` (programmed once), `FLASH` (the single dual-port copy of the internal FLASH, rewritten by the JTAG loader for each test) and `FLASH_STORE`, plus the Virtual JTAG shell of the loader (`flash_jtag_shell`, board only). They also simulate in GHDL through Intel's `altera_mf` models |
| `src/barramento/SoC/` | The two generic AXI4 bridges, which depend only on the memory contract of the core: the master (`axi_master_bridge`, from the core to an AXI4 slave) and the word slave (`axi_slave_word_bridge`, AXI4 in front of a memory), with the test system in `sim/`. The external interconnect, the AXI4 router and the peripheral bank decode the platform map and know the peripherals, so they live in Insper-RISC-V, in `src/interconnect/` |
| `src/tests/` | The SDRAM self test (`teste_sdram`), which drives the controller alone in quick, patterns, whole-chip sweep and random modes, and the system that wires it to the chip model (`teste_sdram_system`) |
| `tests/python/` | Per-entity cocotb tests, in `unittests/{cache,ram,rom,barramento}`, and the catalog (`tests.json`) that drives them |
| `tests/vhdl/` | Test bench of the SDRAM controller (`sdram_ctrl_tb`) |
| `formal/` | SystemVerilog properties and proof scripts, one folder per block, and the engine aggregator ([documentation](docs/en/formal/formal.md)) |
| `docs/pt-br/`, `docs/en/` | One document per component, grouped in `cache`, `ram`, `rom`, and `barramento`, plus `contracts`, `formal`, and `bugs` |

## 3. Memory Families

Three families share a single slave interface: simulation models, FPGA internal IPs, and external memory (RAM outside the FPGA, with multi-cycle controllers), the latter in `src/RAM/SoC/`, where the SDRAM is the first. Every internal memory answers in one cycle; the `ready` signal joins the interface only with external memory. The chip timings in `src/RAM/SoC/sdram/sdram_pkg.vhd` are those of the chip's datasheet, listed in `docs/en/ram/sdram_timings.md`.

The IP sizes must match the platform memory map (`src/simulation/internal-mem/platform.yaml` of [Insper-RISC-V](https://github.com/insper-riscv/Insper-RISC-V)), checked there by `make memory-map`.

## 4. Verification and Execution

### 4.1. Local execution

```bash
git clone --recurse-submodules https://github.com/insper-riscv/Memory.git
cd Memory
uv sync

make check   # VHDL syntax check of the models and of the memories (GHDL)
make test    # Per-entity cocotb tests (make test TEST=RAM for one target)
make paths   # Paths of paths.yaml and the repository tree (riscv-tools check-tree)
make formal  # Formal proofs (SymbiYosys) with the engine of FORMAL_ENGINE (bitwuzla by default)
```

The IPs under `Cyclone-V/` are not analyzed by `make check` because they need Intel's `altera_mf` library, which the image does not carry; the hardware-top simulation in [Insper-RISC-V](https://github.com/insper-riscv/Insper-RISC-V) covers them.

### 4.2. Execution via Docker

The `ghcr.io/insper-riscv/ci-vhdl:latest` image published by [insper-riscv/Infra](https://github.com/insper-riscv/Infra) includes GHDL (LLVM backend), Yosys, SymbiYosys, the Yices, Bitwuzla and Boolector solvers, `uv`, Python 3.14, and cocotb pre-installed:

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace ghcr.io/insper-riscv/ci-vhdl:latest \
  bash -c "uv sync && make check && make test && make paths && make formal"
```

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](LICENSE).
