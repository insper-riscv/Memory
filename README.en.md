# Memory

🌐 [Português](README.md) · [English](README.en.md)

Memories of the RISC-V RV32 SoC: the memory blocks that the core reads and writes. The core, the peripherals, the top levels that wire them together, and the test programs live in other repositories of the [insper-riscv](https://github.com/insper-riscv) organization.

## 1. Documentation

- [AUTHORS.en.md](AUTHORS.en.md): authors with commits in the repository, with name and GitHub account.
- [CONTRIBUTING.en.md](CONTRIBUTING.en.md): mandatory contribution rules, VHDL-2008 standard, naming, headers, Python standards, and verification before opening a Pull Request.
- [CITATION.cff](CITATION.cff): software citation metadata.
- [contracts/02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/en/contracts/02-barramento-e-memoria.md): bus and memory protocol shared by every family.

## 2. Repository Structure

| Path | Contents |
| :--- | :--- |
| `sim/` | Simulation models in plain VHDL with arrays that cocotb can read (`RAM_simulation`, `ROM_simulation`) |
| `ips/` | Quartus IPs (`altsyncram`) of the board: `BOOT_ROM1PORT` (2 KB, programmed once), `FLASH1PORT` and `FLASH_MEM1PORT` (30 KB, the two physical copies of the FLASH, rewritten over JTAG for each test), and `RAM1PORT` (160 KB). They also simulate in GHDL through Intel's `altera_mf` models |
| `tests/python/` | Per-entity cocotb tests of the simulation models and the catalog (`tests.json`) that drives them |

## 3. Memory Families

Three families share a single slave interface: simulation models, FPGA internal IPs, and external memory (flash and RAM outside the FPGA, with multi-cycle controllers), the latter planned for the `external/` directory. Every internal memory answers in one cycle; the `ready` signal joins the interface only with external memory.

The IP sizes must match the platform memory map (`Tests/platforms/internal-mem.yaml`), checked by `riscv-tools check-memory-map`.

## 4. Verification and Running

```bash
git clone --recurse-submodules https://github.com/insper-riscv/Memory.git
cd Memory
uv sync

make check   # VHDL syntax check of the simulation models (GHDL)
make test    # Per-entity cocotb tests (make test TEST=RAM for one target)
make paths   # Existence of every path listed in the configuration
```

The tools (GHDL and uv) come from the `infra-toolchain` image of the [Infra](https://github.com/insper-riscv/Infra) repository, where continuous integration runs. The IPs are not analyzed here because they need Intel's `altera_mf` library, which the image does not carry; the hardware-top simulation in [Tests](https://github.com/insper-riscv/Tests) covers them.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](LICENSE).
