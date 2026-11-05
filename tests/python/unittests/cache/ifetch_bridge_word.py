"""ifetch_bridge with fetch_line false.

The bridge asks for the one word of the fetch address, so each new
address pays the memory latency.

"""

import cocotb

from tests.python.unittests.cache.ifetch_bridge import (
    BASE,
    fetch,
    start,
    word,
)
from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut


@cocotb.test()
async def test_every_word_is_a_word_request(dut: Dut):
    """Check that each sequential word is a request of its own."""
    mem = await start(dut)
    for i in range(8):
        a = BASE + 4 * i
        data, _ = await fetch(dut, a)
        check_equal(data, word(a), f"{a:#x}")
    check_equal(mem.requests, [BASE + 4 * i for i in range(8)])
    check_equal(mem.lines, [0] * 8)


@cocotb.test()
async def test_a_held_word_makes_no_new_request(dut: Dut):
    """Check that the word of the held address is served again."""
    mem = await start(dut)
    a = BASE + 0x344
    await fetch(dut, a)
    data, waited = await fetch(dut, a)
    check_equal(data, word(a))
    check_equal(waited, 0)
    check_equal(mem.requests, [a])
