# Memory

The memories of the RV32 SoC. One job: the memory blocks the core reads and
writes. The core, the peripherals, the top levels that wire them and the test
programs live in other repositories of
[insper-riscv](https://github.com/insper-riscv).

## Layout

| Path | What |
| :--- | :--- |
| `sim/` | simulation models: plain VHDL arrays that cocotb can read (`RAM_simulation`, `ROM_simulation`) |
| `ips/` | the Quartus IPs of the board (`altsyncram`): `BOOT_ROM1PORT` (2 KB, programmed once), `FLASH1PORT` and `FLASH_MEM1PORT` (30 KB, the two physical copies of the FLASH, rewritten over JTAG per test), `RAM1PORT` (160 KB). They also simulate in GHDL through Intel's `altera_mf` models |
| `tests/python/` | per-entity cocotb tests of the simulation models and the catalog (`tests.json`) that drives them |

The third family, **external memory** (flash and RAM outside the FPGA, with
multi-cycle controllers), does not exist yet; it will live in `external/`. All
three families share one slave interface (see the bus and memory interface in
[Core's `docs/contracts/02-barramento-e-memoria.md`](https://github.com/insper-riscv/Core/blob/main/docs/contracts/02-barramento-e-memoria.md)):
today every memory answers in one cycle, and `ready` joins the interface only
with external memory.

The sizes of the IPs must agree with the platform's memory map
(`Tests/platforms/internal-mem.yaml`, checked by `riscv-tools check-memory-map`).

## Use

```bash
git clone --recurse-submodules https://github.com/insper-riscv/Memory.git
cd Memory
uv sync
make check   # GHDL syntax check of the simulation models
make test    # per-entity cocotb tests (TEST=RAM for one)
make paths   # every path the configuration lists exists
```

The tools (GHDL, uv) come from the `infra-toolchain` image of
[Infra](https://github.com/insper-riscv/Infra); CI runs there. The IPs are not
analyzed here (they need Intel's `altera_mf` library, which the image does not
carry): the hardware-top simulation in [Tests](https://github.com/insper-riscv/Tests)
does.

## Where this came from

`sim/` and `ips/` moved from `insper-riscv/RV32` (`src/RAM_simulation.vhd`,
`src/ROM_simulation.vhd`, `tests/FPGA/core/quartus/ips`) and `tests/python` from
`insper-riscv/Tests`, with their history and authorship (`git filter-repo`). The
outdated copies in `src/` (`RAM1PORT`, `ROM1PORT`, `ROM_IP`: 4096 and 8192 words,
not the board's sizes) were archived as the tag `archive/stale-memory-ips` of
RV32. The pre-move state is the tag `pre-refactor` in each repository.

## License

Apache License 2.0, see [LICENSE](LICENSE).
