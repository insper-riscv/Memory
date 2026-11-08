"""Cocotb tests for ram_pkg.

The offset of an address inside the window of a memory chip, with the
base at zero and away from zero, and below the base.
"""

import cocotb
from cocotb.triggers import Timer

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut

KIB = 1024
# Máscara dos 26 bits baixos, a região de 64 MiB.
MASK26 = (1 << 26) - 1


async def offset(dut: Dut, addr: int, base_kib: int) -> int:
    """Return window_offset for an address and a base."""
    dut.i_addr.value = addr
    dut.i_base_kib.value = base_kib
    await Timer(1, unit="ns")
    return int(dut.o_offset.value)


@cocotb.test()
async def test_base_zero(dut: Dut):
    """Check that a zero base leaves the low 26 bits of the address."""
    for addr in (0, 4, 0xFFC, 0x3FFFFFF):
        check_equal(await offset(dut, addr, 0), addr, f"address {addr:#x}")
    check_equal(await offset(dut, 0x23FFFFFF, 0), 0x3FFFFFF, "bits above 26")


@cocotb.test()
async def test_base_away_from_zero(dut: Dut):
    """Check the offset at, after and far from a base of 512 KiB."""
    base = 512
    for addr, wanted in (
        (base * KIB, 0),
        (base * KIB + 4, 4),
        (base * KIB + 0xFFC, 0xFFC),
        (0x20000000 + base * KIB + 8, 8),
    ):
        check_equal(await offset(dut, addr, base), wanted, f"{addr:#x}")


@cocotb.test()
async def test_below_the_base(dut: Dut):
    """Check that an address below the base wraps around in 26 bits."""
    base = 512
    for addr in (base * KIB - 4, 0):
        wanted = (addr - base * KIB) & MASK26
        check_equal(await offset(dut, addr, base), wanted, f"{addr:#x}")
