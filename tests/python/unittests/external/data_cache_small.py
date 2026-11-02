"""dcache with index_bits equal to 5.

The 4 kbit data cache of the simulation platforms, write-through: 32
lines of 16 bytes, so two addresses 512 bytes apart share a line.

"""

import cocotb

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut
from tests.python.unittests.external.data_cache_flash import (
    HIT_CLOCKS,
    SDRAM,
    access,
    start,
    word,
)

LINES = 32
LINE_BYTES = 16
CAPACITY = LINES * LINE_BYTES  # 512 bytes: the stride of a conflict


@cocotb.test()
async def test_the_whole_capacity_stays_resident(dut: Dut):
    """Check that 32 lines fit and a second pass hits every one."""
    mem = await start(dut)
    for k in range(LINES):
        a = SDRAM + LINE_BYTES * k
        v, _ = await access(dut, a)
        check_equal(v, word(a), f"{a:#x}")
    check_equal(len(mem.reads), LINES)
    for k in range(LINES):
        a = SDRAM + LINE_BYTES * k
        v, hit = await access(dut, a)
        check_equal(v, word(a), f"{a:#x}")
        check_true(hit <= HIT_CLOCKS, f"line {k} missed on the second pass")
    check_equal(len(mem.reads), LINES, "the second pass is all hits")


@cocotb.test()
async def test_conflict_at_the_capacity_stride(dut: Dut):
    """Check that two addresses 512 bytes apart share a line."""
    mem = await start(dut)
    a, b = SDRAM + 0x040, SDRAM + 0x040 + CAPACITY
    for addr in (a, b, a):
        v, _ = await access(dut, addr)
        check_equal(v, word(addr))
    check_equal([r for r, _ in mem.reads], [a & ~0xF, b & ~0xF, a & ~0xF])


@cocotb.test()
async def test_no_conflict_below_the_capacity_stride(dut: Dut):
    """Check that two addresses 256 bytes apart keep both lines."""
    mem = await start(dut)
    a, b = SDRAM + 0x040, SDRAM + 0x040 + CAPACITY // 2
    for addr in (a, b, a, b):
        v, _ = await access(dut, addr)
        check_equal(v, word(addr))
    check_equal([r for r, _ in mem.reads], [a & ~0xF, b & ~0xF])
