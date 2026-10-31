"""dcache with the FLASH region: loads are cached, stores to the FLASH never change the cache."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

FLASH = 0x20000000
SDRAM = 0x40000000
LAT = 4


def word(addr):
    return ((addr * 2654435761) ^ 0x77770000) & 0xFFFFFFFF


class Memory:
    """The memory side: answers line reads after a latency and records every request."""

    def __init__(self, dut):
        self.dut = dut
        self.reads = []
        self.writes = []

    async def run(self):
        dut = self.dut
        dut.i_d_ready.value = 0
        while True:
            await RisingEdge(dut.i_clk)
            if int(dut.o_d_rden.value) == 1:
                addr = int(dut.o_d_addr.value)
                self.reads.append((addr, int(dut.o_d_line.value)))
                for _ in range(LAT):
                    await RisingEdge(dut.i_clk)
                w = [word(addr + 4 * i) for i in range(4)]
                # like the SDRAM bridge: the data changes one edge after ready, not with it
                dut.i_d_ready.value = 1
                await RisingEdge(dut.i_clk)
                dut.i_d_ready.value = 0
                dut.i_d_rdata.value = w[0]
                dut.i_d_rdata_x.value = w[1] | (w[2] << 32) | (w[3] << 64)
            elif int(dut.o_d_wren.value) == 1:
                self.writes.append((int(dut.o_d_addr.value), int(dut.o_d_wdata.value)))
                for _ in range(LAT):
                    await RisingEdge(dut.i_clk)
                dut.i_d_ready.value = 1
                await RisingEdge(dut.i_clk)
                dut.i_d_ready.value = 0


async def start(dut):
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    dut.i_rst.value = 1
    for n in ("i_rden", "i_wren", "i_mem_advance", "i_flush", "i_invalidate", "i_d_ready"):
        getattr(dut, n).value = 0
    dut.i_addr.value = FLASH
    dut.i_wdata.value = 0
    dut.i_byteena.value = 0xF
    dut.i_d_rdata.value = 0
    dut.i_d_rdata_x.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    mem = Memory(dut)
    cocotb.start_soon(mem.run())
    return mem


async def access(dut, addr, wr=None, timeout=300):
    """One core access; returns (value read or None, clocks until ready)."""
    dut.i_addr.value = addr
    if wr is None:
        dut.i_rden.value = 1
    else:
        dut.i_wren.value = 1
        dut.i_wdata.value = wr
    for n in range(timeout):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_ready.value) == 1:
            dut.i_mem_advance.value = 1
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            dut.i_rden.value = 0
            dut.i_wren.value = 0
            dut.i_mem_advance.value = 0
            return (int(dut.o_rdata.value) if wr is None else None), n
    raise AssertionError(f"no ready for {addr:#x}")


@cocotb.test()
async def test_a_flash_load_is_cached(dut):
    mem = await start(dut)
    a = FLASH + 0x1230
    v, miss = await access(dut, a)
    assert v == word(a) and miss > LAT
    assert mem.reads == [(a & ~0xF, 1)]
    v, hit = await access(dut, a + 4)
    assert v == word(a + 4) and hit <= 3
    assert len(mem.reads) == 1


@cocotb.test()
async def test_a_store_that_hits_the_flash_line_does_not_change_it(dut):
    mem = await start(dut)
    a = FLASH + 0x2000
    await access(dut, a)                                   # the line is in
    await access(dut, a, wr=0xDEADBEEF)                    # the chip ignores it, so must the cache
    v, hit = await access(dut, a)
    assert v == word(a), f"the cache shows {v:#x}, the chip has {word(a):#x}"
    assert hit <= 3
    # the store was passed on, with the FLASH base, for the region router to absorb
    assert mem.writes == [(a, 0xDEADBEEF)]


@cocotb.test()
async def test_a_store_that_misses_the_flash_does_not_bring_the_line(dut):
    mem = await start(dut)
    a = FLASH + 0x3000
    await access(dut, a, wr=0x1234)
    assert mem.writes == [(a, 0x1234)] and mem.reads == []
    v, waited = await access(dut, a)
    assert v == word(a) and waited > LAT


@cocotb.test()
async def test_regions_do_not_alias(dut):
    mem = await start(dut)
    f, s = FLASH + 0x1230, SDRAM + 0x1230
    for a in (f, s):
        v, waited = await access(dut, a)
        assert v == word(a) and waited > LAT
    assert [x >> 28 for x, _ in mem.reads] == [0x2, 0x4]
    v, waited = await access(dut, f)                       # the SDRAM line took the slot
    assert v == word(f) and waited > LAT


@cocotb.test()
async def test_a_sdram_store_still_updates_the_line(dut):
    mem = await start(dut)
    a = SDRAM + 0x500
    await access(dut, a)
    await access(dut, a, wr=0xCAFE0001)
    v, hit = await access(dut, a)
    assert v == 0xCAFE0001 and hit <= 3
    assert mem.writes == [(a, 0xCAFE0001)]


@cocotb.test()
async def test_a_bypassed_load_goes_to_memory_every_time(dut):
    mem = await start(dut)
    a = SDRAM + 0x3FFF008
    dut.i_bypass.value = 1
    for _ in range(2):
        v, _ = await access(dut, a)
        assert v == word(a)
    # a word read per access, never a line, and nothing was kept
    assert mem.reads == [(a, 0), (a, 0)]
    dut.i_bypass.value = 0
    v, waited = await access(dut, a)
    assert v == word(a) and waited > LAT, "the bypassed loads must not have filled the line"


@cocotb.test()
async def test_a_bypassed_store_does_not_update_the_line(dut):
    mem = await start(dut)
    a = SDRAM + 0x600
    await access(dut, a)                                   # the line is in
    dut.i_bypass.value = 1
    await access(dut, a, wr=0x0BADF00D)                    # the host owns this word: only passed on
    dut.i_bypass.value = 0
    v, hit = await access(dut, a)
    assert v == word(a) and hit <= 3
    assert mem.writes == [(a, 0x0BADF00D)]


async def count_misses(dut, cycles):
    seen = 0
    for _ in range(cycles):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        seen += int(dut.o_miss.value)
    return seen


@cocotb.test()
async def test_one_miss_pulse_per_filled_line(dut):
    mem = await start(dut)
    monitor = cocotb.start_soon(count_misses(dut, 600))
    await access(dut, FLASH + 0x100)
    await access(dut, FLASH + 0x104)                      # same line
    await access(dut, SDRAM + 0x100)
    await access(dut, SDRAM + 0x100, wr=7)                # a store: no fill
    assert await monitor == 2
