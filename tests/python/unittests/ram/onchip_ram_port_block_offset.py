"""onchip_ram_port, alone, with the window 8 KiB into the region.

The address the adapter gives the block is the address of the region
minus the base, and what lies below the base is outside the window.

"""

import cocotb

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut
from tests.python.unittests.ram.onchip_ram_port_block import (
    WINDOW,
    debug_word,
    start,
)
from tests.python.unittests.ram.ram_chip import BASE, load, store, word

OFFSET = 8 * 1024


@cocotb.test()
async def test_the_first_word_of_the_block_is_the_base(dut: Dut):
    """Check that the base of the window is index zero of the block."""
    block = await start(dut)
    await store(dut, BASE + OFFSET, 0x11112222)
    await store(dut, BASE + OFFSET + 0x44, 0x33334444)
    check_equal(
        block.writes,
        [(0, 0x11112222, 0xF), (0x11, 0x33334444, 0xF)],
    )
    value, _, _ = await load(dut, BASE + OFFSET + 0x44)
    check_equal(value, 0x33334444)
    check_equal(await debug_word(dut, 0x11), 0x33334444)


@cocotb.test()
async def test_below_the_base_and_past_the_end_are_outside(dut: Dut):
    """Check both edges of the window."""
    block = await start(dut)
    for addr in (BASE, BASE + OFFSET - 4, BASE + OFFSET + WINDOW):
        value, _, _ = await load(dut, addr)
        check_equal(value, 0, f"{addr:#x}")
        await store(dut, addr, 0xFFFFFFFF)
    check_equal(block.writes, [])
    check_equal(block.reads, [])
    value, _, _ = await load(dut, BASE + OFFSET + WINDOW - 4)
    check_equal(value, word(WINDOW - 4))
