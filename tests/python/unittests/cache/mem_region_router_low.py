"""mem_region_router with the FLASH right after the BOOT_MEMORY.

The FLASH region is [0x800, 0x8000) and the SDRAM is everything else, so
the region comes from the generics and not from address bit 29.

"""

import cocotb

from tests.python.unittests.cache.mem_region_router import (
    line_words,
    request,
    start,
)
from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

FLASH = 0x800
FLASH_LAST_LINE = 0x7FF0
AFTER_FLASH = 0x8000
SDRAM = 0x10000


@cocotb.test()
async def test_line_read_inside_the_region_reaches_the_flash(dut: Dut):
    """Check that a read inside the region goes to the FLASH."""
    s, f = await start(dut)
    r, rx, _ = await request(dut, FLASH + 0x400, rd=1, line=1)
    got = [r, rx & 0xFFFFFFFF, (rx >> 32) & 0xFFFFFFFF, rx >> 64]
    check_equal(got, line_words(0x22220000, FLASH + 0x400))
    check_true(len(f.requests) == 1 and s.requests == [])


@cocotb.test()
async def test_the_region_edges(dut: Dut):
    """Check the first and last lines and the ones around them."""
    s, f = await start(dut)
    await request(dut, FLASH, rd=1, line=1)
    await request(dut, FLASH_LAST_LINE, rd=1, line=1)
    await request(dut, AFTER_FLASH, rd=1, line=1)
    await request(dut, FLASH - 0x10, rd=1, line=1)
    check_equal([a for a, _, _ in f.requests], [FLASH, FLASH_LAST_LINE])
    check_equal([a for a, _, _ in s.requests], [AFTER_FLASH, FLASH - 0x10])


@cocotb.test()
async def test_store_to_the_flash_is_absorbed_and_sdram_passes(dut: Dut):
    """Check that a FLASH store is absorbed and a SDRAM store passes."""
    s, f = await start(dut)
    await request(dut, FLASH + 0x80, wr=1)
    check_true(s.requests == [] and f.requests == [])
    await request(dut, SDRAM + 0x20, wr=1)
    check_true(s.requests == [(SDRAM + 0x20, "w", 0)] and f.requests == [])
