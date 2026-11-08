"""latency_counter.

The latency counting machine shared by the memory models: the last edge
of a count of N comes N edges after the one that loads it, a new load on
the last edge restarts the count, and a reset ends it.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut

MAX_COUNT = 255


async def start(dut: Dut):
    """Start the clock and reset the DUT."""
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    dut.i_rst.value = 1
    dut.i_load.value = 0
    dut.i_count.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await Timer(1, unit="ns")


async def load(dut: Dut, count: int):
    """Load a count on the next edge and return after that edge."""
    dut.i_count.value = count
    dut.i_load.value = 1
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    dut.i_load.value = 0


async def watch(dut: Dut, count: int):
    """Check the two outputs on the edges that follow a load.

    The value read after the edge k - 1 is the one the owner sees on the
    edge k.

    """
    effective = max(count, 1)
    for k in range(1, effective + 1):
        check_equal(int(dut.o_last.value), int(k == effective), f"last at {k}")
        check_equal(int(dut.o_wait.value), int(k < effective), f"wait at {k}")
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
    check_equal(int(dut.o_last.value), 0, "last once")
    check_equal(int(dut.o_wait.value), 0, "free after the count")


@cocotb.test()
async def test_the_last_edge_is_the_nth(dut: Dut):
    """Check the last edge for counts from zero to a few dozens."""
    await start(dut)
    for count in [*range(0, 40), 100, MAX_COUNT]:
        await load(dut, count)
        await watch(dut, count)


@cocotb.test()
async def test_idle_is_quiet(dut: Dut):
    """Check that nothing rises without a load."""
    await start(dut)
    for _ in range(20):
        check_equal(int(dut.o_last.value), 0)
        check_equal(int(dut.o_wait.value), 0)
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")


@cocotb.test()
async def test_a_load_on_the_last_edge_restarts(dut: Dut):
    """Check the chained counts of a line; the load wins."""
    await start(dut)
    await load(dut, 6)
    for _ in range(5):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
    check_equal(int(dut.o_last.value), 1)
    await load(dut, 4)
    await watch(dut, 4)


@cocotb.test()
async def test_a_load_in_the_middle_replaces_the_count(dut: Dut):
    """Check that a load before the end restarts the count."""
    await start(dut)
    await load(dut, 10)
    for _ in range(3):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
    await load(dut, 5)
    await watch(dut, 5)


@cocotb.test()
async def test_reset_ends_the_count(dut: Dut):
    """Check that a reset in the middle leaves no last edge."""
    await start(dut)
    await load(dut, 8)
    for _ in range(2):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    dut.i_rst.value = 0
    for _ in range(12):
        check_equal(int(dut.o_last.value), 0)
        check_equal(int(dut.o_wait.value), 0)
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
