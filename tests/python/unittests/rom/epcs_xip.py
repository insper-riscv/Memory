"""epcs_xip.

The direct read adapter of the serial configuration flash against
the SPI chip model: word and line reads with the contract of the flash
chip, the window that starts at the user region, the zero of a read
outside the window, and the clocks of a frame, which grow with the SPI
clock divider and with the bytes read. The chip model flags a violation
when the adapter sends an instruction a read has no use for, so every
test checks that flag too.

"""

import struct

import cocotb
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import Prng, check_equal, check_true
from tests.python.unittests.dut import Dut
from tests.python.unittests.flashface import read, start

WORD, LINE = 0, 1


def pattern(addr: int) -> int:
    """Return the initial byte of the chip model at an address."""
    return (addr * 37 + addr // 256 * 11 + 5) % 251


def generic(dut: Dut, name: str) -> int:
    """Return an integer generic of the design."""
    return int(getattr(dut, name).value)


def expected(dut: Dut, addr: int, line: int) -> list[int]:
    """Return the words the chip holds for a request in the window."""
    window = generic(dut, "window_bytes")
    offset = generic(dut, "chip_offset")
    size = 16 if line else 4
    first = addr & ~(size - 1)
    base = offset + (first & (window - 1))
    data = bytes(pattern(base + i) for i in range(size))
    return list(struct.unpack("<" + "I" * (size // 4), data))


def frame_clocks(dut: Dut, line: int) -> int:
    """Return the clocks from the request to ready.

    A byte takes eight bits of 2 x clk_div clocks and one clock to
    load; the frame ends with one more half period and the gap of CS#
    high, and the request, the capture and the ready take three clocks.
    """
    div = generic(dut, "clk_div")
    header = 5 if generic(dut, "fast_read") else 4
    count = header + (16 if line else 4)
    gap = (generic(dut, "gap_ticks") + 1) * div
    return count * (16 * div + 1) + gap + 3


async def check_chip(dut: Dut) -> None:
    """Check that the chip model saw no instruction outside the list."""
    await Timer(1, unit="ns")
    check_equal(int(dut.o_violation.value), 0, "chip model violation")


@cocotb.test()
async def test_word_reads_the_window_from_the_chip_offset(dut: Dut):
    """Check that a word read returns the chip bytes at the offset."""
    await start(dut)
    window = generic(dut, "window_bytes")
    for addr in (0, 4, 0x40, window - 4, 0x1234 & ~3):
        words, _ = await read(dut, addr, WORD)
        check_equal(words, expected(dut, addr, WORD), f"word {addr:#x}")
    await check_chip(dut)


@cocotb.test()
async def test_line_reads_four_words_aligned_to_the_line(dut: Dut):
    """Check that a line starts at the 16-byte aligned address."""
    await start(dut)
    window = generic(dut, "window_bytes")
    for addr in (0, 0x10, 0x20, window - 16, 0x30):
        words, _ = await read(dut, addr, LINE)
        check_equal(words, expected(dut, addr, LINE), f"line {addr:#x}")
    words, _ = await read(dut, 0x4C, LINE)
    check_equal(words, expected(dut, 0x40, LINE), "unaligned line address")
    words, _ = await read(dut, 0x4E, WORD)
    check_equal(words, expected(dut, 0x4C, WORD), "unaligned word address")
    await check_chip(dut)


@cocotb.test()
async def test_read_outside_the_window_is_zero_without_the_chip(dut: Dut):
    """Check that a read past the window is zero and leaves CS# high."""
    await start(dut)
    window = generic(dut, "window_bytes")
    for line in (WORD, LINE):
        dut.i_addr.value = window
        dut.i_line.value = line
        dut.i_rden.value = 1
        touched = False
        for _ in range(8):
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            touched = touched or int(dut.o_cs_n.value) == 0
        check_equal(int(dut.o_ready.value), 1, "answers at once")
        check_equal(int(dut.o_rdata.value), 0, "word 0 is zero")
        if line:
            check_equal(int(dut.o_rdata_x.value), 0, "words 1 to 3 are zero")
        check_true(not touched, "the chip is not selected")
        dut.i_rden.value = 0
        dut.i_advance.value = 1
        await RisingEdge(dut.i_clk)
        dut.i_advance.value = 0
        await Timer(1, unit="ns")
    words, _ = await read(dut, 0, LINE)
    check_equal(words, expected(dut, 0, LINE), "the next read is normal")
    await check_chip(dut)


@cocotb.test()
async def test_latency_follows_the_frame(dut: Dut):
    """Check the clocks of a frame against divider, gap and bytes."""
    await start(dut)
    _, word = await read(dut, 0x100, WORD)
    _, line = await read(dut, 0x100, LINE)
    check_equal(word, frame_clocks(dut, WORD), "word frame")
    check_equal(line, frame_clocks(dut, LINE), "line frame")
    await check_chip(dut)


@cocotb.test()
async def test_random_requests(dut: Dut):
    """Check a sequence of word and line reads against the chip."""
    await start(dut)
    rng = Prng(0x5EED)
    window = generic(dut, "window_bytes")
    for _ in range(24):
        addr = rng.randrange(window)
        line = rng.randrange(2)
        words, _ = await read(dut, addr, line)
        check_equal(words, expected(dut, addr, line), f"{addr:#x} {line}")
    await check_chip(dut)
