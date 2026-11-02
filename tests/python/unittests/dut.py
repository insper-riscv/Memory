"""Type of the design under test handle of the cocotb tests."""

from typing import Any

# The simulator resolves the signals of the design by name when the test
# runs, so the handle has no attributes a type checker can know: each
# testbench reads and drives whatever ports its entity declares.
type Dut = Any

# A signal of the design: its value is read and driven as `.value`.
type Signal = Any
