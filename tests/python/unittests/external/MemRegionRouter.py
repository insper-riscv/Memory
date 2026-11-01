"""mem_region_router: one master steered to a SDRAM slave or a FLASH slave by address bit 29."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

SDRAM = 0x40000000
FLASH = 0x20000000
LAT = 3


def word(tag, addr):
    return ((addr * 2654435761) ^ tag) & 0xFFFFFFFF


class Slave:
    """Answers a request after LAT edges, holds ready until advance; records the requests."""

    def __init__(self, dut, prefix, tag, writes=False):
        self.dut, self.p, self.tag, self.writes = dut, prefix, tag, writes
        self.requests = []

    async def run(self):
        state, count = "idle", 0
        self.dut_ready.value = 0
        while True:
            await RisingEdge(self.dut.i_clk)
            rd = int(self.rden.value) == 1
            wr = self.wren is not None and int(self.wren.value) == 1
            if state == "idle" and (rd or wr):
                addr = int(self.addr.value)
                self.requests.append(
                    (addr, "w" if wr else "r", int(self.line.value))
                )
                state, count = "wait", LAT
            elif state == "wait":
                count -= 1
                if count == 0:
                    addr = self.requests[-1][0] & ~0xF
                    w = [word(self.tag, addr + 4 * i) for i in range(4)]
                    self.dut_rdata.value = w[0]
                    self.dut_rdata_x.value = w[1] | (w[2] << 32) | (w[3] << 64)
                    self.dut_ready.value = 1
                    state = "done"
            elif state == "done" and int(self.advance.value) == 1:
                self.dut_ready.value = 0
                state = "idle"


async def start(dut):
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    dut.i_rst.value = 1
    for n in ("i_rden", "i_wren", "i_line", "i_advance"):
        getattr(dut, n).value = 0
    dut.i_addr.value = SDRAM
    dut.i_wdata.value = 0
    dut.i_byteena.value = 0xF
    dut.i_wdata_x.value = 0
    s = Slave(dut, "o_s_", 0x11110000)
    s.addr, s.rden, s.wren, s.line, s.advance = (
        dut.o_s_addr,
        dut.o_s_rden,
        dut.o_s_wren,
        dut.o_s_line,
        dut.o_s_advance,
    )
    s.dut_ready, s.dut_rdata, s.dut_rdata_x = (
        dut.i_s_ready,
        dut.i_s_rdata,
        dut.i_s_rdata_x,
    )
    f = Slave(dut, "o_f_", 0x22220000)
    f.addr, f.rden, f.wren, f.line, f.advance = (
        dut.o_f_addr,
        dut.o_f_rden,
        None,
        dut.o_f_line,
        dut.o_f_advance,
    )
    f.dut_ready, f.dut_rdata, f.dut_rdata_x = (
        dut.i_f_ready,
        dut.i_f_rdata,
        dut.i_f_rdata_x,
    )
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    cocotb.start_soon(s.run())
    cocotb.start_soon(f.run())
    return s, f


async def request(dut, addr, rd=0, wr=0, line=0, timeout=100):
    """Hold the request until ready, advance for a cycle, then drop it; returns (rdata, rdata_x, waited)."""
    dut.i_addr.value = addr
    dut.i_rden.value = rd
    dut.i_wren.value = wr
    dut.i_line.value = line
    dut.i_wdata.value = 0xCAFE0000 | (addr & 0xFFFF)
    for n in range(timeout):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_ready.value) == 1:
            r, rx = int(dut.o_rdata.value), int(dut.o_rdata_x.value)
            dut.i_advance.value = 1
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            dut.i_rden.value = 0
            dut.i_wren.value = 0
            dut.i_advance.value = 0
            return r, rx, n
    raise AssertionError(f"no ready for {addr:#x}")


def line_words(tag, base):
    return [word(tag, base + 4 * i) for i in range(4)]


@cocotb.test()
async def test_line_read_goes_to_the_sdram(dut):
    s, f = await start(dut)
    r, rx, _ = await request(dut, SDRAM + 0x1230, rd=1, line=1)
    got = [r, rx & 0xFFFFFFFF, (rx >> 32) & 0xFFFFFFFF, rx >> 64]
    assert got == line_words(0x11110000, SDRAM + 0x1230)
    assert len(s.requests) == 1 and f.requests == []


@cocotb.test()
async def test_line_read_goes_to_the_flash(dut):
    s, f = await start(dut)
    r, rx, _ = await request(dut, FLASH + 0x400, rd=1, line=1)
    got = [r, rx & 0xFFFFFFFF, (rx >> 32) & 0xFFFFFFFF, rx >> 64]
    assert got == line_words(0x22220000, FLASH + 0x400)
    assert len(f.requests) == 1 and s.requests == []


@cocotb.test()
async def test_store_to_the_flash_is_absorbed(dut):
    s, f = await start(dut)
    _, _, waited = await request(dut, FLASH + 0x80, wr=1)
    assert waited <= 2, f"the absorbed store waited {waited}"
    assert s.requests == [] and f.requests == []


@cocotb.test()
async def test_read_outside_the_window_is_zero(dut):
    s, f = await start(dut)
    r, rx, _ = await request(dut, FLASH + 0x100000, rd=1, line=1)
    assert r == 0 and rx == 0
    r, rx, _ = await request(dut, FLASH + 0x3F00000, rd=1)
    assert r == 0
    assert s.requests == [] and f.requests == []
    # the last line inside the window still reaches the chip
    await request(dut, FLASH + 0xFFFF0, rd=1, line=1)
    assert len(f.requests) == 1


@cocotb.test()
async def test_store_to_the_sdram_passes_through(dut):
    s, f = await start(dut)
    await request(dut, SDRAM + 0x20, wr=1)
    assert s.requests == [(SDRAM + 0x20, "w", 0)] and f.requests == []


@cocotb.test()
async def test_mixed_sequence(dut):
    s, f = await start(dut)
    plan = [
        SDRAM + 0x10,
        FLASH + 0x10,
        FLASH + 0x20,
        SDRAM + 0x30,
        FLASH + 0x30,
    ]
    for a in plan:
        r, _, _ = await request(dut, a, rd=1, line=1)
        tag = 0x22220000 if a & FLASH and not a & SDRAM else 0x11110000
        assert r == word(tag, a & ~0xF)
    assert [a for a, _, _ in s.requests] == [SDRAM + 0x10, SDRAM + 0x30]
    assert [a for a, _, _ in f.requests] == [
        FLASH + 0x10,
        FLASH + 0x20,
        FLASH + 0x30,
    ]
