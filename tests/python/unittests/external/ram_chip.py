"""ram_chip.

The RAM model that stands for the SDRAM of the board in the simulated
platforms: both ports, bytes, lines, the window and the contract of the
bridge (ready stays up until advance, the data changes on advance).

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

BASE = 0x40000000
LATENCY = 8  # the generic's default
WINDOW = 1 << 20  # 1 MB


def word(addr: int) -> int:
    """Return a data word that depends on its address."""
    return ((addr * 2654435761) ^ 0x5A5A0000) & 0xFFFFFFFF


async def start(dut: Dut):
    """Start the clock and reset the DUT."""
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    dut.i_rst.value = 1
    for name in ("i_rden", "i_wren", "i_mem_advance", "i_line"):
        getattr(dut, name).value = 0
    dut.i_ins_rden.value = 0
    dut.i_ins_advance.value = 0
    dut.i_ins_line.value = 0
    dut.i_addr.value = BASE
    dut.i_wdata.value = 0
    dut.i_byteena.value = 0xF
    dut.i_wdata_x.value = 0
    dut.i_byteena_x.value = 0xFFF
    dut.i_dbg_word_addr.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)


async def finish(dut: Dut, addr: int, timeout: int = 100):
    """Hold the access of the data port until ready, then advance.

    Returns (word 0, words 1 to 3, clocks until ready).

    """
    dut.i_addr.value = addr
    for n in range(1, timeout):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_ready.value) == 1:
            dut.i_mem_advance.value = 1
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            # the data of the access shows up on the edge of advance
            result = (int(dut.o_rdata.value), int(dut.o_rdata_x.value), n)
            dut.i_mem_advance.value = 0
            dut.i_rden.value = 0
            dut.i_wren.value = 0
            dut.i_line.value = 0
            return result
    raise AssertionError(f"no ready for {addr:#x}")


async def load(dut: Dut, addr: int, line: bool = False):
    """Read a word, or a line, through the data port."""
    dut.i_line.value = int(line)
    dut.i_rden.value = 1
    return await finish(dut, addr)


async def store(
    dut: Dut,
    addr: int,
    value: int,
    be: int = 0xF,
    words_x: int | None = None,
):
    """Write a word, or a line when words_x holds words 1 to 3."""
    dut.i_line.value = int(words_x is not None)
    dut.i_wdata.value = value
    dut.i_byteena.value = be
    dut.i_wdata_x.value = words_x or 0
    dut.i_wren.value = 1
    return await finish(dut, addr)


async def instruction(
    dut: Dut, addr: int, line: bool = False, timeout: int = 100
):
    """One access of the instruction port.

    Returns (word 0, words 1 to 3, clocks until ready).

    """
    dut.i_ins_addr.value = addr
    dut.i_ins_line.value = int(line)
    dut.i_ins_rden.value = 1
    for n in range(1, timeout):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_ins_ready.value) == 1:
            dut.i_ins_advance.value = 1
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            result = (
                int(dut.o_ins_rdata.value),
                int(dut.o_ins_rdata_x.value),
                n,
            )
            dut.i_ins_advance.value = 0
            dut.i_ins_rden.value = 0
            dut.i_ins_line.value = 0
            return result
    raise AssertionError(f"no ready for {addr:#x}")


async def debug_word(dut: Dut, index: int) -> int:
    """Read a word of the chip through the debug port."""
    dut.i_dbg_word_addr.value = index
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    return int(dut.o_dbg_word_data.value)


@cocotb.test()
async def test_a_word_is_written_and_read_back(dut: Dut):
    """Check that a stored word comes back and takes the latency."""
    await start(dut)
    _, _, waited = await store(dut, BASE + 0x100, 0xDEADBEEF)
    check_true(waited >= LATENCY, f"the store took only {waited} clocks")
    value, _, waited = await load(dut, BASE + 0x100)
    check_equal(value, 0xDEADBEEF)
    check_true(waited >= LATENCY, f"the load took only {waited} clocks")
    check_equal(await debug_word(dut, 0x100 // 4), 0xDEADBEEF)


@cocotb.test()
async def test_byte_enables_keep_the_other_bytes(dut: Dut):
    """Check that only the enabled bytes change."""
    await start(dut)
    a = BASE + 0x40
    await store(dut, a, 0x11223344)
    await store(dut, a, 0xAABBCCDD, be=0b0101)
    value, _, _ = await load(dut, a)
    check_equal(value, 0x11BB33DD)


@cocotb.test()
async def test_a_line_is_written_and_read_back(dut: Dut):
    """Check that a line write and a line read move four words."""
    await start(dut)
    a = BASE + 0x200
    words = [word(a + 4 * i) for i in range(4)]
    await store(
        dut,
        a,
        words[0],
        words_x=words[1] | (words[2] << 32) | (words[3] << 64),
    )
    for i, w in enumerate(words):
        check_equal(await debug_word(dut, a // 4 % (1 << 18) + i), w)
    value, extra, _ = await load(dut, a + 8, line=True)
    check_equal(value, words[0], "a line starts at the 16-byte boundary")
    check_equal(extra, words[1] | (words[2] << 32) | (words[3] << 64))


@cocotb.test()
async def test_the_read_data_changes_on_advance(dut: Dut):
    """Check that ready holds, and the data changes only on advance."""
    await start(dut)
    await store(dut, BASE + 0x10, 0x1111)
    await store(dut, BASE + 0x14, 0x2222)
    first, _, _ = await load(dut, BASE + 0x10)
    check_equal(first, 0x1111)
    dut.i_addr.value = BASE + 0x14
    dut.i_rden.value = 1
    for _ in range(LATENCY + 3):
        await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    check_equal(int(dut.o_ready.value), 1, "ready waits for advance")
    check_equal(int(dut.o_rdata.value), 0x1111, "the old word until advance")
    dut.i_mem_advance.value = 1
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    dut.i_mem_advance.value = 0
    dut.i_rden.value = 0
    check_equal(int(dut.o_rdata.value), 0x2222)


@cocotb.test()
async def test_the_instruction_port_sees_the_stores_of_the_data_port(
    dut: Dut,
):
    """Check that a store is fetched, as a line and as a word."""
    await start(dut)
    a = BASE + 0x300
    for i in range(4):
        await store(dut, a + 4 * i, word(a + 4 * i))
    value, _, _ = await instruction(dut, a + 4)
    check_equal(value, word(a + 4))
    value, extra, _ = await instruction(dut, a, line=True)
    check_equal(value, word(a))
    check_equal(
        extra,
        word(a + 4) | (word(a + 8) << 32) | (word(a + 12) << 64),
    )


@cocotb.test()
async def test_outside_the_window_reads_zero_and_drops_stores(dut: Dut):
    """Check that the 1 MB window ends where it should."""
    await start(dut)
    inside = BASE + WINDOW - 4
    outside = BASE + WINDOW
    await store(dut, inside, 0xAAAA5555)
    await store(dut, outside, 0x12345678)
    value, _, _ = await load(dut, outside)
    check_equal(value, 0, "a read outside the window is zero")
    value, _, _ = await load(dut, inside)
    check_equal(value, 0xAAAA5555, "the last word of the window is kept")
    value, _, _ = await load(dut, BASE)
    check_equal(value, 0, "the store outside did not wrap around")
