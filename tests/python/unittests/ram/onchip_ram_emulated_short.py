"""Emulated latency shorter than the block can do.

With LATENCY of 3 the adapter asks for 4 clocks to see a word ready,
more than the 3 of the block, and keeps the structural 6 of a line,
never less.

"""

import cocotb

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut
from tests.python.unittests.ram.onchip_ram_port import start
from tests.python.unittests.ram.ram_chip import BASE, load, store, word

WORD_CLOCKS = (
    4  # the latency of 3 asks for 4 edges, more than the 3 of the block
)
LINE_CLOCKS = 6  # the 4 words of a line need 6, more than the latency asks


@cocotb.test()
async def test_the_structural_minimum_holds(dut: Dut):
    """Check a word and a line against the longer latency."""
    await start(dut)
    _, _, waited = await store(dut, BASE + 0x10, word(1))
    check_equal(waited, WORD_CLOCKS)
    value, _, waited = await load(dut, BASE + 0x10)
    check_equal(waited, WORD_CLOCKS)
    check_equal(value, word(1))
    _, _, waited = await load(dut, BASE + 0x20, line=True)
    check_equal(waited, LINE_CLOCKS)
