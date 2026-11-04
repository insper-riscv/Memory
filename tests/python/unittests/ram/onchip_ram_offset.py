"""onchip_ram_port with base_kib equal to 8.

The RAM starts 8 KiB into its 64 MB region, so the address of the RAM
is the address of the region minus its base.

"""

import cocotb

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut
from tests.python.unittests.ram.onchip_ram_port import (
    WINDOW,
    debug_word,
    start,
)
from tests.python.unittests.ram.ram_chip import BASE, load, store

OFFSET = 8 * 1024


@cocotb.test()
async def test_the_ram_starts_at_the_base(dut: Dut):
    """Check that the first word is the word at the base."""
    await start(dut)
    await store(dut, BASE + OFFSET, 0x11112222)
    value, _, _ = await load(dut, BASE + OFFSET)
    check_equal(value, 0x11112222)
    check_equal(await debug_word(dut, 0), 0x11112222)


@cocotb.test()
async def test_outside_the_ram_is_zero(dut: Dut):
    """Check the word before the base and the one after the end."""
    await start(dut)
    first = BASE + OFFSET
    stores = [(first, 0xAAAA0001), (first - 4, 0xBBBB0002)]
    stores.append((first + WINDOW, 0xCCCC0003))
    for addr, value in stores:
        await store(dut, addr, value)
    checks = ((first - 4, 0), (first + WINDOW, 0), (first, 0xAAAA0001))
    for addr, want in checks:
        got, _, _ = await load(dut, addr)
        check_equal(got, want, f"{addr:#x}")
