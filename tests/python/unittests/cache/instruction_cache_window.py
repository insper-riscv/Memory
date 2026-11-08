"""icache with window_bits equal to 27.

The 128 MiB window of the DE2-115: the tag keeps address bit 26, so two
addresses 64 MiB apart are two lines, and the request to the memory
carries the whole address.

"""

import cocotb

from tests.python.unittests.cache.instruction_cache import (
    BASE,
    fetch,
    start,
    word,
)
from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

HALF_WINDOW = 64 << 20  # the bit 26 that the 64 MiB window left out
WINDOW = 128 << 20
FLASH = 0x20000000
LINE = 0xF


@cocotb.test()
async def test_addresses_64_mib_apart_are_not_confused(dut: Dut):
    """Check that bit 26 is part of the tag."""
    mem = await start(dut)
    a = BASE + 0x1230
    b = a + HALF_WINDOW
    for addr in (a, b, a):
        data, waited = await fetch(dut, addr)
        check_equal(data, word(addr), f"{addr:#x}")
        check_true(waited > 0, f"{addr:#x} hit a line of the other half")
    check_equal(mem.requests, [a & ~LINE, b & ~LINE, a & ~LINE])


@cocotb.test()
async def test_the_last_line_of_the_window_is_requested_whole(dut: Dut):
    """Check the request of the last line of the 128 MiB."""
    mem = await start(dut)
    top = BASE + WINDOW - 16
    for i in range(4):
        data, _ = await fetch(dut, top + 4 * i)
        check_equal(data, word(top + 4 * i), f"{top + 4 * i:#x}")
    check_equal(mem.requests, [top])


@cocotb.test()
async def test_the_flash_and_the_upper_half_are_told_apart(dut: Dut):
    """Check that the region bit still separates the FLASH."""
    mem = await start(dut)
    f = FLASH + 0x1230
    s = BASE + HALF_WINDOW + 0x1230
    for addr in (f, s, f):
        data, _ = await fetch(dut, addr)
        check_equal(data, word(addr), f"{addr:#x}")
    check_equal(mem.requests, [f & ~LINE, s & ~LINE, f & ~LINE])
