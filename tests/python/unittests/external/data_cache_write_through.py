"""The data cache in write-through mode, behind the AXI4-Lite.

Bridges and the SDRAM.

Every store reaches the chip before it completes, with no flush, and a
store that misses does not bring the line in. The tests compare what the
core reads with a Python copy of the memory, and the chip with the same
copy after every group of accesses.

"""

import random

import cocotb

from tests.python.unittests.external.data_cache import (
    SAME_INDEX,
    Mirror,
    begin,
)
from tests.python.unittests.external.sdram_helpers import model_word


@cocotb.test()
async def test_a_store_reaches_the_chip_at_once(dut):
    """Check that a store reaches the chip at once."""
    await begin(dut)
    m = Mirror(dut)
    await m.write(0x123456, 0xCAFEBABE)
    assert await model_word(dut, 0x123456) == 0xCAFEBABE, (
        "the store stayed in the cache"
    )
    await m.write(0x123456, 0x11, 0x1)
    assert await model_word(dut, 0x123456) == 0xCAFEBA11
    await m.check_chip()


@cocotb.test()
async def test_a_store_that_misses_does_not_bring_the_line_in(dut):
    """Check that a store that misses does not bring the line in."""
    await begin(dut)
    m = Mirror(dut)
    await m.write(0x000100, 0xAA)
    hit_read = await m.read(
        0x000100
    )  # first read: the line was not brought in
    again = await m.read(0x000100)
    assert hit_read > 4 * again, (
        f"the read after a missing store was a hit "
        f"({hit_read} against {again} clocks)"
    )


@cocotb.test()
async def test_a_store_that_hits_updates_the_line_and_the_chip(dut):
    """Check that a store that hits updates the line and the chip."""
    await begin(dut)
    m = Mirror(dut)
    await m.read(0x000200)  # the line is in
    await m.write(0x000201, 0xBEEF)  # same line
    assert await model_word(dut, 0x000201) == 0xBEEF
    cycles = await m.read(0x000201)
    assert cycles <= 3, f"the updated word is a hit, it took {cycles} clocks"
    await m.check_chip()


@cocotb.test()
async def test_random_traffic_keeps_the_chip_current(dut):
    """Check that random traffic keeps the chip current."""
    await begin(dut)
    m = Mirror(dut)
    rng = random.Random(11)  # noqa: S311
    base = [
        0x000010,
        0x000011,
        0x000012,
        0x000013,
        0x0003FF,
        0x000400,
        0x000FFF,
    ]
    words = []
    for b in base:
        words += [b, b + SAME_INDEX, b + 3 * SAME_INDEX]
    for i in range(300):
        w = rng.choice(words)
        if rng.random() < 0.5:
            await m.write(
                w,
                rng.getrandbits(32),
                rng.choice([0xF, 0xF, 0x3, 0xC, 0x1, 0x8, 0x5]),
            )
        else:
            await m.read(w, hold=rng.choice([0, 0, 2]))
        if i % 25 == 24:
            await m.check_chip()  # no flush: the chip is already current
    await m.check_chip()
