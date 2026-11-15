"""max10_xip.

The direct read adapter of the MAX 10 user flash against the model of
the on-chip flash megafunction: the content is programmed through the
register bank of the controller, then read through the adapter on the
same Avalon data interface. It covers word and line reads with the
contract of the flash chip, the window that starts at the base word,
the zero of a read outside it, and that the adapter never asks the
megafunction for a write.

"""

import cocotb
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import Prng, check_equal, check_true
from tests.python.unittests.dut import Dut
from tests.python.unittests.flashface import read, start
from tests.python.unittests.regbus import clear_flags, reg_write, wait_done

ADDRESS, DATA, COMMAND = 2, 3, 5
WRITE, ENABLE = 2, 4
WORD, LINE = 0, 1


def generic(dut: Dut, name: str) -> int:
    """Return an integer generic of the design."""
    return int(getattr(dut, name).value)


def content(word: int) -> int:
    """Return the word programmed at a word of the data space."""
    return (word * 0x01010101 + 0x0F1E2D3C) & 0xFFFFFFFF


async def program(dut: Dut) -> None:
    """Program the whole window through the register bank."""
    dut.i_sel_xip.value = 0
    await reg_write(dut, COMMAND, ENABLE)
    await wait_done(dut)
    await clear_flags(dut)
    base = generic(dut, "base_word")
    for word in range(base, base + generic(dut, "window_bytes") // 4):
        await reg_write(dut, ADDRESS, word)
        await reg_write(dut, DATA, content(word))
        await reg_write(dut, COMMAND, WRITE)
        await wait_done(dut)
        await clear_flags(dut)
    dut.i_sel_xip.value = 1


def expected(dut: Dut, addr: int, line: int) -> list[int]:
    """Return the words of a request inside the window."""
    window = generic(dut, "window_bytes")
    size = 16 if line else 4
    first = (addr & ~(size - 1)) & (window - 1)
    base = generic(dut, "base_word") + first // 4
    return [content(base + i) for i in range(size // 4)]


async def prepare(dut: Dut) -> None:
    """Reset, then program the window."""
    dut.i_sel_xip.value = 0
    dut.i_write.value = 0
    dut.i_read.value = 0
    dut.i_address.value = 0
    dut.i_data_in.value = 0
    await start(dut)
    await program(dut)


@cocotb.test()
async def test_word_reads_the_window_from_the_base_word(dut: Dut):
    """Check that a word read returns the words programmed there."""
    await prepare(dut)
    window = generic(dut, "window_bytes")
    for addr in (0, 4, 0x40, window - 4):
        words, _ = await read(dut, addr, WORD)
        check_equal(words, expected(dut, addr, WORD), f"word {addr:#x}")
    check_equal(int(dut.o_data_write.value), 0, "the adapter never writes")


@cocotb.test()
async def test_line_reads_four_words_aligned_to_the_line(dut: Dut):
    """Check that a line starts at the 16-byte aligned address."""
    await prepare(dut)
    window = generic(dut, "window_bytes")
    for addr in (0, 0x10, window - 16):
        words, _ = await read(dut, addr, LINE)
        check_equal(words, expected(dut, addr, LINE), f"line {addr:#x}")
    words, _ = await read(dut, 0x4C, LINE)
    check_equal(words, expected(dut, 0x40, LINE), "unaligned line address")
    words, _ = await read(dut, 0x4E, WORD)
    check_equal(words, expected(dut, 0x4C, WORD), "unaligned word address")


@cocotb.test()
async def test_read_outside_the_window_is_zero(dut: Dut):
    """Check that a read past the window returns zero at once."""
    await prepare(dut)
    window = generic(dut, "window_bytes")
    for line in (WORD, LINE):
        dut.i_addr.value = window
        dut.i_line.value = line
        dut.i_rden.value = 1
        await RisingEdge(dut.i_clk)
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        check_equal(int(dut.o_ready.value), 1, "answers at once")
        check_equal(int(dut.o_rdata.value), 0, "word 0 is zero")
        if line:
            check_equal(int(dut.o_rdata_x.value), 0, "words 1 to 3 are zero")
        dut.i_rden.value = 0
        dut.i_advance.value = 1
        await RisingEdge(dut.i_clk)
        dut.i_advance.value = 0
        await Timer(1, unit="ns")
    words, _ = await read(dut, 0, LINE)
    check_equal(words, expected(dut, 0, LINE), "the next read is normal")


@cocotb.test()
async def test_line_takes_four_reads_of_the_megafunction(dut: Dut):
    """Check that a line costs four times the reads of a word."""
    await prepare(dut)
    _, word = await read(dut, 0x20, WORD)
    _, line = await read(dut, 0x20, LINE)
    check_true(line > 3 * word, "four sequential reads")
    check_equal(int(dut.o_data_write.value), 0, "the adapter never writes")


@cocotb.test()
async def test_random_requests(dut: Dut):
    """Check a sequence of word and line reads against the content."""
    await prepare(dut)
    rng = Prng(0xC0DE)
    window = generic(dut, "window_bytes")
    for _ in range(24):
        addr = rng.randrange(window)
        line = rng.randrange(2)
        words, _ = await read(dut, addr, line)
        check_equal(words, expected(dut, addr, line), f"{addr:#x} {line}")
