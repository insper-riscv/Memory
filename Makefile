SHELL := /bin/bash
GHDL  := ghdl
STD   := --std=08
WDIR  := build/ghdl

.PHONY: check test paths formal formal-axi clean

# GHDL syntax check of the simulation models and of the external memory (the SDRAM
# controller, its bridge and the chip model). The Quartus IPs (ips/) need
# Intel's altera_mf library, which the toolchain image does not carry: they are
# analyzed by the hardware-top simulation in the Tests repository. The clock-domain
# synchronizer comes from the Common-Components repository, next to this one.
check:
	@mkdir -p $(WDIR)
	@$(GHDL) -a $(STD) --work=work --workdir=$(WDIR) $$(riscv-tools vhdl-sort ../Common-Components/src/synchronizer.vhd sim/*.vhd external/sdram/*.vhd external/sdram/sim/*.vhd external/axi/*.vhd external/cache/*.vhd external/cache/sim/*.vhd external/axi/sim/*.vhd external/bus/*.vhd external/bus/sim/*.vhd)
	@echo "VHDL syntax check passed"

# Per-entity cocotb tests; `make test TEST=RAM` for one entry of tests/python/tests.json.
test:
	uv run python tests/python/runner.py $(TEST)

# Formal verification of the SDRAM arbiter (docs/FORMAL.md): needs yosys and sby, in the toolchain image.
formal:
	bash formal/run.sh

# Formal verification of the AXI4 master and slave bridges (docs/DCACHE_AXI.md); the slave takes about ten minutes.
formal-axi:
	bash formal/axi_master/run.sh
	bash formal/axi_slave/run.sh

# Every path the configuration lists exists.
paths:
	riscv-tools --root . check-paths --manifest paths.yaml

clean:
	rm -rf build
	find . -type f \( -name '*.vcd' -o -name '*.ghw' \) -print -delete
