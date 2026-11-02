"""ram_chip with size_bytes equal to 4096.

The size of the chip is a generic, a power of two: with 4096 bytes the
window is 4 KB, so the word at 4 KB is already outside it.

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

WINDOW = 1 << 12  # 4 KB


@cocotb.test()
async def test_the_window_follows_the_generic(dut: Dut):
    """Check that the last word of 4 KB is kept and the next is not."""
    await start(dut)
    await store(dut, BASE + WINDOW - 4, 0xAAAA5555)
    await store(dut, BASE + WINDOW, 0x12345678)
    value, _, _ = await load(dut, BASE + WINDOW - 4)
    check_equal(value, 0xAAAA5555)
    value, _, _ = await load(dut, BASE + WINDOW)
    check_equal(value, 0, "a read outside a 4 KB window is zero")
    value, _, _ = await load(dut, BASE)
    check_equal(value, 0, "the store outside did not wrap around")


@cocotb.test()
async def test_the_debug_port_ends_with_the_window(dut: Dut):
    """Check that the debug port reads zero past the end of the chip."""
    await start(dut)
    await store(dut, BASE + WINDOW - 4, 0xCAFE0001)
    check_equal(await debug_word(dut, WINDOW // 4 - 1), 0xCAFE0001)
    check_equal(await debug_word(dut, WINDOW // 4), 0)
