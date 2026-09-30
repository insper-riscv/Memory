# `tests/python`: VHDL unit tests that need the simulation memories (cocotb + GHDL)

The per-entity tests of the core itself (ALU, register file, control, hazard and
forwarding units, extenders, store manager, bubble mux, instruction decoder)
moved to [Core](https://github.com/insper-riscv/Core) with their history. What
stays here needs the simulation memories or the clock generator: `RAM`, `ROM`,
`clk_gen_3way` and the whole-core instruction tests (`unittests/instructions`).
Paths in `tests.json` are relative to this repository's root: `../Core/...` for
the core, `../src/...` for RV32IM's memories and tops.


Cocotb testbenches that exercise individual VHDL entities (`ALU`,
`RegFile`, `ROM_simulation`, control/hazard/forwarding units, etc.)
directly, one file per entity. This is a separate, older suite from
the `asm`/`c` tests the rest of this repo uses: it doesn't go through
`riscv-tools`' compiler/linker/`config.yaml` at all, it just elaborates
a handful of `.vhd` sources per test and drives the entity's ports
straight from Python.

## Structure

```
tests/python/
├── runner.py                    # catalog loader + cocotb/GHDL driver
├── tests.json                   # catalog: name -> {toplevel, sources, test_module, ...}
├── unittests/
│   ├── entities/                # one file per VHDL entity (ALU.py, RAM.py, ...)
│   │   └── data/                # fixture files an entity test's generics point at (e.g. testROM.hex)
│   └── instructions/            # raw hand-assembled instruction-sequence tests (see "Known issue" below)
│       └── codes/                # the .hex images those tests load
└── sim_build/                   # generated: <group>/<name>/{waves.ghw, ...} per test
```

## Running

```bash
uv run python tests/python/runner.py            # every entry in tests.json (skips "skip": true ones)
uv run python tests/python/runner.py ALU        # one entry, by its tests.json key
```

`SIM` picks the simulator GHDL/cocotb uses (defaults to `ghdl`, matching
the rest of this repo's `sim` suite). This is the same command
`.github/workflows/sim.yml` runs in CI.

## The catalog (`tests.json`)

Each entry is a test name (used as the CLI argument above) mapping to:

| Field | Meaning |
| :--- | :--- |
| `toplevel` | The VHDL entity to elaborate (lowercase, matching the `.vhd`'s own entity name) |
| `sources` | Every `.vhd` file the entity needs, as paths relative to this repo's parent (`RV32IM`), e.g. `../Core/I/ALU.vhd` |
| `test_module` | Dotted Python path to the test file, e.g. `tests.python.unittests.entities.ALU` |
| `parameters` | Optional: VHDL generics to pass (e.g. `ROM_FILE` for an entity that loads a memory image) |
| `skip` / `skip_reason` | Optional: excluded from the `all` sweep with the reason printed, but still runs if invoked by name explicitly |

`runner.py` infers the output group (`entities`/`instructions`/`misc`)
from whether `test_module` contains `.entities.` or `.instructions.`,
and uses that to name the test's `sim_build/` subfolder.

## Writing a new entity test

1. Create `tests/python/unittests/entities/MyEntity.py`:

   ```python
   import cocotb
   from cocotb.triggers import Timer

   @cocotb.test()
   async def test_basic(dut):
       dut.my_input.value = 1
       await Timer(1, units="ns")
       assert int(dut.my_output.value) == 1
   ```

   Assertions are plain `assert`; any exception raised inside a
   `@cocotb.test()` marks it FAIL under cocotb 2.0, no special
   exception class needed.

2. Add it to `tests.json`:

   ```json
   "MyEntity": {
       "toplevel": "myentity",
       "sources": ["../src/MyEntity.vhd"],
       "test_module": "tests.python.unittests.entities.MyEntity"
   }
   ```

3. Run it on its own first: `uv run python tests/python/runner.py MyEntity`.

## Known issue: the 10 `instructions` tests are all skipped

The `instructions` group (`one`, `two`, `three`, `four`, `five`, `six`,
`MUL`, `FWD`, `LOAD_USE`, `MEXT`) predates the BOOT_ROM+FLASH memory
redesign and assumes code starts executing at address `0` with no boot
delay, which is no longer how the core resets. Fixing this needs a real
rewrite (a `BOOT_ROM_FILE` generic, `.hex` images re-padded to
`FLASH_BASE`, and corrected cycle counts), not a parameter tweak, so
these 10 entries carry `"skip": true` for now; see
[PER_ENTITY_TESTS_CI_BREAKAGE.md](../../docs/bugs/PER_ENTITY_TESTS_CI_BREAKAGE.md)
for the full investigation. The 13 `entities` tests are unaffected and
run normally.

## Viewing waveforms (GTKWave)

Every run writes `waves.ghw` into that test's `sim_build/<group>/<name>/`:

```bash
gtkwave tests/python/sim_build/entities/ALU/waves.ghw
```

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../LICENSE).
