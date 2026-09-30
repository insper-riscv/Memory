SHELL := /bin/bash
GHDL  := ghdl
STD   := --std=08
WDIR  := build/ghdl

.PHONY: check test paths clean

# GHDL syntax check of the simulation models. The Quartus IPs (ips/) need
# Intel's altera_mf library, which the toolchain image does not carry: they are
# analyzed by the hardware-top simulation in the Tests repository.
check:
	@mkdir -p $(WDIR)
	@$(GHDL) -a $(STD) --work=work --workdir=$(WDIR) $$(uv run riscv-tools vhdl-sort sim/*.vhd)
	@echo "VHDL syntax check passed"

# Per-entity cocotb tests; `make test TEST=RAM` for one entry of tests/python/tests.json.
test:
	uv run python tests/python/runner.py $(TEST)

# Every path the configuration lists exists.
paths:
	uv run riscv-tools --root . check-paths --manifest paths.yaml

clean:
	rm -rf build
	find . -type f \( -name '*.vcd' -o -name '*.ghw' \) -print -delete
