# `tests/python`: per-entity VHDL unit tests (cocotb + GHDL)

Cocotb testbenches for the simulation models of this repository
(`RAM_simulation`, `ROM_simulation`). They drive the entity's ports straight
from Python, without `riscv-tools`' compiler or simulation flow.

## Structure

```
tests/python/
├── runner.py                    # catalog loader + cocotb/GHDL driver
├── tests.json                   # catalog: name -> {toplevel, sources, test_module, ...}
├── unittests/{cache,ram,rom,barramento}/  # one file per entity or per simulation model
│                                          # (sdram_ctrl, sdram_arbiter, sdram_cpu_bridge, sdram_dbg_master and
│                                          # sdram_jtag_core each have a file of their own)
│   └── rom/data/                # fixtures a test reads (e.g. testROM.hex)
├── ../vhdl/                     # testbench wrappers a cocotb test needs (e.g. sdram_ctrl_tb: controller + chip model)
└── sim_build/                   # generated: <group>/<name>/{waves.ghw, ...} per test
```

## Running

```bash
make test                # every entry in tests.json (skips "skip": true ones)
make test TEST=RAM       # one entry, by its tests.json key
```

`SIM` picks the simulator (defaults to `ghdl`).

## The catalog (`tests.json`)

| Field | Meaning |
| :--- | :--- |
| `toplevel` | the VHDL entity under test |
| `sources` | its source files, relative to the root of this repository, in dependency order |
| `test_module` | the Python module with the cocotb tests |
| `skip`, `skip_reason` | optional: `true` leaves the entry out of a full run |
| `parameters` | optional: generics passed to the simulator (paths are resolved against the root) |
