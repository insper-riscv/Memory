"""The SDRAM bridge, controller and chip model together, as a core.

Would use them.

The chip model fails the simulation on any broken chip rule (timings,
command order, power-up sequence, refresh interval), so a passing run
also proves the controller obeys the chip. The tests compare what a core
reads with a Python copy of the memory and, independently, with the
content stored in the model.

"""

import cocotb
from cocotb.triggers import Timer

from tests.python.unittests.checks import (
    Prng,
    check_equal,
    check_true,
    log_info,
)
from tests.python.unittests.dut import Dut
from tests.python.unittests.external.sdram_helpers import (
    CPU_NS,
    LAST_WORD,
    access,
    line_access,
    merge,
    model_word,
    post_edge,
    start,
)

MIN_REFRESHES = 8  # refreshes the chip must have seen
MIN_REFRESHES_60US = 7  # refreshes in 60 us, at least
WRITE_STALL = 8  # core cycles a write stalls, at most
READ_STALL = 10  # core cycles a read stalls, at most
HALF = 0.5  # probability of the random choices
LINE_WRITE = 0.35  # share of line writes in the mixed test
LINE_READ = 0.7  # share of line writes and reads together


@cocotb.test()
async def test_power_up_and_first_access(dut: Dut):
    """The power-up sequence completes.

    A write followed by a read returns the word.

    """
    await start(dut)
    check_equal(int(dut.o_dbg_init_ok.value), 1)
    check_true(int(dut.o_dbg_refreshes.value) >= MIN_REFRESHES)
    _, _ = await access(dut, True, 0x123456, 0xCAFEBABE)
    got, _ = await access(dut, False, 0x123456)
    check_equal(got, 0xCAFEBABE, f"read 0x{got:08X}")
    check_equal(await model_word(dut, 0x123456), 0xCAFEBABE)


@cocotb.test()
async def test_byte_enables(dut: Dut):
    """Every byte-enable mask writes exactly the enabled bytes."""
    await start(dut)
    base = 0x11223344
    for be in range(16):
        word = 0x000100 + be
        await access(dut, True, word, base)
        await access(dut, True, word, 0xA5B6C7D8, be)
        got, _ = await access(dut, False, word)
        want = merge(base, 0xA5B6C7D8, be)
        check_equal(
            got, want, f"be={be:04b}: read 0x{got:08X}, expected 0x{want:08X}"
        )


@cocotb.test()
async def test_address_decode(dut: Dut):
    """Distinct word addresses keep distinct values.

    Banks, rows, columns, the first and last word.

    """
    await start(dut)
    rng = Prng(1)
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
        check_equal(
            got, v, f"word 0x{w:06X}: read 0x{got:08X}, expected 0x{v:08X}"
        )
        check_equal(
            await model_word(dut, w),
            v,
            f"word 0x{w:06X}: the chip holds something else",
        )


@cocotb.test()
async def test_random_traffic(dut: Dut):
    """Random reads and writes with random byte masks.

    Gaps between accesses and pipeline holds are random too.

    """
    await start(dut)
    rng = Prng(7)
    pool = [rng.randrange(1 << 24) for _ in range(48)]
    ref: dict[int, int] = {}
    for _ in range(500):
        w = rng.choice(pool)
        hold = rng.choice([0, 0, 0, 1, 3])
        if w not in ref:  # the first write of a word is a full word
            v = rng.getrandbits(32)
            await access(dut, True, w, v, 0xF, hold)
            ref[w] = v
        elif rng.random() < HALF:
            v, be = (
                rng.getrandbits(32),
                rng.choice([0xF, 0xF, 0x3, 0xC, 0x1, 0x8, 0x6]),
            )
            await access(dut, True, w, v, be, hold)
            ref[w] = merge(ref[w], v, be)
        else:
            got, _ = await access(dut, False, w, hold=hold)
            check_equal(
                got,
                ref[w],
                f"word 0x{w:06X}: read 0x{got:08X}, expected 0x{ref[w]:08X}",
            )
        for _ in range(rng.choice([0, 0, 1, 5, 20])):
            await post_edge(dut)
    for w, v in ref.items():
        got, _ = await access(dut, False, w)
        check_equal(got, v)


@cocotb.test()
async def test_refresh_keeps_running(dut: Dut):
    """With the bus idle for several refresh periods the controller.

    Keeps refreshing (the chip model fails the simulation if two
    refreshes are more than 7.8 us apart).

    """
    await start(dut)
    before = int(dut.o_dbg_refreshes.value)
    for _ in range(int(60_000 / CPU_NS)):  # 60 us
        await post_edge(dut)
    after = int(dut.o_dbg_refreshes.value)
    check_true(
        after - before >= MIN_REFRESHES_60US,
        f"only {after - before} refreshes in 60 us",
    )
    await access(dut, True, 0x42, 0x0BADF00D)
    got, _ = await access(dut, False, 0x42)
    check_equal(got, 0x0BADF00D)


@cocotb.test()
async def test_read_data_changes_only_when_the_pipeline_advances(dut: Dut):
    """A second read held in the stopped pipeline keeps the first.

    Read data visible.

    """
    await start(dut)
    await access(dut, True, 0x10, 0x11111111)
    await access(dut, True, 0x20, 0x22222222)
    first, _ = await access(dut, False, 0x10)
    check_equal(first, 0x11111111)
    second, _ = await access(
        dut, False, 0x20, hold=6
    )  # asserts rdata == first while holding
    check_equal(second, 0x22222222)


async def _ratio(dut: Dut, cpu_ns: int, offset: int):
    await start(dut, cpu_ns, offset)
    rng = Prng(cpu_ns)
    ref: dict[int, int] = {}
    for _ in range(60):
        w = rng.randrange(1 << 24)
        v = rng.getrandbits(32)
        await access(dut, True, w, v)
        ref[w] = v
    for w, v in ref.items():
        got, _ = await access(dut, False, w)
        check_equal(
            got,
            v,
            f"{cpu_ns} ns: word 0x{w:06X} read 0x{got:08X}, "
            f"expected 0x{v:08X}",
        )


@cocotb.test()
async def test_core_clock_twice_the_memory_clock_period(dut: Dut):
    """Core clock at 14 ns (the memory clock divided by 2), in phase."""
    await _ratio(dut, 14, 0)


@cocotb.test()
async def test_core_clock_unrelated_and_shifted(dut: Dut):
    """Core clock at 53 ns, shifted by 3 ns.

    No fixed relation to the memory clock.

    """
    await _ratio(dut, 53, 3)


@cocotb.test()
async def test_core_clock_slow_and_shifted(dut: Dut):
    """Core clock at 100 ns, shifted by 13 ns."""
    await _ratio(dut, 100, 13)


@cocotb.test()
async def test_a_corrupted_chip_is_noticed(dut: Dut):
    """Control for the checks above.

    Flipping one stored bit changes exactly that bit of the read.

    """
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
        check_equal(
            got, 0x00FF00FF ^ (1 << bit), f"bit {bit}: read 0x{got:08X}"
        )
        dut.i_dbg_flip.value = 1  # put it back
        await Timer(5, unit="ns")
        dut.i_dbg_flip.value = 0
        await Timer(5, unit="ns")


@cocotb.test()
async def test_latency(dut: Dut):
    """The stall a core sees, in core cycles (logged, and bounded.

    To catch a regression).

    """
    await start(dut)
    _, w = await access(dut, True, 0x5, 1)
    _, r = await access(dut, False, 0x5)
    log_info(
        f"stall: write {w} core cycles, read {r} core cycles "
        f"(core clock {CPU_NS} ns)"
    )
    check_true(w <= WRITE_STALL and r <= READ_STALL, f"write {w}, read {r}")


@cocotb.test()
async def test_line_write_then_word_reads(dut: Dut):
    """A line written in one request holds its four words, read.

    Back one by one and from the chip.

    """
    await start(dut)
    base = 0x00ABC0
    words = [0x11111111, 0x22222222, 0x33333333, 0x44444444]
    await line_access(dut, True, base, words)
    for i, w in enumerate(words):
        got, _ = await access(dut, False, base + i)
        check_equal(got, w, f"word {i}: read 0x{got:08X}")
        check_equal(await model_word(dut, base + i), w)


@cocotb.test()
async def test_line_read_of_words_written_one_by_one(dut: Dut):
    """A line read returns the four words written one at a time.

    They come in order.

    """
    await start(dut)
    base = 0x7FFFF0
    words = [0xA0000001 + i * 0x01010101 for i in range(4)]
    for i, w in enumerate(words):
        await access(dut, True, base + i, w)
    got, _ = await line_access(dut, False, base)
    check_equal(got, words, [hex(g) for g in got])


@cocotb.test()
async def test_line_byte_enables(dut: Dut):
    """Each word of a line write keeps its own byte enables."""
    await start(dut)
    base = 0x000100
    old = [0xDEAD0000 + i for i in range(4)]
    await line_access(dut, True, base, old)
    new = [0xA1B2C3D4, 0x55667788, 0x99AABBCC, 0x0F1E2D3C]
    bes = [0x3, 0xC, 0x5, 0xA]
    await line_access(dut, True, base, new, bes)
    got, _ = await line_access(dut, False, base)
    want = [merge(o, n, b) for o, n, b in zip(old, new, bes, strict=True)]
    check_equal(got, want, [hex(g) for g in got])


@cocotb.test()
async def test_line_is_faster_than_four_words(dut: Dut):
    """One line request costs less than four word requests (one.

    Handshake, one row opening).

    """
    await start(dut)
    base = 0x000200
    _, line_cycles = await line_access(dut, False, base)
    word_cycles = 0
    for i in range(4):
        _, c = await access(dut, False, base + i)
        word_cycles += c
    log_info(
        f"line read {line_cycles} cycles, four words {word_cycles} cycles"
    )
    check_true(
        line_cycles < word_cycles - 4, f"{line_cycles} against {word_cycles}"
    )


async def mixed_line_write(
    dut: Dut, rng: Prng, base: int, mem: dict[int, int]
):
    """Write a random line with random byte enables; update the copy."""
    words = [rng.getrandbits(32) for _ in range(4)]
    bes = [rng.choice([0xF, 0xF, 0x3, 0xC, 0x1]) for _ in range(4)]
    await line_access(dut, True, base, words, bes)
    for i in range(4):
        if base + i in mem:
            old = mem[base + i]
        else:
            old = await model_word(dut, base + i)
        mem[base + i] = merge(old, words[i], bes[i])


async def mixed_line_read(dut: Dut, base: int, mem: dict[int, int]):
    """Read a line and compare the words the copy already knows."""
    got, _ = await line_access(dut, False, base)
    for i in range(4):
        if base + i in mem:
            check_equal(
                got[i],
                mem[base + i],
                f"line 0x{base:06X} word {i}: 0x{got[i]:08X}",
            )


@cocotb.test()
async def test_lines_and_words_mixed(dut: Dut):
    """Random lines and words over rows, banks and the ends of memory.

    The result is compared against a Python copy.
    """
    await start(dut)
    rng = Prng(5)
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
    mem: dict[int, int] = {}
    for _ in range(80):
        base = rng.choice(lines)
        kind = rng.random()
        if kind < LINE_WRITE:
            await mixed_line_write(dut, rng, base, mem)
        elif kind < LINE_READ:
            await mixed_line_read(dut, base, mem)
        else:
            w = base + rng.randrange(4)
            v = rng.getrandbits(32)
            await access(dut, True, w, v)
            mem[w] = v
    for w, v in mem.items():
        check_equal(await model_word(dut, w), v, f"word 0x{w:06X}")
