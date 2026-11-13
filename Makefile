SHELL := /bin/bash
GHDL  := ghdl
STD   := --std=08
WDIR  := build/ghdl

.PHONY: check test paths formal clean

# GHDL syntax check of the simulation models and of the memories (the SDRAM
# controller, its bridge, the caches and the chip models). The Quartus IPs (src/*/Cyclone-V/) need
# Intel's altera_mf library, which the toolchain image does not carry: they are
# analyzed by the hardware-top simulation in the Tests repository. The clock-domain
# synchronizer comes from the Common-Components repository, in src/common.
check:
	@mkdir -p $(WDIR)
	@$(GHDL) -a $(STD) --work=work --workdir=$(WDIR) $$(riscv-tools vhdl-sort src/common/src/utils_pkg.vhd src/common/src/config_pkg.vhd src/common/src/synchronizer.vhd src/*/SoC/*.vhd src/*/SoC/sim/*.vhd src/RAM/SoC/sdram/*.vhd src/tests/*.vhd src/RAM/FPGA/debug/sdram/sdram_dbg_master.vhd src/RAM/FPGA/debug/sdram/sdram_jtag_core.vhd)
	@python3 tests/python/check_chip_timing.py
	@echo "VHDL syntax check passed"

# Per-entity cocotb tests; `make test TEST=RAM` for one entry of tests/python/tests.json.
test:
	uv run python tests/python/runner.py $(TEST)

# Formal verification of the SDRAM arbiter (docs/FORMAL.md) and of the AXI4 master and slave bridges
# (docs/DCACHE_AXI.md), all at once: needs yosys, sby and the solver, in the toolchain image. FORMAL_ENGINE
# chooses the engine (yices, bitwuzla, boolector or abc-bmc3; default bitwuzla), and FORMAL_JOBS limits the
# proofs that run at the same time (default: the number of cores, up to 8). The results of the engine go to
# build/formal-results, for formal/aggregate.sh.
formal:
	bash formal/all.sh

# Every path the configuration lists exists.
paths:
	riscv-tools --root . check-paths --manifest paths.yaml
	riscv-tools --root . check-tree --kind memory

clean:
	rm -rf build
	find . -type f \( -name '*.vcd' -o -name '*.ghw' \) -print -delete
