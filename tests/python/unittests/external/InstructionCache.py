"""icache: the instruction cache alone, against a memory model with a variable latency."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

BASE = 0x40000000
LAT = 5


def word(addr, version=0):
    """The content of the memory model at a word address."""
    return ((addr * 2654435761) ^ (0xA5A50000 + version)) & 0xFFFFFFFF


class Memory:
    """Answers each line request after a latency, and counts them."""

    def __init__(self, dut, latency=LAT):
        self.dut = dut
        self.latency = latency
        self.version = 0
        self.requests = []

    async def run(self):
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
                dut.i_d_rdata_x.value = words[1] | (words[2] << 32) | (words[3] << 64)
                dut.i_d_ready.value = 1
                await RisingEdge(dut.i_clk)
                dut.i_d_ready.value = 0


async def start(dut):
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


async def fetch(dut, addr, timeout=200):
    """Hold addr until ready, the way the core does; returns (data, clocks waited)."""
    dut.i_addr.value = addr
    dut.i_sel.value = 1
    for n in range(timeout):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_ready.value) == 1:
            return int(dut.o_data.value), n
    raise AssertionError(f"no ready for {addr:#x} after {timeout} clocks")


@cocotb.test()
async def test_miss_then_hits_in_the_line(dut):
    mem = await start(dut)
    base = BASE + 0x1230
    data, waited = await fetch(dut, base)
    assert data == word(base)
    assert waited > LAT, "the first fetch has to wait for the line"
    assert mem.requests == [base]
    for i in range(1, 4):
        data, waited = await fetch(dut, base + 4 * i)
        assert data == word(base + 4 * i)
        assert waited <= 1, f"word {i} of a line in the cache waited {waited}"
    assert mem.requests == [base], "no second request for the same line"


@cocotb.test()
async def test_sequential_code_across_lines(dut):
    mem = await start(dut)
    for i in range(64):
        a = BASE + 4 * i
        data, _ = await fetch(dut, a)
        assert data == word(a), f"{a:#x}"
    assert len(mem.requests) == 16
    assert mem.requests == [BASE + 16 * k for k in range(16)]


@cocotb.test()
async def test_conflict_evicts_the_line(dut):
    mem = await start(dut)
    a, b = BASE + 0x040, BASE + 0x040 + 0x1000     # same index, different tag
    for addr in (a, b, a):
        data, _ = await fetch(dut, addr)
        assert data == word(addr)
    assert mem.requests == [a & ~0xF, b & ~0xF, a & ~0xF]


@cocotb.test()
async def test_not_selected_never_hits_or_fills(dut):
    mem = await start(dut)
    dut.i_addr.value = 0x00000100
    dut.i_sel.value = 0
    for _ in range(40):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        assert int(dut.o_ready.value) == 0
    assert mem.requests == []


@cocotb.test()
async def test_invalidate_drops_every_line(dut):
    mem = await start(dut)
    addrs = [BASE + 0x100, BASE + 0x2F0, BASE + 0x1008]
    for a in addrs:
        await fetch(dut, a)
    mem.version = 1                                   # the program stored new code behind the cache
    for a in addrs:                                   # lines still hold the old words
        data, _ = await fetch(dut, a)
        assert data == word(a, 0)
    dut.i_invalidate.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_invalidate.value = 0
    del mem.requests[:]
    for a in addrs:
        data, _ = await fetch(dut, a)
        assert data == word(a, 1), f"{a:#x} after the invalidate"
    assert len(mem.requests) == 3


@cocotb.test()
async def test_invalidate_during_a_fill_drops_that_line(dut):
    mem = await start(dut)
    a = BASE + 0x300
    dut.i_addr.value = a
    dut.i_sel.value = 1
    for _ in range(6):                                # the fill is under way
        await RisingEdge(dut.i_clk)
    assert len(mem.requests) == 1
    mem.version = 1
    dut.i_invalidate.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_invalidate.value = 0
    data, _ = await fetch(dut, a)                     # the line from before the invalidate must not stay
    assert data == word(a, 1)
    assert len(mem.requests) == 2


@cocotb.test()
async def test_address_change_during_a_fill(dut):
    mem = await start(dut)
    a, b = BASE + 0x500, BASE + 0x900
    dut.i_addr.value = a
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    data, _ = await fetch(dut, b)                     # a branch moved the PC while the line of a came in
    assert data == word(b)
    data, waited = await fetch(dut, a)                # and the line of a ended up in the cache
    assert data == word(a)
    assert waited <= 1
