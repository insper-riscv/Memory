"""The cacheless FLASH fetch path end to end.

Fetch bridge, two region routers, the FLASH arbiter and the chip, with
the chip at 24 clocks to the first word and 4 between words.

"""

import cocotb
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.cache.flash_path import (
    FLASH,
    SDRAM,
    start,
    word,
)
from tests.python.unittests.checks import check_equal, check_true, log_info
from tests.python.unittests.dut import Dut

FIRST_LATENCY = 24  # clocks to the first word of the chip
NEXT_LATENCY = 4  # clocks between two words of a line of the chip
LINE_WORDS = 4


async def fetch(dut: Dut, addr: int, timeout: int = 400):
    """Hold addr until ready, the way the core does.

    Returns (data, clocks waited).

    """
    dut.i_addr.value = addr
    dut.i_sel.value = 1
    for n in range(timeout):
        await Timer(1, unit="ns")
        if int(dut.o_ready.value) == 1:
            return int(dut.o_data.value), n
        await RisingEdge(dut.i_clk)
    raise AssertionError(f"no instruction for {addr:#x}")


async def run_trace(dut: Dut, trace: list[int]):
    """Fetch a program counter trace and check each word.

    The PC only moves to the next entry once ready is high, and it
    moves on the clock edge, as in the fetch stage of the core. Returns
    the clocks the whole trace took.

    """
    total = 0
    for addr in trace:
        data, waited = await fetch(dut, addr)
        check_equal(data, word(addr), f"{addr:#x}")
        total += waited + 1
        await RisingEdge(dut.i_clk)
    return total


async def b_request(dut: Dut, addr: int, timeout: int = 400):
    """Read a line on port B and return it as four words."""
    dut.i_b_addr.value = addr
    dut.i_b_rden.value = 1
    dut.i_b_line.value = 1
    for _ in range(timeout):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_b_ready.value) == 1:
            r, rx = int(dut.o_b_rdata.value), int(dut.o_b_rdata_x.value)
            dut.i_b_advance.value = 1
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            dut.i_b_rden.value = 0
            dut.i_b_advance.value = 0
            return [r] + [(rx >> (32 * i)) & 0xFFFFFFFF for i in range(3)]
    raise AssertionError(f"no ready for B at {addr:#x}")


async def pulse_invalidate(dut: Dut):
    """Raise i_invalidate for one clock, as a fence.i does."""
    dut.i_invalidate.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_invalidate.value = 0


def chip_requests(dut: Dut) -> int:
    """Return how many requests the chip has accepted."""
    return int(dut.o_chip_reqs.value)


@cocotb.test()
async def test_first_fetch_waits_for_the_chip(dut: Dut):
    """Check that the first instruction takes the chip latency."""
    await start(dut)
    a = FLASH + 0x10230
    data, waited = await fetch(dut, a)
    check_equal(data, word(a))
    check_true(waited > FIRST_LATENCY, f"waited only {waited} clocks")
    check_equal(chip_requests(dut), 1)
    check_equal(int(dut.o_si_rden.value), 0)


@cocotb.test()
async def test_sequential_pc_pays_the_latency_once_per_line(dut: Dut):
    """Check the clocks of a sequential run of 64 instructions."""
    await start(dut)
    base = FLASH + 0x400
    total = await run_trace(dut, [base + 4 * i for i in range(64)])
    check_equal(chip_requests(dut), 64 // LINE_WORDS)
    line_clocks = FIRST_LATENCY + NEXT_LATENCY * (LINE_WORDS - 1)
    per_line = total / (64 // LINE_WORDS)
    log_info(f"sequential: {total / 64:.2f} clocks per instruction")
    check_true(line_clocks <= per_line <= line_clocks + 12, per_line)


@cocotb.test()
async def test_branches_get_the_right_word(dut: Dut):
    """Check forward and backward branches and a loop on one word."""
    await start(dut)
    base = FLASH + 0x800
    trace = [base, base + 4, base + 0x200, base + 0x204, base + 4, base]
    trace += [base + 0x400] * 3 + [base + 0x404]
    await run_trace(dut, trace)


@cocotb.test()
async def test_a_branch_during_the_wait_pays_the_rest_of_it(dut: Dut):
    """Check that a branch while the chip is waiting still lands."""
    await start(dut)
    a, b = FLASH + 0x500, FLASH + 0x900
    dut.i_addr.value = a
    for _ in range(8):  # well inside the 24 clocks of the chip
        await RisingEdge(dut.i_clk)
    data, waited = await fetch(dut, b)
    check_equal(data, word(b))
    check_true(waited > FIRST_LATENCY - 8, "the old request cannot abort")
    check_equal(chip_requests(dut), 2)


@cocotb.test()
async def test_the_pc_holds_while_ready_is_low(dut: Dut):
    """Check that ready is low during the wait and then stays high."""
    await start(dut)
    a = FLASH + 0xC00
    dut.i_addr.value = a
    dut.i_sel.value = 1
    low = 0
    for _ in range(FIRST_LATENCY // 2):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        low += 1 - int(dut.o_ready.value)
    check_equal(low, FIRST_LATENCY // 2)
    data, _ = await fetch(dut, a)
    check_equal(data, word(a))
    for _ in range(30):  # the core stalls elsewhere: nothing changes
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        check_equal(int(dut.o_ready.value), 1)
        check_equal(int(dut.o_data.value), word(a))
    check_equal(chip_requests(dut), 1)


@cocotb.test()
async def test_fence_i_refetches_the_word(dut: Dut):
    """Check that fence.i leaves nothing of the held line."""
    await start(dut)
    a = FLASH + 0xA00
    await fetch(dut, a)
    check_equal(chip_requests(dut), 1)
    await pulse_invalidate(dut)
    await Timer(1, unit="ns")
    check_equal(int(dut.o_ready.value), 0)
    data, _ = await fetch(dut, a)
    check_equal(data, word(a))
    check_equal(chip_requests(dut), 2)


@cocotb.test()
async def test_fence_i_during_the_wait_drops_the_arriving_word(dut: Dut):
    """Check that a word that arrives after fence.i is refetched."""
    await start(dut)
    a = FLASH + 0xE00
    dut.i_addr.value = a
    for _ in range(10):
        await RisingEdge(dut.i_clk)
    await pulse_invalidate(dut)
    data, _ = await fetch(dut, a)
    check_equal(data, word(a))
    check_equal(chip_requests(dut), 2)


@cocotb.test()
async def test_the_data_master_shares_the_chip(dut: Dut):
    """Check that a line read of port B and a fetch both get theirs."""
    await start(dut)
    b = cocotb.start_soon(b_request(dut, FLASH + 0x800))
    data, _ = await fetch(dut, FLASH + 0x100)
    got = await b
    check_equal(data, word(FLASH + 0x100))
    check_equal(got, [word(FLASH + 0x800 + 4 * i) for i in range(4)])
    check_equal(chip_requests(dut), 2)


@cocotb.test()
async def test_a_sdram_address_goes_to_the_sdram_side(dut: Dut):
    """Check that the region of the address picks the side."""
    await start(dut)
    dut.i_addr.value = SDRAM + 0x40
    dut.i_sel.value = 1
    seen = 0
    for _ in range(30):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        seen |= int(dut.o_si_rden.value)
    check_equal(seen, 1, "the fetch has to be steered to the SDRAM side")
    check_equal(chip_requests(dut), 0)
