"""The internal memory of the data cache, in front of the SDRAM.

An access inside the window is served by the block RAMs of the cache in
the time of a hit and never reaches the chip, and the accesses outside the
window behave as before. The window is 4 KiB at the word address 0x2000
(byte 0x00008000 of the SDRAM).

"""

import cocotb

from tests.python.unittests.cache.data_cache import Mirror, begin, flush
from tests.python.unittests.checks import Prng, check_equal, check_true
from tests.python.unittests.dut import Dut
from tests.python.unittests.ram.sdram_helpers import access, model_word

SCRATCH_WORD = 0x2000  # first word of the window (0x8000 / 4)
SCRATCH_WORDS = 1024  # words of the window (4 KiB)
HIT_CLOCKS = 3  # clocks of an access to the window, at most
HALF = 0.5  # probability of the random choices


@cocotb.test()
async def test_the_window_answers_like_a_hit_and_stays_off_the_chip(
    dut: Dut,
):
    """Check that a word of the window is fast and never reaches the chip."""
    await begin(dut)
    before = await model_word(dut, SCRATCH_WORD + 5)
    _, cycles = await access(dut, True, SCRATCH_WORD + 5, 0xCAFEBABE)
    check_true(cycles <= HIT_CLOCKS + 2, f"store took {cycles} clocks")
    got, cycles = await access(dut, False, SCRATCH_WORD + 5)
    check_equal(got, 0xCAFEBABE)
    check_true(cycles <= HIT_CLOCKS, f"load took {cycles} clocks")
    await flush(dut)
    check_equal(
        await model_word(dut, SCRATCH_WORD + 5),
        before,
        "a store of the window reached the chip",
    )


@cocotb.test()
async def test_byte_enables_and_every_word(dut: Dut):
    """Check the byte enables and that the words do not alias."""
    await begin(dut)
    mem: dict[int, int] = {}
    rng = Prng(5)
    for w in range(0, SCRATCH_WORDS, 7):
        v = rng.getrandbits(32)
        await access(dut, True, SCRATCH_WORD + w, v)
        mem[w] = v
    for w in range(0, SCRATCH_WORDS, 7):
        v = rng.getrandbits(32)
        be = rng.choice([0x1, 0x2, 0x4, 0x8, 0x3, 0xC, 0xA])
        await access(dut, True, SCRATCH_WORD + w, v, be)
        old = mem[w]
        for b in range(4):
            if be >> b & 1:
                old = (old & ~(0xFF << (8 * b))) | (v & (0xFF << (8 * b)))
        mem[w] = old
    for w, v in mem.items():
        got, _ = await access(dut, False, SCRATCH_WORD + w)
        check_equal(got, v, f"word {w}")


@cocotb.test()
async def test_outside_the_window_is_the_cache(dut: Dut):
    """Check that the words beside the window still go through the cache."""
    await begin(dut)
    m = Mirror(dut)
    for w in (SCRATCH_WORD - 1, SCRATCH_WORD + SCRATCH_WORDS):
        await m.write(w, 0x12345678)
        await m.read(w)
    for _ in range(100):
        w = SCRATCH_WORD - 8 + int(Prng(w).random() * 16) * 200
        if SCRATCH_WORD <= w < SCRATCH_WORD + SCRATCH_WORDS:
            continue
        await m.write(w, 0xA5A5A5A5)
        await m.read(w)
    await flush(dut)
    await m.check_chip()
