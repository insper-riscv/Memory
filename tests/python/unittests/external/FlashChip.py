"""flash_chip: the FLASH chip model, against a storage model with a registered read."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

FIRST = 24
NEXT = 4


def word(addr):
    """The content of the storage at a byte address."""
    return ((addr * 2654435761) ^ 0x5A5A1234) & 0xFFFFFFFF


async def storage(dut):
    """A memory with a registered read: the word of the address before the edge."""
    while True:
        await RisingEdge(dut.i_clk)
        dut.i_mem_data.value = word(int(dut.o_mem_addr.value) & ~3)


async def start(dut):
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    dut.i_rst.value = 1
    dut.i_rden.value = 0
    dut.i_line.value = 0
    dut.i_advance.value = 0
    dut.i_addr.value = 0
    dut.i_mem_data.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    cocotb.start_soon(storage(dut))


async def request(dut, addr, line, timeout=500):
    """Hold the request until ready, then advance; returns (words, clocks waited)."""
    dut.i_addr.value = addr
    dut.i_line.value = line
    dut.i_rden.value = 1
    for n in range(timeout):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_ready.value) == 1:
            words = [int(dut.o_rdata.value)]
            if line:
                x = int(dut.o_rdata_x.value)
                words += [(x >> (32 * i)) & 0xFFFFFFFF for i in range(3)]
            dut.i_rden.value = 0
            dut.i_advance.value = 1
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            dut.i_advance.value = 0
            assert int(dut.o_ready.value) == 0, (
                "ready has to drop once the request advances"
            )
            return words, n
    raise AssertionError(f"no ready for {addr:#x} after {timeout} clocks")


@cocotb.test()
async def test_line_comes_whole_and_aligned(dut):
    await start(dut)
    # an address in the middle of the line still returns the line from its start
    words, _ = await request(dut, 0x20001238, 1)
    base = 0x20001230
    assert words == [word(base + 4 * i) for i in range(4)]


@cocotb.test()
async def test_a_single_word(dut):
    await start(dut)
    words, _ = await request(dut, 0x20000044, 0)
    assert words == [word(0x20000044)]


@cocotb.test()
async def test_latency_follows_the_generics(dut):
    await start(dut)
    _, line_wait = await request(dut, 0x20000100, 1)
    _, word_wait = await request(dut, 0x20000200, 0)
    # first word after FIRST edges, each of the other three NEXT edges later
    assert line_wait == word_wait + 3 * NEXT, (line_wait, word_wait)
    assert FIRST <= word_wait <= FIRST + 3


@cocotb.test()
async def test_ready_holds_until_advance(dut):
    await start(dut)
    dut.i_addr.value = 0x20000300
    dut.i_line.value = 1
    dut.i_rden.value = 1
    for _ in range(FIRST + 3 * NEXT + 10):
        await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    assert int(dut.o_ready.value) == 1
    first = int(dut.o_rdata.value)
    for _ in range(5):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        assert int(dut.o_ready.value) == 1
        assert int(dut.o_rdata.value) == first


@cocotb.test()
async def test_back_to_back_requests(dut):
    await start(dut)
    for k in range(6):
        addr = 0x20000000 + 0x40 * k
        words, _ = await request(dut, addr, 1)
        assert words == [word(addr + 4 * i) for i in range(4)]


@cocotb.test()
async def test_a_request_outside_the_window_reads_zero(dut):
    await start(dut)
    # bits 25:20 set: past the 1 MB window of the chip
    words, _ = await request(dut, 0x20100000, 1)
    assert words == [0, 0, 0, 0]
    words, _ = await request(dut, 0x23F00040, 0)
    assert words == [0]
    # the last line inside the window still reads the storage
    words, _ = await request(dut, 0x200FFFF0, 1)
    assert words == [word(0x200FFFF0 + 4 * i) for i in range(4)]


@cocotb.test()
async def test_busy_covers_the_latency_of_a_request(dut):
    await start(dut)
    busy = 0

    async def watch():
        nonlocal busy
        while True:
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            busy += int(dut.o_busy.value)

    cocotb.start_soon(watch())
    await request(dut, 0x20000500, 1)
    # one request of four words waits FIRST + 3 * NEXT clocks in the chip
    assert busy == FIRST + 3 * NEXT, busy
