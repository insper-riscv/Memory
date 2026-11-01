"""The SDRAM bridge, controller and chip model together, as a core would use them.

The chip model fails the simulation on any broken chip rule (timings, command
order, power-up sequence, refresh interval), so a passing run also proves the
controller obeys the chip. The tests compare what a core reads with a Python
copy of the memory and, independently, with the content stored in the model.
"""

import random

import cocotb
from cocotb.triggers import Timer

from tests.python.unittests.external.sdram_helpers import (
    CPU_NS,
    LAST_WORD,
    _post_edge,
    access,
    line_access,
    merge,
    model_word,
    start,
)


@cocotb.test()
async def test_power_up_and_first_access(dut):
    """The power-up sequence completes, and a write followed by a read returns the word."""
    await start(dut)
    assert int(dut.o_dbg_init_ok.value) == 1
    assert int(dut.o_dbg_refreshes.value) >= 8
    _, _ = await access(dut, True, 0x123456, 0xCAFEBABE)
    got, _ = await access(dut, False, 0x123456)
    assert got == 0xCAFEBABE, f"read 0x{got:08X}"
    assert await model_word(dut, 0x123456) == 0xCAFEBABE


@cocotb.test()
async def test_byte_enables(dut):
    """Every byte-enable mask writes exactly the enabled bytes."""
    await start(dut)
    base = 0x11223344
    for be in range(16):
        word = 0x000100 + be
        await access(dut, True, word, base)
        await access(dut, True, word, 0xA5B6C7D8, be)
        got, _ = await access(dut, False, word)
        want = merge(base, 0xA5B6C7D8, be)
        assert got == want, (
            f"be={be:04b}: read 0x{got:08X}, expected 0x{want:08X}"
        )


@cocotb.test()
async def test_address_decode(dut):
    """Distinct word addresses keep distinct values: banks, rows, columns, the first and last word."""
    await start(dut)
    rng = random.Random(1)
    words = [
        0,
        1,
        0x0FF,
        0x1FF,
        0x200,
        0x400,
        0x600,
        0x7FF,
        0x800,
        0x1000,
        0x7FFFF,
        0x800000,
        0xFFFFFE,
        LAST_WORD,
    ]
    words += [rng.randrange(1 << 24) for _ in range(40)]
    words = sorted(set(words))
    want = {
        w: (0x9E3779B1 * (i + 1)) & 0xFFFFFFFF for i, w in enumerate(words)
    }
    for w, v in want.items():
        await access(dut, True, w, v)
    for w, v in want.items():
        got, _ = await access(dut, False, w)
        assert got == v, (
            f"word 0x{w:06X}: read 0x{got:08X}, expected 0x{v:08X}"
        )
        assert await model_word(dut, w) == v, (
            f"word 0x{w:06X}: the chip holds something else"
        )


@cocotb.test()
async def test_random_traffic(dut):
    """Random reads and writes, random byte masks, random gaps and random pipeline holds."""
    await start(dut)
    rng = random.Random(7)
    pool = [rng.randrange(1 << 24) for _ in range(48)]
    ref = {}
    for _ in range(500):
        w = rng.choice(pool)
        hold = rng.choice([0, 0, 0, 1, 3])
        if w not in ref:  # the first write of a word is a full word
            v = rng.getrandbits(32)
            await access(dut, True, w, v, 0xF, hold)
            ref[w] = v
        elif rng.random() < 0.5:
            v, be = (
                rng.getrandbits(32),
                rng.choice([0xF, 0xF, 0x3, 0xC, 0x1, 0x8, 0x6]),
            )
            await access(dut, True, w, v, be, hold)
            ref[w] = merge(ref[w], v, be)
        else:
            got, _ = await access(dut, False, w, hold=hold)
            assert got == ref[w], (
                f"word 0x{w:06X}: read 0x{got:08X}, expected 0x{ref[w]:08X}"
            )
        for _ in range(rng.choice([0, 0, 1, 5, 20])):
            await _post_edge(dut)
    for w, v in ref.items():
        got, _ = await access(dut, False, w)
        assert got == v


@cocotb.test()
async def test_refresh_keeps_running(dut):
    """With the bus idle for several refresh periods the controller keeps refreshing
    (the chip model fails the simulation if two refreshes are more than 7.8 us apart).
    """
    await start(dut)
    before = int(dut.o_dbg_refreshes.value)
    for _ in range(int(60_000 / CPU_NS)):  # 60 us
        await _post_edge(dut)
    after = int(dut.o_dbg_refreshes.value)
    assert after - before >= 7, f"only {after - before} refreshes in 60 us"
    await access(dut, True, 0x42, 0x0BADF00D)
    got, _ = await access(dut, False, 0x42)
    assert got == 0x0BADF00D


@cocotb.test()
async def test_read_data_changes_only_when_the_pipeline_advances(dut):
    """A second read held in the stopped pipeline keeps the first read data visible."""
    await start(dut)
    await access(dut, True, 0x10, 0x11111111)
    await access(dut, True, 0x20, 0x22222222)
    first, _ = await access(dut, False, 0x10)
    assert first == 0x11111111
    second, _ = await access(
        dut, False, 0x20, hold=6
    )  # asserts rdata == first while holding
    assert second == 0x22222222


async def _ratio(dut, cpu_ns, offset):
    await start(dut, cpu_ns, offset)
    rng = random.Random(cpu_ns)
    ref = {}
    for _ in range(60):
        w = rng.randrange(1 << 24)
        v = rng.getrandbits(32)
        await access(dut, True, w, v)
        ref[w] = v
    for w, v in ref.items():
        got, _ = await access(dut, False, w)
        assert got == v, (
            f"{cpu_ns} ns: word 0x{w:06X} read 0x{got:08X}, expected 0x{v:08X}"
        )


@cocotb.test()
async def test_core_clock_twice_the_memory_clock_period(dut):
    """Core clock at 14 ns (the memory clock divided by 2), in phase."""
    await _ratio(dut, 14, 0)


@cocotb.test()
async def test_core_clock_unrelated_and_shifted(dut):
    """Core clock at 53 ns, shifted by 3 ns: no fixed relation to the memory clock."""
    await _ratio(dut, 53, 3)


@cocotb.test()
async def test_core_clock_slow_and_shifted(dut):
    """Core clock at 100 ns, shifted by 13 ns."""
    await _ratio(dut, 100, 13)


@cocotb.test()
async def test_a_corrupted_chip_is_noticed(dut):
    """Control for the checks above: flipping one stored bit changes exactly that bit of the read."""
    await start(dut)
    await access(dut, True, 0x777, 0x00FF00FF)
    for bit in (0, 7, 16, 31):
        dut.i_dbg_flip_addr.value = 0x777
        dut.i_dbg_flip_bit.value = bit
        dut.i_dbg_flip.value = 1
        await Timer(5, unit="ns")
        dut.i_dbg_flip.value = 0
        await Timer(5, unit="ns")
        got, _ = await access(dut, False, 0x777)
        assert got == 0x00FF00FF ^ (1 << bit), f"bit {bit}: read 0x{got:08X}"
        dut.i_dbg_flip.value = 1  # put it back
        await Timer(5, unit="ns")
        dut.i_dbg_flip.value = 0
        await Timer(5, unit="ns")


@cocotb.test()
async def test_latency(dut):
    """The stall a core sees, in core cycles (logged, and bounded to catch a regression)."""
    await start(dut)
    _, w = await access(dut, True, 0x5, 1)
    _, r = await access(dut, False, 0x5)
    dut._log.info(
        f"stall: write {w} core cycles, read {r} core cycles (core clock {CPU_NS} ns)"
    )
    assert w <= 8 and r <= 10, f"write {w}, read {r}"


@cocotb.test()
async def test_line_write_then_word_reads(dut):
    """A line written in one request holds its four words, read back one by one and from the chip."""
    await start(dut)
    base = 0x00ABC0
    words = [0x11111111, 0x22222222, 0x33333333, 0x44444444]
    await line_access(dut, True, base, words)
    for i, w in enumerate(words):
        got, _ = await access(dut, False, base + i)
        assert got == w, f"word {i}: read 0x{got:08X}"
        assert await model_word(dut, base + i) == w


@cocotb.test()
async def test_line_read_of_words_written_one_by_one(dut):
    """A line read returns the four words that were written one at a time, in order."""
    await start(dut)
    base = 0x7FFFF0
    words = [0xA0000001 + i * 0x01010101 for i in range(4)]
    for i, w in enumerate(words):
        await access(dut, True, base + i, w)
    got, _ = await line_access(dut, False, base)
    assert got == words, [hex(g) for g in got]


@cocotb.test()
async def test_line_byte_enables(dut):
    """Each word of a line write keeps its own byte enables."""
    await start(dut)
    base = 0x000100
    old = [0xDEAD0000 + i for i in range(4)]
    await line_access(dut, True, base, old)
    new = [0xA1B2C3D4, 0x55667788, 0x99AABBCC, 0x0F1E2D3C]
    bes = [0x3, 0xC, 0x5, 0xA]
    await line_access(dut, True, base, new, bes)
    got, _ = await line_access(dut, False, base)
    want = [merge(o, n, b) for o, n, b in zip(old, new, bes)]
    assert got == want, [hex(g) for g in got]


@cocotb.test()
async def test_line_is_faster_than_four_words(dut):
    """One line request costs less than four word requests (one handshake, one row opening)."""
    await start(dut)
    base = 0x000200
    _, line_cycles = await line_access(dut, False, base)
    word_cycles = 0
    for i in range(4):
        _, c = await access(dut, False, base + i)
        word_cycles += c
    dut._log.info(
        f"line read {line_cycles} cycles, four words {word_cycles} cycles"
    )
    assert line_cycles < word_cycles - 4, (
        f"{line_cycles} against {word_cycles}"
    )


@cocotb.test()
async def test_lines_and_words_mixed(dut):
    """Random lines and words over rows, banks and the ends of the memory, against a Python copy."""
    await start(dut)
    rng = random.Random(5)
    lines = [
        0,
        4,
        0x1FC,
        0x200,
        0x7FC,
        0x800,
        0x1000,
        0x7FFFC,
        0x800000,
        LAST_WORD & ~3,
    ]
    lines += [rng.randrange(1 << 22) << 2 for _ in range(12)]
    mem = {}
    for _ in range(80):
        base = rng.choice(lines)
        kind = rng.random()
        if kind < 0.35:
            words = [rng.getrandbits(32) for _ in range(4)]
            bes = [rng.choice([0xF, 0xF, 0x3, 0xC, 0x1]) for _ in range(4)]
            await line_access(dut, True, base, words, bes)
            for i in range(4):
                mem[base + i] = merge(
                    mem.get(
                        base + i,
                        await model_word(dut, base + i)
                        if base + i not in mem
                        else 0,
                    ),
                    words[i],
                    bes[i],
                )
        elif kind < 0.7:
            got, _ = await line_access(dut, False, base)
            for i in range(4):
                if base + i in mem:
                    assert got[i] == mem[base + i], (
                        f"line 0x{base:06X} word {i}: 0x{got[i]:08X}"
                    )
        else:
            w = base + rng.randrange(4)
            v = rng.getrandbits(32)
            await access(dut, True, w, v)
            mem[w] = v
    for w, v in mem.items():
        assert await model_word(dut, w) == v, f"word 0x{w:06X}"
