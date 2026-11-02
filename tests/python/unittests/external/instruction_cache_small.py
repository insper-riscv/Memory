"""icache with index_bits equal to 5.

The 4 kbit instruction cache of the simulation platforms: 32 lines of 16
bytes, so two addresses 512 bytes apart share a line.

"""

import cocotb

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut
from tests.python.unittests.external.instruction_cache import (
    BASE,
    FLASH,
    fetch,
    start,
    word,
)

LINES = 32
LINE_BYTES = 16
CAPACITY = LINES * LINE_BYTES  # 512 bytes: the stride of a conflict


async def sweep(dut: Dut, base: int, count: int):
    """Fetch count consecutive lines, one word of each."""
    for k in range(count):
        addr = base + LINE_BYTES * k
        data, _ = await fetch(dut, addr)
        check_equal(data, word(addr), f"{addr:#x}")


@cocotb.test()
async def test_the_whole_capacity_stays_resident(dut: Dut):
    """Check that 32 lines fit and a second pass makes no request."""
    mem = await start(dut)
    await sweep(dut, BASE, LINES)
    check_equal(len(mem.requests), LINES)
    await sweep(dut, BASE, LINES)
    check_equal(len(mem.requests), LINES, "the second pass is all hits")


@cocotb.test()
async def test_the_next_line_evicts_the_first(dut: Dut):
    """Check that a 33rd line takes the place of the first."""
    mem = await start(dut)
    await sweep(dut, BASE, LINES + 1)
    check_equal(len(mem.requests), LINES + 1)
    data, _ = await fetch(dut, BASE)
    check_equal(data, word(BASE))
    check_equal(mem.requests[-1], BASE, "line 0 was evicted by line 32")


@cocotb.test()
async def test_conflict_at_the_capacity_stride(dut: Dut):
    """Check that two addresses 512 bytes apart share a line."""
    mem = await start(dut)
    a, b = BASE + 0x040, BASE + 0x040 + CAPACITY
    for addr in (a, b, a):
        data, _ = await fetch(dut, addr)
        check_equal(data, word(addr))
    check_equal(mem.requests, [a & ~0xF, b & ~0xF, a & ~0xF])


@cocotb.test()
async def test_no_conflict_below_the_capacity_stride(dut: Dut):
    """Check that two addresses 256 bytes apart keep both lines."""
    mem = await start(dut)
    a, b = BASE + 0x040, BASE + 0x040 + CAPACITY // 2
    for addr in (a, b, a, b):
        data, _ = await fetch(dut, addr)
        check_equal(data, word(addr))
    check_equal(mem.requests, [a & ~0xF, b & ~0xF])


@cocotb.test()
async def test_the_flash_and_the_ram_are_told_apart(dut: Dut):
    """Check that the same index in the two regions is a conflict."""
    mem = await start(dut)
    s, f = BASE + 0x1230, FLASH + 0x1230
    for addr in (s, f, s):
        data, _ = await fetch(dut, addr)
        check_equal(data, word(addr))
    check_equal(len(mem.requests), 3)
