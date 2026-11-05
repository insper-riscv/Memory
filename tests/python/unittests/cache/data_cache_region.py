"""dcache invalidation by region.

An erase or a program of the FLASH behind the cache, as the FLASH
controller reports it, drops the clean lines of the region and never a
dirty line. The cache is in write-back mode here.

"""

import cocotb
from cocotb.triggers import RisingEdge

from tests.python.unittests.cache.data_cache_flash import (
    FLASH,
    HIT_CLOCKS,
    LAT,
    SDRAM,
    access,
    start,
    word,
)
from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

SETTLE = 6  # clocks after the pulse until the lines are gone
INDEX_SPAN = 0x1000  # bytes apart that map to the same line


async def pulse_region(dut: Dut, first: int, last: int):
    """Raise the region invalidation for one clock and let it settle."""
    dut.i_inval_first.value = first
    dut.i_inval_last.value = last
    dut.i_inval_region.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_inval_region.value = 0
    for _ in range(SETTLE):
        await RisingEdge(dut.i_clk)


@cocotb.test()
async def test_the_region_drops_its_line_and_keeps_the_others(dut: Dut):
    """Check that a region drops its line and keeps the others."""
    mem = await start(dut)
    inside, outside = FLASH + 0x1230, FLASH + 0x2450
    for a in (inside, outside):
        await access(dut, a)
    mem.version = 1
    await pulse_region(dut, inside & ~0xFF, (inside | 0xFF))
    check_equal((await access(dut, outside))[0], word(outside, 0))
    value, waited = await access(dut, inside)
    check_equal(value, word(inside, 1))
    check_true(waited > LAT, "the dropped line has to come again")
    check_equal(len(mem.reads), 3)


@cocotb.test()
async def test_a_region_of_many_lines_wraps_the_index(dut: Dut):
    """Check a region that crosses the last line of the index."""
    mem = await start(dut)
    lines = [FLASH + 0xFF0, FLASH + 0x1000, FLASH + 0x1010]
    near = [FLASH + 0xFE0, FLASH + 0x1020]
    for a in lines + near:
        await access(dut, a)
    mem.version = 1
    await pulse_region(dut, lines[0], lines[2] + 15)
    for a in near:
        check_equal((await access(dut, a))[0], word(a, 0))
    for a in lines:
        check_equal((await access(dut, a))[0], word(a, 1))


@cocotb.test()
async def test_a_dirty_line_survives_the_region(dut: Dut):
    """Check that a dirty line of the same index is not dropped."""
    mem = await start(dut)
    s = SDRAM + 0x540
    await access(dut, s, wr=0xCAFE0002)
    reads = len(mem.reads)
    mem.version = 1
    # the region is a flash line with the index of the dirty line
    await pulse_region(dut, FLASH + 0x540, FLASH + 0x54F)
    value, hit = await access(dut, s)
    check_equal(value, 0xCAFE0002)
    check_true(hit <= HIT_CLOCKS, hit)
    check_equal(len(mem.reads), reads)
    check_equal(mem.writes, [])


@cocotb.test()
async def test_a_region_as_big_as_the_cache_drops_every_clean_line(
    dut: Dut,
):
    """Check that 4 KB of region drops every clean line."""
    mem = await start(dut)
    addrs = [FLASH + 0x100, SDRAM + 0x6F0, FLASH + 0xA08]
    for a in addrs:
        await access(dut, a)
    mem.version = 1
    await pulse_region(dut, FLASH + 0x10000, FLASH + 0x10FFF)
    for a in addrs:
        value, waited = await access(dut, a)
        check_equal(value, word(a, 1))
        check_true(waited > LAT, hex(a))


@cocotb.test()
async def test_a_backwards_region_does_nothing(dut: Dut):
    """Check that last below first is ignored."""
    mem = await start(dut)
    a = FLASH + 0x700
    await access(dut, a)
    mem.version = 1
    await pulse_region(dut, a + 0x100, a)
    value, hit = await access(dut, a)
    check_equal(value, word(a, 0))
    check_true(hit <= HIT_CLOCKS, hit)


@cocotb.test()
async def test_a_fill_under_way_inside_the_region_is_not_validated(
    dut: Dut,
):
    """Check that a fill with old data does not become valid."""
    mem = await start(dut)
    a = FLASH + 0x300
    task = cocotb.start_soon(access(dut, a))
    while not mem.reads:
        await RisingEdge(dut.i_clk)
    # the memory has answered with the old data; the fill is finishing
    for _ in range(LAT + 1):
        await RisingEdge(dut.i_clk)
    mem.version = 1
    await pulse_region(dut, a, a + 15)
    # the access that asked for the line gets the new data, because the
    # line filled with the old data is not validated
    first, _ = await task
    check_equal(first, word(a, 1))
    check_equal(len(mem.reads), 2)
