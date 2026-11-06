"""sram_ctrl.

The asynchronous SRAM controller against the chip model: the contract of
the RAM chip (word and line accesses, byte enables, the window, ready held
until advance and the data changing on advance) and the clocks per access
that follow from the timing generics. The chip model fails the simulation
when the controller breaks a chip timing, so a test that finishes also
proved the timing.

"""

import math

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import Prng, check_equal
from tests.python.unittests.dut import Dut

REGION = 0x40000000
SIZE = 65536
MASK32 = 0xFFFFFFFF


class Chip:
    """The reference content of the chip, in bytes."""

    def __init__(self) -> None:
        """Start with zeros, as the model does."""
        self.mem = bytearray(SIZE)

    def write(self, off: int, value: int, be: int) -> None:
        """Write the enabled bytes of a word at a word-aligned offset."""
        for b in range(4):
            if (be >> b) & 1:
                self.mem[off + b] = (value >> (8 * b)) & 0xFF

    def word(self, off: int) -> int:
        """Return the word at a word-aligned offset."""
        return int.from_bytes(self.mem[off : off + 4], "little")

    def line(self, off: int) -> list[int]:
        """Return the four words of the line that holds the offset."""
        base = off & ~15
        return [self.word(base + 4 * i) for i in range(4)]


# The chip keeps its content from one test to the next, so the reference does too.
CHIP = Chip()


def generic(dut: Dut, name: str) -> int:
    """Return an integer generic of the design."""
    return int(getattr(dut, name).value)


def window_base(dut: Dut) -> int:
    """Return the address of the first byte of the chip."""
    return REGION + generic(dut, "base_kib") * 1024


async def start(dut: Dut):
    """Start the clock and reset the DUT."""
    cocotb.start_soon(Clock(dut.i_clk, generic(dut, "clk_period_ns"), unit="ns").start())
    dut.i_rst.value = 1
    for name in ("i_rden", "i_wren", "i_advance", "i_line"):
        getattr(dut, name).value = 0
    dut.i_addr.value = 0
    dut.i_wdata.value = 0
    dut.i_byteena.value = 0xF
    dut.i_wdata_x.value = 0
    dut.i_byteena_x.value = 0xFFF
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)


async def access(dut: Dut, addr: int, timeout: int = 400):
    """Hold the access until ready, then advance. Return (word 0, words 1 to 3, clocks until ready)."""
    dut.i_addr.value = addr
    for n in range(1, timeout):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_ready.value) == 1:
            before = (int(dut.o_rdata.value), int(dut.o_rdata_x.value))
            # Ready holds, and the data stays until the pipeline advances.
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            check_equal(int(dut.o_ready.value), 1, "ready has to hold")
            check_equal((int(dut.o_rdata.value), int(dut.o_rdata_x.value)), before, "data holds until advance")
            dut.i_advance.value = 1
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            result = (int(dut.o_rdata.value), int(dut.o_rdata_x.value), n)
            dut.i_advance.value = 0
            dut.i_rden.value = 0
            dut.i_wren.value = 0
            dut.i_line.value = 0
            check_equal(int(dut.o_ready.value), 0, "ready drops on advance")
            return result
    raise AssertionError(f"no ready for {addr:#x}")


async def load(dut: Dut, addr: int, line: bool = False):
    """Read a word, or a line."""
    dut.i_line.value = int(line)
    dut.i_rden.value = 1
    return await access(dut, addr)


async def store(dut: Dut, addr: int, value: int, be: int = 0xF, words_x: int | None = None, be_x: int = 0xFFF):
    """Write a word, or a line when words_x holds words 1 to 3."""
    dut.i_line.value = int(words_x is not None)
    dut.i_wdata.value = value
    dut.i_byteena.value = be
    dut.i_wdata_x.value = words_x or 0
    dut.i_byteena_x.value = be_x
    dut.i_wren.value = 1
    return await access(dut, addr)


def split_x(x: int) -> list[int]:
    """Split the 96 bits of words 1 to 3 into words."""
    return [(x >> (32 * i)) & MASK32 for i in range(3)]


@cocotb.test()
async def test_read_clocks_follow_the_timing_generics(dut: Dut):
    """Check the clocks until ready of a word and of a line against the formula."""
    await start(dut)
    period = generic(dut, "clk_period_ns")
    margin = generic(dut, "margin_ns")
    n_rd = max(1, math.ceil((max(generic(dut, "t_aa_ns"), generic(dut, "t_rc_ns")) + margin) / period))
    base = window_base(dut)
    _, _, clocks = await load(dut, base + 0x100)
    check_equal(clocks, 1 + 2 * n_rd, "word")
    _, _, clocks = await load(dut, base + 0x110, line=True)
    check_equal(clocks, 1 + 8 * n_rd, "line")


@cocotb.test()
async def test_words_with_byte_enables(dut: Dut):
    """Check word stores with every byte-enable mask and the loads that follow."""
    await start(dut)
    base = window_base(dut)
    prng = Prng(0x5352)
    for mask in range(16):
        off = 0x200 + 16 * mask
        value = prng.getrandbits(32)
        await store(dut, base + off, value, be=mask)
        CHIP.write(off, value, mask)
        word, _, _ = await load(dut, base + off)
        check_equal(hex(word), hex(CHIP.word(off)), f"mask {mask:#x}")
    # Stores in sequence at the same word accumulate the bytes.
    for byte in range(4):
        await store(dut, base + 0x300, 0x11223344, be=1 << byte)
        CHIP.write(0x300, 0x11223344, 1 << byte)
    word, _, _ = await load(dut, base + 0x300)
    check_equal(hex(word), "0x11223344", "bytes accumulate")


@cocotb.test()
async def test_lines(dut: Dut):
    """Check line stores with byte masks and line loads against the reference."""
    await start(dut)
    base = window_base(dut)
    prng = Prng(0x4C494E45)
    for n in range(10):
        off = (prng.randrange(SIZE) & ~15)
        words = [prng.getrandbits(32) for _ in range(4)]
        be_x = prng.getrandbits(12) if n % 2 else 0xFFF
        be0 = prng.getrandbits(4) if n % 2 else 0xF
        await store(dut, base + off, words[0], be=be0, words_x=words[1] | (words[2] << 32) | (words[3] << 64), be_x=be_x)
        CHIP.write(off, words[0], be0)
        for i in range(3):
            CHIP.write(off + 4 * (i + 1), words[i + 1], (be_x >> (4 * i)) & 0xF)
        w0, x, _ = await load(dut, base + off + 4 * (n % 4), line=True)
        want = CHIP.line(off)
        check_equal([hex(w0)] + [hex(w) for w in split_x(x)], [hex(w) for w in want], f"line {off:#x}")


@cocotb.test()
async def test_random_accesses_match_the_reference(dut: Dut):
    """Check a random mix of word and line accesses against the reference."""
    await start(dut)
    base = window_base(dut)
    prng = Prng(0x52414E44)
    for _ in range(80):
        off = prng.randrange(SIZE) & ~3
        kind = prng.randrange(4)
        if kind == 0:
            value, be = prng.getrandbits(32), prng.getrandbits(4)
            await store(dut, base + off, value, be=be)
            CHIP.write(off, value, be)
        elif kind == 1:
            w0, x, _ = await load(dut, base + off, line=True)
            check_equal([hex(w0)] + [hex(w) for w in split_x(x)], [hex(w) for w in CHIP.line(off)], f"line {off:#x}")
        else:
            word, _, _ = await load(dut, base + off)
            check_equal(hex(word), hex(CHIP.word(off)), f"word {off:#x}")


@cocotb.test()
async def test_the_window(dut: Dut):
    """Check that accesses outside the chip read zero and write nothing."""
    await start(dut)
    base = window_base(dut)
    await store(dut, base + 0x40, 0xCAFEF00D)
    CHIP.write(0x40, 0xCAFEF00D, 0xF)
    word, _, _ = await load(dut, base + SIZE + 0x40)
    check_equal(word, 0, "above the chip reads zero")
    word, x, _ = await load(dut, base + SIZE, line=True)
    check_equal((word, x), (0, 0), "above the chip, line")
    await store(dut, base + SIZE + 0x40, 0xFFFFFFFF)
    if base > REGION:
        word, _, _ = await load(dut, base - 4)
        check_equal(word, 0, "below the chip reads zero")
        await store(dut, base - 4, 0xFFFFFFFF)
    word, _, _ = await load(dut, base + 0x40)
    check_equal(hex(word), "0xcafef00d", "the chip is intact")
