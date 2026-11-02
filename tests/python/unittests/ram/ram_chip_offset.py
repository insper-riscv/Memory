"""ram_chip with base_kib equal to 8.

The chip starts 8 KiB into its 64 MB region, so the address of the chip
is the address of the region minus its base: a RAM that sits at an
address other than the start of the region still fits the window.

"""

import cocotb

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut
from tests.python.unittests.ram.ram_chip import (
    BASE,
    debug_word,
    load,
    start,
    store,
)

OFFSET = 8 * 1024
WINDOW = 1 << 12  # 4 KB, the size_bytes of the entry


@cocotb.test()
async def test_the_chip_starts_at_the_base(dut: Dut):
    """Check that the first word of the chip is the word at the base."""
    await start(dut)
    await store(dut, BASE + OFFSET, 0x11112222)
    value, _, _ = await load(dut, BASE + OFFSET)
    check_equal(value, 0x11112222)
    check_equal(await debug_word(dut, 0), 0x11112222)


@cocotb.test()
async def test_outside_the_chip_is_zero(dut: Dut):
    """Check the word before the base and the one after the end."""
    await start(dut)
    await store(dut, BASE + OFFSET, 0xAAAA0001)
    await store(dut, BASE + OFFSET - 4, 0xBBBB0002)
    await store(dut, BASE + OFFSET + WINDOW, 0xCCCC0003)
    value, _, _ = await load(dut, BASE + OFFSET - 4)
    check_equal(value, 0, "the word before the base is outside")
    value, _, _ = await load(dut, BASE + OFFSET + WINDOW)
    check_equal(value, 0, "the word after the end is outside")
    value, _, _ = await load(dut, BASE + OFFSET)
    check_equal(value, 0xAAAA0001, "the stores outside did not wrap around")
