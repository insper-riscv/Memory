"""icache.

The instruction cache alone, against a memory model with a variable
latency.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

BASE = 0x40000000
LAT = 5


def word(addr: int, version: int = 0) -> int:
    """Return the content of the memory model at a word address."""
    return ((addr * 2654435761) ^ (0xA5A50000 + version)) & 0xFFFFFFFF


class Memory:
    """Answers each line request after a latency, and counts them."""

    def __init__(self, dut: Dut, latency: int = LAT):
        """Bind the model to the DUT."""
        self.dut = dut
        self.latency = latency
        self.version = 0
        self.requests: list[int] = []

    async def run(self):
        """Drive the slave side of the port, clock by clock."""
        dut = self.dut
        dut.i_d_ready.value = 0
        while True:
            await RisingEdge(dut.i_clk)
            if int(dut.o_d_rden.value) == 1 and int(dut.o_d_line.value) == 1:
                addr = int(dut.o_d_addr.value)
                self.requests.append(addr)
                for _ in range(self.latency):
                    await RisingEdge(dut.i_clk)
                words = [word(addr + 4 * i, self.version) for i in range(4)]
                dut.i_d_rdata.value = words[0]
                dut.i_d_rdata_x.value = (
                    words[1] | (words[2] << 32) | (words[3] << 64)
                )
                dut.i_d_ready.value = 1
                await RisingEdge(dut.i_clk)
                dut.i_d_ready.value = 0


async def start(dut: Dut):
    """Start the clock and reset the DUT."""
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    # O mesmo clock nas duas entradas: o comportamento é o de um clock
    # só.
    cocotb.start_soon(Clock(dut.i_clk_cpu, 10, unit="ns").start())
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
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_ready.value) == 1:
            return int(dut.o_data.value), n
    raise AssertionError(f"no ready for {addr:#x} after {timeout} clocks")


@cocotb.test()
async def test_miss_then_hits_in_the_line(dut: Dut):
    """Check that miss then hits in the line."""
    mem = await start(dut)
    base = BASE + 0x1230
    data, waited = await fetch(dut, base)
    check_equal(data, word(base))
    check_true(waited > LAT, "the first fetch has to wait for the line")
    check_equal(mem.requests, [base])
    for i in range(1, 4):
        data, waited = await fetch(dut, base + 4 * i)
        check_equal(data, word(base + 4 * i))
        check_true(
            waited <= 1, f"word {i} of a line in the cache waited {waited}"
        )
    check_equal(mem.requests, [base], "no second request for the same line")


@cocotb.test()
async def test_sequential_code_across_lines(dut: Dut):
    """Check that sequential code across lines."""
    mem = await start(dut)
    for i in range(64):
        a = BASE + 4 * i
        data, _ = await fetch(dut, a)
        check_equal(data, word(a), f"{a:#x}")
    check_equal(len(mem.requests), 16)
    check_equal(mem.requests, [BASE + 16 * k for k in range(16)])


@cocotb.test()
async def test_conflict_evicts_the_line(dut: Dut):
    """Check that conflict evicts the line."""
    mem = await start(dut)
    a, b = BASE + 0x040, BASE + 0x040 + 0x1000  # same index, different tag
    for addr in (a, b, a):
        data, _ = await fetch(dut, addr)
        check_equal(data, word(addr))
    check_equal(mem.requests, [a & ~0xF, b & ~0xF, a & ~0xF])


@cocotb.test()
async def test_not_selected_never_hits_or_fills(dut: Dut):
    """Check that not selected never hits or fills."""
    mem = await start(dut)
    dut.i_addr.value = 0x00000100
    dut.i_sel.value = 0
    for _ in range(40):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        check_equal(int(dut.o_ready.value), 0)
    check_equal(mem.requests, [])


@cocotb.test()
async def test_invalidate_drops_every_line(dut: Dut):
    """Check that invalidate drops every line."""
    mem = await start(dut)
    addrs = [BASE + 0x100, BASE + 0x2F0, BASE + 0x1008]
    for a in addrs:
        await fetch(dut, a)
    mem.version = 1  # the program stored new code behind the cache
    for a in addrs:  # lines still hold the old words
        data, _ = await fetch(dut, a)
        check_equal(data, word(a, 0))
    dut.i_invalidate.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_invalidate.value = 0
    del mem.requests[:]
    for a in addrs:
        data, _ = await fetch(dut, a)
        check_equal(data, word(a, 1), f"{a:#x} after the invalidate")
    check_equal(len(mem.requests), 3)


@cocotb.test()
async def test_invalidate_during_a_fill_drops_that_line(dut: Dut):
    """Check that invalidate during a fill drops that line."""
    mem = await start(dut)
    a = BASE + 0x300
    dut.i_addr.value = a
    dut.i_sel.value = 1
    for _ in range(6):  # the fill is under way
        await RisingEdge(dut.i_clk)
    check_equal(len(mem.requests), 1)
    mem.version = 1
    dut.i_invalidate.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_invalidate.value = 0
    data, _ = await fetch(
        dut, a
    )  # the line from before the invalidate must not stay
    check_equal(data, word(a, 1))
    check_equal(len(mem.requests), 2)


@cocotb.test()
async def test_address_change_during_a_fill(dut: Dut):
    """Check that address change during a fill."""
    await start(dut)
    a, b = BASE + 0x500, BASE + 0x900
    dut.i_addr.value = a
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    data, _ = await fetch(
        dut, b
    )  # a branch moved the PC while the line of a came in
    check_equal(data, word(b))
    data, waited = await fetch(
        dut, a
    )  # and the line of a ended up in the cache
    check_equal(data, word(a))
    check_true(waited <= 1)


FLASH = 0x20000000


@cocotb.test()
async def test_regions_do_not_alias(dut: Dut):
    """Check that regions do not alias."""
    mem = await start(dut)
    # same index and same bits 25:12, different region
    s, f = BASE + 0x1230, FLASH + 0x1230
    for addr in (s, f):
        data, waited = await fetch(dut, addr)
        check_equal(data, word(addr))
        check_true(waited > LAT, f"{addr:#x} must be a miss of its own")
    check_equal(mem.requests, [s & ~0xF, f & ~0xF])
    # the FLASH line replaced the SDRAM one, so the SDRAM line misses
    # again
    data, waited = await fetch(dut, s)
    check_true(data == word(s) and waited > LAT)
    check_equal(mem.requests[-1], s & ~0xF)


@cocotb.test()
async def test_fill_addresses_carry_the_region_base(dut: Dut):
    """Check that fill addresses carry the region base."""
    mem = await start(dut)
    for addr in (FLASH + 0x40, BASE + 0x40, FLASH + 0x7FFF0, BASE + 0x3FFFFF0):
        await fetch(dut, addr)
    check_equal([a >> 28 for a in mem.requests], [0x2, 0x4, 0x2, 0x4])
    check_equal(
        mem.requests,
        [
            (FLASH + 0x40) & ~0xF,
            (BASE + 0x40) & ~0xF,
            (FLASH + 0x7FFF0) & ~0xF,
            (BASE + 0x3FFFFF0) & ~0xF,
        ],
    )


@cocotb.test()
async def test_flash_line_hits_in_the_line(dut: Dut):
    """Check that flash line hits in the line."""
    mem = await start(dut)
    base = FLASH + 0x2230
    await fetch(dut, base)
    for i in range(1, 4):
        data, waited = await fetch(dut, base + 4 * i)
        check_true(data == word(base + 4 * i) and waited <= 1)
    check_equal(mem.requests, [base])


@cocotb.test()
async def test_invalidate_drops_the_lines_of_both_regions(dut: Dut):
    """Check that invalidate drops the lines of both regions."""
    mem = await start(dut)
    addrs = [FLASH + 0x100, BASE + 0x2F0]
    for a in addrs:
        await fetch(dut, a)
    mem.version = 1
    dut.i_invalidate.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_invalidate.value = 0
    del mem.requests[:]
    for a in addrs:
        data, _ = await fetch(dut, a)
        check_equal(data, word(a, 1))
    check_equal(len(mem.requests), 2)


async def count_misses(dut: Dut, cycles: int):
    """Count the clocks with o_miss high over `cycles` clocks."""
    seen = 0
    for _ in range(cycles):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        seen += int(dut.o_miss.value)
    return seen


@cocotb.test()
async def test_one_miss_pulse_per_filled_line(dut: Dut):
    """Check that one miss pulse per filled line."""
    await start(dut)
    monitor = cocotb.start_soon(count_misses(dut, 1200))
    for base in (BASE + 0x100, BASE + 0x200, BASE + 0x100, FLASH + 0x100):
        await fetch(dut, base)
        await fetch(dut, base + 4)  # same line: a hit
    check_equal(
        await monitor, 3, "three lines filled, the repeated one is a hit"
    )
