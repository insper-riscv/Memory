"""Cocotb tests for cache_pkg.

The window test and the line index width, at the edges of the region and
of the sizes the caches accept.
"""

import cocotb
from cocotb.triggers import Timer

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut

# Região da FLASH do mapa padrão, em KiB.
BASE_KIB = 524288
END_KIB = 1048576
KIB = 1024


async def window(dut: Dut, addr: int, base_kib: int, end_kib: int) -> int:
    """Return in_window for an address and a region."""
    dut.i_addr.value = addr
    dut.i_base_kib.value = base_kib
    dut.i_end_kib.value = end_kib
    await Timer(1, unit="ns")
    return int(dut.o_in_window.value)


@cocotb.test()
async def test_edges_of_the_region(dut: Dut):
    """Check the addresses at the base, at the end and next to them."""
    base, end = BASE_KIB * KIB, END_KIB * KIB
    for addr, wanted in (
        (base - 1, 0),
        (base, 1),
        (base + 1, 1),
        (end - 1, 1),
        (end, 0),
        (end + 1, 0),
        (0, 0),
        (0xFFFFFFFF, 0),
    ):
        got = await window(dut, addr, BASE_KIB, END_KIB)
        check_equal(got, wanted, f"address {addr:#x}")


@cocotb.test()
async def test_empty_region(dut: Dut):
    """Check that a region with base equal to its end is empty."""
    for addr in (0, KIB * 7 - 1, KIB * 7, KIB * 7 + 1):
        check_equal(await window(dut, addr, 7, 7), 0, f"address {addr:#x}")
    check_equal(await window(dut, 0, 0, 0), 0, "zero region")


@cocotb.test()
async def test_region_up_to_the_top(dut: Dut):
    """Check a region that ends at the last KiB of the address space."""
    top = (1 << 22) - 1
    check_equal(await window(dut, (top - 1) * KIB - 1, top - 1, top), 0)
    check_equal(await window(dut, (top - 1) * KIB, top - 1, top), 1)
    check_equal(await window(dut, top * KIB - 1, top - 1, top), 1)
    check_equal(await window(dut, top * KIB, top - 1, top), 0)
    check_equal(await window(dut, 0xFFFFFFFF, top - 1, top), 0)


@cocotb.test()
async def test_index_bits(dut: Dut):
    """Check the index width for the smallest and the usual sizes."""
    for size_log2, wanted in ((8, 1), (9, 2), (12, 5), (16, 9), (20, 13)):
        dut.i_size_log2.value = size_log2
        await Timer(1, unit="ns")
        check_equal(int(dut.o_index_bits.value), wanted, f"2**{size_log2}")
