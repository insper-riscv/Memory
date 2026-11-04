"""onchip_ram_port, the latency and the debug port under traffic.

The latency of the adapter is low and constant: two clocks after the
one that sees the request for a word, five for a line, the same for a
read and for a write. The debug port keeps working while an access sits
in ready waiting for the pipeline.

"""

import cocotb
from cocotb.triggers import RisingEdge

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut
from tests.python.unittests.ram.onchip_ram_port import (
    advance,
    clock_edges,
    debug_word,
    drive,
    start,
)
from tests.python.unittests.ram.ram_chip import BASE, load, store, word

WORD_CLOCKS = 3  # edges until ready is seen, counting the first
LINE_CLOCKS = 6


@cocotb.test()
async def test_the_latency_of_a_word_is_constant(dut: Dut):
    """Check the same clocks for reads and writes, at any address."""
    await start(dut)
    for a in (0x0, 0x44, 0xFFC):
        _, _, waited = await store(dut, BASE + a, word(a))
        check_equal(waited, WORD_CLOCKS, f"store at {a:#x}")
        _, _, waited = await load(dut, BASE + a)
        check_equal(waited, WORD_CLOCKS, f"load at {a:#x}")


@cocotb.test()
async def test_the_latency_of_a_line_is_constant(dut: Dut):
    """Check the same clocks for a line read and a line write."""
    await start(dut)
    for a in (0x0, 0x40, 0xFF0):
        _, _, waited = await store(dut, BASE + a, 1, words_x=2)
        check_equal(waited, LINE_CLOCKS, f"line store at {a:#x}")
        _, _, waited = await load(dut, BASE + a, line=True)
        check_equal(waited, LINE_CLOCKS, f"line load at {a:#x}")


@cocotb.test()
async def test_the_outside_of_the_window_takes_the_same_time(dut: Dut):
    """Check that an access beyond the window is not faster."""
    await start(dut)
    _, _, waited = await load(dut, BASE + 0x1000)
    check_equal(waited, WORD_CLOCKS)


@cocotb.test()
async def test_the_debug_port_reads_while_ready_waits(dut: Dut):
    """Check the debug port while an access waits for the advance."""
    await start(dut)
    await store(dut, BASE + 0x20, 0xA5A5A5A5)
    await store(dut, BASE + 0x24, 0x5A5A5A5A)
    drive(dut, i_addr=BASE + 0x20, i_rden=1)
    await clock_edges(dut, 8)
    check_equal(int(dut.o_ready.value), 1)
    check_equal(await debug_word(dut, 0x24 // 4), 0x5A5A5A5A)
    check_equal(await debug_word(dut, 0x20 // 4), 0xA5A5A5A5)
    check_equal(int(dut.o_ready.value), 1, "the debug read kept ready")
    await advance(dut)
    check_equal(int(dut.o_rdata.value), 0xA5A5A5A5)


@cocotb.test()
async def test_the_debug_port_does_not_disturb_an_access(dut: Dut):
    """Check that a debug index changing at every clock is harmless."""
    await start(dut)
    for i in range(4):
        await store(dut, BASE + 4 * i, word(i))

    async def sweep():
        for k in range(400):
            drive(dut, i_dbg_word_addr=k % 8)
            await RisingEdge(dut.i_clk)

    cocotb.start_soon(sweep())
    for i in range(4):
        value, _, _ = await load(dut, BASE + 4 * i)
        check_equal(value, word(i))
        await store(dut, BASE + 4 * i, word(i + 100))
        value, _, _ = await load(dut, BASE + 4 * i)
        check_equal(value, word(i + 100))
