"""The data cache in front of the SDRAM, through the AXI4-Lite.

Bridges, as a core would use it.

Every test compares what the core reads with a Python copy of the
memory, and what reaches the chip model with that copy once the cache
has been flushed. The chip model fails the simulation on any broken chip
rule, as in the SDRAM system tests.

"""

import random

import cocotb
from cocotb.triggers import RisingEdge

from tests.python.unittests.external.sdram_helpers import (
    _post_edge,
    access,
    merge,
    model_word,
    start,
)

LINE_WORDS = 4
LINES = 256
SAME_INDEX = (
    LINES * LINE_WORDS
)  # words apart that map to the same line of the cache


async def begin(dut):
    """Start the clock and reset the DUT."""
    dut.i_flush.value = 0
    await start(dut)


async def flush(dut):
    """Write back every dirty line; returns the cpu cycles it took."""
    dut.i_flush.value = 1
    await _post_edge(dut)
    dut.i_flush.value = 0
    cycles = 1
    while True:
        await RisingEdge(dut.i_clk_cpu)
        cycles += 1
        if int(dut.o_flush_done.value):
            break
        assert cycles < 200_000, "flush never finished"
    await _post_edge(dut)
    assert int(dut.o_busy.value) == 0
    return cycles


class Mirror:
    """The expected content of the memory.

    It is filled from the chip the first time a word is touched.

    """

    def __init__(self, dut):
        """Bind the model to the DUT."""
        self.dut = dut
        self.mem = {}

    async def word(self, w):
        """Return the data word the models hold at an address."""
        if w not in self.mem:
            self.mem[w] = await model_word(self.dut, w)
        return self.mem[w]

    async def write(self, w, data, be=0xF):
        """Write one word."""
        old = await self.word(w)
        self.mem[w] = merge(old, data, be)
        return await access(self.dut, True, w, data, be)

    async def read(self, w, hold=0):
        """Read one word and return it."""
        want = await self.word(w)
        got, cycles = await access(self.dut, False, w, hold=hold)
        assert got == want, (
            f"word 0x{w:06X}: read 0x{got:08X}, expected 0x{want:08X}"
        )
        return cycles

    async def check_chip(self):
        """Check the chip against the Python copy of the memory."""
        for w, v in self.mem.items():
            got = await model_word(self.dut, w)
            assert got == v, (
                f"word 0x{w:06X}: the chip holds 0x{got:08X}, "
                f"expected 0x{v:08X}"
            )


@cocotb.test()
async def test_write_then_read(dut):
    """A word written and read back through the cache, and the chip.

    Only sees it after the flush.

    """
    await begin(dut)
    m = Mirror(dut)
    old = await m.word(0x123456)
    await m.write(0x123456, 0xCAFEBABE)
    await m.read(0x123456)
    assert await model_word(dut, 0x123456) == old, (
        "a write-back cache wrote through"
    )
    await flush(dut)
    assert await model_word(dut, 0x123456) == 0xCAFEBABE


@cocotb.test()
async def test_hit_is_fast_and_miss_is_not(dut):
    """A hit is ready in two clocks, a miss takes the line fill.

    And a dirty miss takes more.

    """
    await begin(dut)
    m = Mirror(dut)
    miss = await m.read(0x000100)
    hit = await m.read(0x000100)
    near = await m.read(0x000101)  # same line, another word
    assert hit <= 3 and near <= 3, f"hit took {hit} and {near} cycles"
    assert miss > 4 * hit, f"a miss took {miss} cycles against {hit} of a hit"
    await m.write(0x000100, 0x11111111)  # the line is dirty now
    clean = await m.read(0x000100 + SAME_INDEX * 2)  # replaces the dirty line
    dirty = miss
    assert clean > dirty, (
        f"a dirty miss ({clean}) should cost more than a clean one ({dirty})"
    )
    await m.read(0x000100)  # the line comes back, with the written word
    await flush(dut)
    await m.check_chip()


@cocotb.test()
async def test_byte_enables(dut):
    """Every byte-enable mask writes exactly the enabled bytes.

    This holds in the cache and in the chip.

    """
    await begin(dut)
    m = Mirror(dut)
    for be in range(16):
        w = 0x000200 + be
        await m.write(w, 0x11223344)
        await m.write(w, 0xA5B6C7D8, be)
        await m.read(w)
    await flush(dut)
    await m.check_chip()


@cocotb.test()
async def test_hold_keeps_ready_and_data(dut):
    """While the pipeline stays stopped after ready, ready stays.

    High and the read data does not move.

    """
    await begin(dut)
    m = Mirror(dut)
    await m.write(0x000300, 0xDEADBEEF)
    await m.read(0x000300, hold=5)
    await m.read(0x000300 + SAME_INDEX, hold=5)  # a miss with a hold
    await m.read(0x000300, hold=5)


@cocotb.test()
async def test_eviction_writes_back(dut):
    """Words that map to the same line replace each other, and each.

    One keeps its own content.

    """
    await begin(dut)
    m = Mirror(dut)
    ws = [0x000040 + k * SAME_INDEX for k in range(6)]
    for i, w in enumerate(ws):
        await m.write(w, 0x1000 + i)
    for w in ws:
        await m.read(w)
    # the first ones were written back by the evictions, before any
    # flush
    first = await model_word(dut, ws[0])
    assert first == m.mem[ws[0]], (
        f"0x{first:08X} reached the chip, expected 0x{m.mem[ws[0]]:08X}"
    )
    await flush(dut)
    await m.check_chip()


@cocotb.test()
async def test_random_traffic(dut):
    """Random reads and writes over a few conflicting lines.

    Against the Python copy.

    """
    await begin(dut)
    m = Mirror(dut)
    rng = random.Random(7)  # noqa: S311
    base = [
        0x000010,
        0x000011,
        0x000012,
        0x000013,
        0x000014,
        0x0003FF,
        0x000400,
        0x000FFF,
    ]
    words = []
    for b in base:
        words += [b, b + SAME_INDEX, b + 3 * SAME_INDEX]
    for _ in range(300):
        w = rng.choice(words)
        if rng.random() < 0.5:
            await m.write(
                w,
                rng.getrandbits(32),
                rng.choice([0xF, 0xF, 0x3, 0xC, 0x1, 0x8, 0x5]),
            )
        else:
            await m.read(w, hold=rng.choice([0, 0, 0, 2]))
    await flush(dut)
    await m.check_chip()
    # after the flush the lines are clean: the same traffic reads the
    # same values
    for w in words:
        await m.read(w)


@cocotb.test()
async def test_flush_keeps_lines_valid(dut):
    """A flush leaves the lines in the cache.

    The next read of a flushed word is a hit.

    """
    await begin(dut)
    m = Mirror(dut)
    await m.write(0x000500, 0xAB)
    await flush(dut)
    assert await m.read(0x000500) <= 3
