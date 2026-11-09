"""Cocotb tests for sim_util_pkg.

The data pattern of an address, the nanosecond conversion and the pulse
of a violation of the memory models.
"""

import cocotb
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

# Constante de mistura e de xor do padrão de dados.
MIX = 0x9E3779B1
XOR = 0x5A5A1234
MASK32 = 0xFFFFFFFF
# Atraso pedido a tns, em ns.
DELAY_NS = 20


def pattern(addr: int) -> int:
    """Return the pattern word of an address."""
    return ((addr * MIX) & MASK32) ^ XOR


@cocotb.test()
async def test_pattern_word(dut: Dut):
    """Check the pattern word at the edges and at a few addresses."""
    for addr in (0, 1, 4, 0x20000000, 0xFFFFFFFC, 0xFFFFFFFF):
        dut.i_addr.value = addr
        await Timer(1, unit="ns")
        check_equal(int(dut.o_word.value), pattern(addr), f"{addr:#x}")
    check_equal(pattern(0), XOR, "address zero is the xor constant")


@cocotb.test()
async def test_tns(dut: Dut):
    """Check that tns waits as many nanoseconds as it is asked."""
    dut.i_start.value = 0
    dut.i_delay_ns.value = DELAY_NS
    await Timer(1, unit="ns")
    dut.i_start.value = 1
    await Timer(DELAY_NS - 1, unit="ns")
    check_equal(int(dut.o_tick.value), 0, "before the delay")
    await Timer(2, unit="ns")
    check_equal(int(dut.o_tick.value), 1, "after the delay")
    dut.i_start.value = 0
    await Timer(1, unit="ns")


@cocotb.test()
async def test_violation_pulse(dut: Dut):
    """Check that a violation pulses the output and the pulse ends."""
    dut.i_violate.value = 0
    await Timer(5, unit="ns")
    check_equal(int(dut.o_violation.value), 0, "idle")
    dut.i_violate.value = 1
    await RisingEdge(dut.o_violation)
    check_true(int(dut.o_violation.value) == 1, "the pulse rose")
    await Timer(2, unit="ns")
    check_equal(int(dut.o_violation.value), 0, "the pulse ended")
    dut.i_violate.value = 0
