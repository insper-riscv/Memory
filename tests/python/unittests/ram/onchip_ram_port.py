"""onchip_ram_port, and the ram_chip as its reference.

The adapter that puts the block RAM of the FPGA behind the line
contract of the memory side: bytes, lines, the window and the debug
port. The same tests run on the ram_chip (generic USE_CHIP), which is
the reference of the contract, so a difference between the two entries
is a difference of behaviour. The latency is the one thing that is not
shared, and onchip_ram_latency has it.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut
from tests.python.unittests.ram.ram_chip import (
    BASE,
    load,
    store,
    word,
)

WINDOW = 1 << 12  # 4 KB, the SIZE_BYTES of the entries
DEBUG_CLOCKS = 6  # clocks the debug port may take to show a word


def drive(dut: Dut, **values: int) -> None:
    """Drive the input ports named by the keywords."""
    for name, value in values.items():
        getattr(dut, name).value = value


async def clock_edges(dut: Dut, count: int = 1) -> None:
    """Wait for count clock edges and let the signals settle."""
    for _ in range(count):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")


async def advance(dut: Dut) -> None:
    """Let the pipeline advance for one edge and drop the request."""
    drive(dut, i_mem_advance=1)
    await clock_edges(dut)
    drive(dut, i_mem_advance=0, i_rden=0)


async def stall_then_advance(dut: Dut, addr: int, clocks: int):
    """Hold a read for some clocks, then advance.

    Returns (ready, data while held, data after the advance).

    """
    drive(dut, i_addr=addr, i_rden=1)
    await clock_edges(dut, clocks)
    held = (int(dut.o_ready.value), int(dut.o_rdata.value))
    await advance(dut)
    return held[0], held[1], int(dut.o_rdata.value)


async def start(dut: Dut):
    """Start the clock and reset the DUT."""
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    drive(
        dut,
        i_rst=1,
        i_rden=0,
        i_wren=0,
        i_mem_advance=0,
        i_line=0,
        i_flush=0,
        i_addr=BASE,
        i_wdata=0,
        i_byteena=0xF,
        i_wdata_x=0,
        i_byteena_x=0xFFF,
        i_dbg_word_addr=0,
    )
    await clock_edges(dut, 3)
    drive(dut, i_rst=0)
    await clock_edges(dut, 3)


async def debug_word(dut: Dut, index: int) -> int:
    """Read a word of the memory through the debug port."""
    drive(dut, i_dbg_word_addr=index)
    await clock_edges(dut, DEBUG_CLOCKS)
    return int(dut.o_dbg_word_data.value)


@cocotb.test()
async def test_a_word_is_written_and_read_back(dut: Dut):
    """Check that a stored word comes back, also by the debug port."""
    await start(dut)
    await store(dut, BASE + 0x100, 0xDEADBEEF)
    value, _, _ = await load(dut, BASE + 0x100)
    check_equal(value, 0xDEADBEEF)
    check_equal(await debug_word(dut, 0x100 // 4), 0xDEADBEEF)


@cocotb.test()
async def test_byte_enables_keep_the_other_bytes(dut: Dut):
    """Check that only the enabled bytes change, for every mask."""
    await start(dut)
    a = BASE + 0x40
    for be in range(16):
        await store(dut, a, 0x11223344)
        await store(dut, a, 0xAABBCCDD, be=be)
        value, _, _ = await load(dut, a)
        expected = 0x11223344
        for b in range(4):
            if (be >> b) & 1:
                mask = 0xFF << (8 * b)
                expected = (expected & ~mask) | (0xAABBCCDD & mask)
        check_equal(value, expected, f"mask {be:04b}")


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
        check_equal(await debug_word(dut, 0x200 // 4 + i), w)
    value, extra, _ = await load(dut, a + 8, line=True)
    check_equal(value, words[0], "a line starts at the 16-byte boundary")
    check_equal(extra, words[1] | (words[2] << 32) | (words[3] << 64))


@cocotb.test()
async def test_a_line_write_keeps_the_masked_bytes(dut: Dut):
    """Check the byte enables of words 1 to 3 of a line write."""
    await start(dut)
    a = BASE + 0x300
    for i in range(4):
        await store(dut, a + 4 * i, 0xFFFFFFFF)
    dut.i_byteena_x.value = 0x020
    await store(dut, a, 0, words_x=0, be=0x0)
    dut.i_byteena_x.value = 0xFFF
    value, extra, _ = await load(dut, a, line=True)
    check_equal(value, 0xFFFFFFFF)
    check_equal(extra, 0xFFFFFFFF | (0xFFFF00FF << 32) | (0xFFFFFFFF << 64))


@cocotb.test()
async def test_the_read_data_changes_on_advance(dut: Dut):
    """Check that ready holds, and the data changes only on advance."""
    await start(dut)
    await store(dut, BASE + 0x10, 0x1111)
    await store(dut, BASE + 0x14, 0x2222)
    first, _, _ = await load(dut, BASE + 0x10)
    check_equal(first, 0x1111)
    ready, held, after = await stall_then_advance(dut, BASE + 0x14, 20)
    check_equal(ready, 1, "ready waits for advance")
    check_equal(held, 0x1111, "the old word until advance")
    check_equal(after, 0x2222)


@cocotb.test()
async def test_outside_the_window_reads_zero_and_drops_stores(dut: Dut):
    """Check that the window ends where it should."""
    await start(dut)
    writes = {BASE + WINDOW - 4: 0xAAAA5555, BASE + WINDOW: 0x12345678}
    for addr, value in writes.items():
        await store(dut, addr, value)
    expected = {
        BASE + WINDOW: 0,  # a read outside the window is zero
        BASE + WINDOW - 4: 0xAAAA5555,  # the last word is kept
        BASE: 0,  # the store outside did not wrap around
    }
    for addr, want in expected.items():
        value, _, _ = await load(dut, addr)
        check_equal(value, want, f"{addr:#x}")


@cocotb.test()
async def test_the_debug_port_ends_with_the_window(dut: Dut):
    """Check that the debug port reads zero beyond the last word."""
    await start(dut)
    await store(dut, BASE + WINDOW - 4, 0xCAFE0001)
    check_equal(await debug_word(dut, WINDOW // 4 - 1), 0xCAFE0001)
    check_equal(await debug_word(dut, WINDOW // 4), 0)
    check_equal(await debug_word(dut, 1 << 20), 0)
