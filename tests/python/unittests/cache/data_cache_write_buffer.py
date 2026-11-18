"""The data cache in write-through mode with a four-word write buffer.

A store completes without waiting for the chip, the stores reach the
chip in program order, and a read never passes a store. The tests
compare what the core reads with a Python copy of the memory, and the
chip with the same copy once the flush has finished (the flush ends
only with the buffer empty).

"""

import cocotb

from tests.python.unittests.cache.data_cache import (
    SAME_INDEX,
    Mirror,
    begin,
    flush,
)
from tests.python.unittests.checks import Prng, check_true
from tests.python.unittests.dut import Dut

STORE_CLOCKS = 6  # clocks of a store that enters the buffer, at most
HALF = 0.5  # probability of the random choices
CHECK_EVERY = 20  # accesses between two checks of the chip


@cocotb.test()
async def test_a_store_does_not_wait_for_the_chip(dut: Dut):
    """Check that a store completes in a few clocks."""
    await begin(dut)
    m = Mirror(dut)
    await m.word(0x000500)  # fill the copy before timing the store
    _, cycles = await m.write(0x000500, 0xCAFEBABE)
    check_true(
        cycles <= STORE_CLOCKS,
        f"the store waited for the chip ({cycles} clocks)",
    )
    await flush(dut)
    await m.check_chip()


@cocotb.test()
async def test_a_read_sees_the_stores_before_it(dut: Dut):
    """Check that a read after a store returns the stored word."""
    await begin(dut)
    m = Mirror(dut)
    for k in range(4):
        await m.word(0x000600 + k * 4)
    for k in range(4):
        await m.write(0x000600 + k * 4, 0x11110000 + k)
    for k in range(4):  # the lines are not in the cache: they are filled
        await m.read(0x000600 + k * 4)
    await flush(dut)
    await m.check_chip()


@cocotb.test()
async def test_more_stores_than_the_buffer_holds(dut: Dut):
    """Check that a burst of stores longer than the buffer arrives."""
    await begin(dut)
    m = Mirror(dut)
    for k in range(24):
        await m.write(0x000700 + k * 7, 0xA0000000 + k, 0xF)
    await flush(dut)
    await m.check_chip()


@cocotb.test()
async def test_byte_enables_in_the_buffer(dut: Dut):
    """Check that every byte-enable mask writes the enabled bytes."""
    await begin(dut)
    m = Mirror(dut)
    for be in range(16):
        w = 0x000800 + be
        await m.write(w, 0x11223344)
        await m.write(w, 0xA5B6C7D8, be)
        await m.read(w)
    await flush(dut)
    await m.check_chip()


@cocotb.test()
async def test_random_traffic_keeps_the_chip_current(dut: Dut):
    """Check that random traffic leaves the chip as the copy after a flush."""
    await begin(dut)
    m = Mirror(dut)
    rng = Prng(29)
    base = [0x000010, 0x000011, 0x000012, 0x0003FF, 0x000400, 0x000FFF]
    words: list[int] = []
    for b in base:
        words += [b, b + SAME_INDEX, b + 3 * SAME_INDEX]
    for i in range(400):
        w = rng.choice(words)
        if rng.random() < HALF:
            await m.write(
                w,
                rng.getrandbits(32),
                rng.choice([0xF, 0xF, 0x3, 0xC, 0x1, 0x8, 0x5]),
            )
        else:
            await m.read(w, hold=rng.choice([0, 0, 2]))
        if i % CHECK_EVERY == CHECK_EVERY - 1:
            await flush(dut)
            await m.check_chip()
    await flush(dut)
    await m.check_chip()
