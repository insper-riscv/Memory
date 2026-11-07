"""dcache with window_bits equal to 27, in write-back mode.

The 128 MiB window of the DE2-115: the tag keeps address bit 26, so two
addresses 64 MiB apart are two lines, and the line written back on an
eviction goes to its own address.

"""

import cocotb

from tests.python.unittests.cache.data_cache_flash import (
    HIT_CLOCKS,
    LAT,
    SDRAM,
    access,
    start,
    word,
)
from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

HALF_WINDOW = 64 << 20  # the bit 26 that the 64 MiB window left out
WINDOW = 128 << 20


@cocotb.test()
async def test_addresses_64_mib_apart_are_not_confused(dut: Dut):
    """Check that bit 26 is part of the tag."""
    mem = await start(dut)
    a = SDRAM + 0x1230
    b = a + HALF_WINDOW
    for addr in (a, b):
        v, waited = await access(dut, addr)
        check_true(v == word(addr) and waited > LAT, f"{addr:#x}")
    check_equal([r[0] for r in mem.reads], [a & ~0xF, b & ~0xF])
    v, waited = await access(dut, a)  # b took the slot of a
    check_true(v == word(a) and waited > LAT, "a still hit after b")


@cocotb.test()
async def test_the_last_line_of_the_window_is_cached(dut: Dut):
    """Check the request of the last line of the 128 MiB and its hits."""
    mem = await start(dut)
    top = SDRAM + WINDOW - 16
    v, waited = await access(dut, top)
    check_true(v == word(top) and waited > LAT)
    v, hit = await access(dut, top + 12)
    check_true(v == word(top + 12) and hit <= HIT_CLOCKS)
    check_equal(mem.reads, [(top, 1)])


@cocotb.test()
async def test_the_evicted_line_goes_back_to_its_own_address(dut: Dut):
    """Check that the write-back address carries bit 26."""
    mem = await start(dut)
    a = SDRAM + HALF_WINDOW + 0x2340
    b = SDRAM + 0x2340  # the same index, the other half of the window
    await access(dut, a)
    await access(dut, a, wr=0xCAFE0001)
    await access(dut, b)  # evicts the dirty line of a
    check_true(
        any(addr == a for addr, _ in mem.writes),
        f"no write-back to {a:#x}: {[hex(w[0]) for w in mem.writes]}",
    )
