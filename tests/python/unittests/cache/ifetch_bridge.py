"""ifetch_bridge.

The cacheless instruction fetch bridge alone, against a memory model
with a variable latency. The bridge asks for the 16-byte line that holds
the fetch address, so sequential code pays the latency once per line.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

BASE = 0x40000000
FLASH = 0x20000000
LAT = 5
LINE_BYTES = 16


def word(addr: int, version: int = 0) -> int:
    """Return the content of the memory model at a word address."""
    return ((addr * 2654435761) ^ (0xA5A50000 + version)) & 0xFFFFFFFF


class Memory:
    """Answers each request after a latency, and records them."""

    def __init__(self, dut: Dut, latency: int = LAT):
        """Bind the model to the DUT."""
        self.dut = dut
        self.latency = latency
        self.version = 0
        self.requests: list[int] = []
        self.lines: list[int] = []
        self.misses = 0

    async def run(self):
        """Drive the slave side of the port, clock by clock."""
        dut = self.dut
        dut.i_d_ready.value = 0
        while True:
            await RisingEdge(dut.i_clk)
            self.misses += int(dut.o_miss.value)
            if int(dut.o_d_rden.value) == 1:
                addr = int(dut.o_d_addr.value)
                line = int(dut.o_d_line.value)
                self.requests.append(addr)
                self.lines.append(line)
                for _ in range(self.latency):
                    await RisingEdge(dut.i_clk)
                    # The request is held until it is answered.
                    check_equal(int(dut.o_d_rden.value), 1)
                    check_equal(int(dut.o_d_addr.value), addr)
                words = [word(addr + 4 * i, self.version) for i in range(4)]
                dut.i_d_rdata.value = words[0]
                dut.i_d_rdata_x.value = (
                    words[1] | (words[2] << 32) | (words[3] << 64)
                )
                dut.i_d_ready.value = 1
                await RisingEdge(dut.i_clk)
                check_equal(int(dut.o_d_advance.value), 1)
                dut.i_d_ready.value = 0


async def start(dut: Dut):
    """Start the clock and reset the DUT."""
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    dut.i_rst.value = 1
    dut.i_addr.value = BASE
    dut.i_sel.value = 1
    dut.i_invalidate.value = 0
    dut.i_d_ready.value = 0
    dut.i_d_rdata.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    mem = Memory(dut)
    cocotb.start_soon(mem.run())
    return mem


async def fetch(dut: Dut, addr: int, timeout: int = 200):
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
    raise AssertionError(f"no ready for {addr:#x} after {timeout} clocks")


async def pulse_invalidate(dut: Dut):
    """Raise i_invalidate for one clock, as a fence.i does."""
    dut.i_invalidate.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_invalidate.value = 0


@cocotb.test()
async def test_miss_then_hits_in_the_line(dut: Dut):
    """Check that a miss waits and the rest of the line does not."""
    mem = await start(dut)
    base = BASE + 0x1230
    data, waited = await fetch(dut, base)
    check_equal(data, word(base))
    check_true(waited > LAT, "the first fetch has to wait for the memory")
    check_equal(mem.requests, [base])
    check_equal(mem.lines, [1])
    for i in range(1, 4):
        data, waited = await fetch(dut, base + 4 * i)
        check_equal(data, word(base + 4 * i))
        check_equal(waited, 0, f"word {i} of the held line waited")
    check_equal(mem.requests, [base], "no second request for the line")


@cocotb.test()
async def test_sequential_code_across_lines(dut: Dut):
    """Check that sequential code asks for one line per four words."""
    mem = await start(dut)
    for i in range(64):
        a = BASE + 4 * i
        data, _ = await fetch(dut, a)
        check_equal(data, word(a), f"{a:#x}")
    check_equal(mem.requests, [BASE + 16 * k for k in range(16)])


@cocotb.test()
async def test_ready_drops_when_the_address_leaves_the_line(dut: Dut):
    """Check that ready falls with the address, not a clock later."""
    await start(dut)
    base = BASE + 0x200
    await fetch(dut, base)
    dut.i_addr.value = base + 16
    await Timer(1, unit="ns")
    check_equal(int(dut.o_ready.value), 0)


@cocotb.test()
async def test_a_held_address_makes_no_new_request(dut: Dut):
    """Check that a stall of the core does not refetch."""
    mem = await start(dut)
    a = BASE + 0x340
    await fetch(dut, a)
    for _ in range(50):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        check_equal(int(dut.o_ready.value), 1)
        check_equal(int(dut.o_data.value), word(a))
    check_equal(len(mem.requests), 1)


@cocotb.test()
async def test_branches_refetch_the_target(dut: Dut):
    """Check that a branch out of the line asks for the target line."""
    mem = await start(dut)
    a, b = BASE + 0x400, BASE + 0x900
    for addr in (a, a + 4, b, b + 8, a + 4, b):
        data, _ = await fetch(dut, addr)
        check_equal(data, word(addr), f"{addr:#x}")
    check_equal(mem.requests, [a, b, a, b])


@cocotb.test()
async def test_the_flash_region_keeps_its_base(dut: Dut):
    """Check that the request carries the base of the region."""
    mem = await start(dut)
    a = FLASH + 0x1230
    data, _ = await fetch(dut, a)
    check_equal(data, word(a))
    check_equal(mem.requests, [a])


@cocotb.test()
async def test_not_selected_never_ready_or_requests(dut: Dut):
    """Check that a non selected address neither answers nor asks."""
    mem = await start(dut)
    dut.i_addr.value = 0x00000100
    dut.i_sel.value = 0
    asked = 0
    for _ in range(40):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        asked |= int(dut.o_d_rden.value) | int(dut.o_ready.value)
    check_equal(asked, 0)
    check_equal(mem.requests, [])


@cocotb.test()
async def test_invalidate_drops_the_held_line(dut: Dut):
    """Check that fence.i makes the fetch read the memory again."""
    mem = await start(dut)
    a = BASE + 0x100
    await fetch(dut, a)
    mem.version = 1  # the program stored new code behind the bridge
    data, _ = await fetch(dut, a)
    check_equal(data, word(a, 0))
    await pulse_invalidate(dut)
    data, _ = await fetch(dut, a)
    check_equal(data, word(a, 1), "after the invalidate")
    check_equal(len(mem.requests), 2)


@cocotb.test()
async def test_invalidate_during_a_request_drops_its_word(dut: Dut):
    """Check that a word that arrives after fence.i is not kept."""
    mem = await start(dut)
    a = BASE + 0x300
    dut.i_addr.value = a
    dut.i_sel.value = 1
    for _ in range(4):  # the request is under way
        await RisingEdge(dut.i_clk)
    check_equal(len(mem.requests), 1)
    mem.version = 1
    await pulse_invalidate(dut)
    data, _ = await fetch(dut, a)
    check_equal(data, word(a, 1))
    check_equal(len(mem.requests), 2)


@cocotb.test()
async def test_address_change_during_a_request(dut: Dut):
    """Check that a branch during a request still gets the target."""
    mem = await start(dut)
    a, b = BASE + 0x500, BASE + 0x900
    dut.i_addr.value = a
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    data, _ = await fetch(dut, b)
    check_equal(data, word(b))
    check_equal(mem.requests, [a, b])


@cocotb.test()
async def test_one_miss_pulse_per_request(dut: Dut):
    """Check that o_miss pulses once for each request."""
    mem = await start(dut)
    for i in range(16):
        await fetch(dut, BASE + 4 * i)
    await RisingEdge(dut.i_clk)
    check_equal(len(mem.requests), 4)
    check_equal(mem.misses, 4)


@cocotb.test()
async def test_reset_drops_the_held_line(dut: Dut):
    """Check that the reset forgets the held line."""
    mem = await start(dut)
    a = BASE + 0x700
    await fetch(dut, a)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await Timer(1, unit="ns")
    check_equal(int(dut.o_ready.value), 0)
    await fetch(dut, a)
    check_equal(len(mem.requests), 2)
