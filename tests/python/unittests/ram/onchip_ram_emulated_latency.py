"""Emulated latency of the on-chip RAM, equal to the ram_chip one.

The entry LATENCY of 9 runs on the adapter over the block (OnchipRamEmulated) and on the ram_chip
(OnchipRamEmulatedChip), with the same module: a word and a line both take
LATENCY clocks after the one that sees the request, for a read and a
write, at any address and outside the window.

"""

import cocotb

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut
from tests.python.unittests.ram.onchip_ram_port import start
from tests.python.unittests.ram.ram_chip import BASE, load, store, word

LATENCY = 9
CLOCKS = LATENCY + 1  # edges until ready is seen, counting the first


@cocotb.test()
async def test_a_word_takes_the_emulated_latency(dut: Dut):
    """Check the same clocks for a word read and a word write."""
    await start(dut)
    for a in (0x0, 0x44, 0xFFC):
        _, _, waited = await store(dut, BASE + a, word(a))
        check_equal(waited, CLOCKS, f"store at {a:#x}")
        value, _, waited = await load(dut, BASE + a)
        check_equal(waited, CLOCKS, f"load at {a:#x}")
        check_equal(value, word(a), f"data at {a:#x}")


@cocotb.test()
async def test_a_line_takes_the_emulated_latency(dut: Dut):
    """Check that a line costs the same clocks as a word."""
    await start(dut)
    for a in (0x0, 0x40, 0xFF0):
        _, _, waited = await store(dut, BASE + a, 1, words_x=2)
        check_equal(waited, CLOCKS, f"line store at {a:#x}")
        _, _, waited = await load(dut, BASE + a, line=True)
        check_equal(waited, CLOCKS, f"line load at {a:#x}")


@cocotb.test()
async def test_the_outside_of_the_window_takes_the_same_time(dut: Dut):
    """Check that an access beyond the window is not faster."""
    await start(dut)
    value, _, waited = await load(dut, BASE + 0x1000)
    check_equal(waited, CLOCKS)
    check_equal(value, 0)
