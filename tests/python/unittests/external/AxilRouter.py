"""The AXI4-Lite router: one master, two slaves chosen by address, DECERR where there is none.

The testbench plays the master and both slaves. A slave accepts every request in the clock it is
offered, and answers a write with OKAY one clock after both AW and W, and a read with the address
it saw, one clock after AR; each answer waits for the router to take it.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

OKAY, DECERR = 0, 3
SLAVE0, SLAVE1 = 0x40000010, 0x80000020
NOBODY = 0x10000000


class Slave:
    def __init__(self, dut, n):
        self.dut, self.n = dut, n
        self.writes = []
        self.reads = []
        self.aw = self.w = None
        self.b = self.r = False
        self.rd_addr = 0
        for ch in ("awready", "wready", "arready"):
            self.sig(ch).value = 1
        self.sig("bvalid").value = 0
        self.sig("rvalid").value = 0
        self.sig("bresp").value = OKAY
        self.sig("rresp").value = OKAY
        cocotb.start_soon(self.run())

    def sig(self, name):
        return getattr(self.dut, f"m{self.n}_{name}")

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            v = lambda name: int(self.sig(name).value)
            # the values at the edge: handshakes of this clock
            if v("awvalid") and v("awready"):
                self.aw = int(self.sig("awaddr").value)
            if v("wvalid") and v("wready"):
                self.w = (int(self.sig("wdata").value), int(self.sig("wstrb").value))
            if v("arvalid") and v("arready"):
                self.rd_addr = int(self.sig("araddr").value)
                self.reads.append(self.rd_addr)
                self.r = True
            if v("bvalid") and v("bready"):
                self.b = False
            if v("rvalid") and v("rready"):
                self.r = False
                self.sig("rvalid").value = 0
            if self.aw is not None and self.w is not None:
                self.writes.append((self.aw, *self.w))
                self.aw = self.w = None
                self.b = True
            self.sig("bvalid").value = 1 if self.b else 0
            if self.r:
                self.sig("rvalid").value = 1
                self.sig("rdata").value = self.rd_addr ^ 0xFFFFFFFF


async def setup(dut):
    for sig in ("awvalid", "wvalid", "arvalid", "bready", "rready"):
        getattr(dut, f"s_{sig}").value = 0
    for n in (0, 1):
        for ch in ("awready", "wready", "arready", "bvalid", "rvalid"):
            getattr(dut, f"m{n}_{ch}").value = 0
    dut.rst.value = 1
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    s = [Slave(dut, 0), Slave(dut, 1)]
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await Timer(1, unit="ns")
    return s


async def write(dut, addr, data, strb=0xF, w_first=False):
    """A write; returns the response. With w_first W is offered a clock before AW."""
    dut.s_awaddr.value = addr
    dut.s_wdata.value = data
    dut.s_wstrb.value = strb
    aw_done = w_done = False
    if w_first:
        dut.s_wvalid.value = 1
    else:
        dut.s_awvalid.value = 1
        dut.s_wvalid.value = 1
    for cycle in range(40):
        await Timer(1, unit="ns")
        aw_hs = int(dut.s_awvalid.value) and int(dut.s_awready.value)
        w_hs = int(dut.s_wvalid.value) and int(dut.s_wready.value)
        if w_first and cycle == 0:
            assert not w_hs, "W was taken before its AW"
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if aw_hs:
            dut.s_awvalid.value = 0
            aw_done = True
        if w_hs:
            dut.s_wvalid.value = 0
            w_done = True
        if w_first and cycle == 0:
            dut.s_awvalid.value = 1
        if aw_done and w_done:
            break
    assert aw_done and w_done, "the write request was never accepted"
    dut.s_bready.value = 1
    for _ in range(40):
        await Timer(1, unit="ns")
        if int(dut.s_bvalid.value):
            resp = int(dut.s_bresp.value)
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
            dut.s_bready.value = 0
            return resp
        await RisingEdge(dut.clk)
    raise AssertionError("no write response")


async def read(dut, addr):
    dut.s_araddr.value = addr
    dut.s_arvalid.value = 1
    for _ in range(40):
        await Timer(1, unit="ns")
        hs = int(dut.s_arready.value)
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if hs:
            break
    else:
        raise AssertionError("the read request was never accepted")
    dut.s_arvalid.value = 0
    dut.s_rready.value = 1
    for _ in range(40):
        await Timer(1, unit="ns")
        if int(dut.s_rvalid.value):
            out = (int(dut.s_rdata.value), int(dut.s_rresp.value))
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
            dut.s_rready.value = 0
            return out
        await RisingEdge(dut.clk)
    raise AssertionError("no read response")


@cocotb.test()
async def test_writes_go_to_the_selected_slave(dut):
    s = await setup(dut)
    assert await write(dut, SLAVE0, 0x11, 0x3) == OKAY
    assert await write(dut, SLAVE1, 0x22, 0xC) == OKAY
    assert s[0].writes == [(SLAVE0, 0x11, 0x3)], s[0].writes
    assert s[1].writes == [(SLAVE1, 0x22, 0xC)], s[1].writes


@cocotb.test()
async def test_reads_come_from_the_selected_slave(dut):
    s = await setup(dut)
    assert await read(dut, SLAVE0) == (SLAVE0 ^ 0xFFFFFFFF, OKAY)
    assert await read(dut, SLAVE1) == (SLAVE1 ^ 0xFFFFFFFF, OKAY)
    assert s[0].reads == [SLAVE0] and s[1].reads == [SLAVE1]


@cocotb.test()
async def test_w_before_aw_waits_and_follows_aw(dut):
    s = await setup(dut)
    assert await write(dut, SLAVE1, 0xBEEF, w_first=True) == OKAY
    assert s[1].writes == [(SLAVE1, 0xBEEF, 0xF)] and s[0].writes == []


@cocotb.test()
async def test_no_slave_answers_decerr(dut):
    s = await setup(dut)
    assert await write(dut, NOBODY, 0x5) == DECERR
    assert await read(dut, NOBODY) == (0, DECERR)
    assert await read(dut, 0x44000000) == (0, DECERR)      # just above the SDRAM
    assert await read(dut, 0x4C000000) == (0, DECERR)      # bits 27 and 26 both set
    assert s[0].writes == s[1].writes == [] and s[0].reads == s[1].reads == []
    assert await write(dut, SLAVE0, 0x1) == OKAY            # and the router is fine after it
    assert await read(dut, SLAVE1) == (SLAVE1 ^ 0xFFFFFFFF, OKAY)


@cocotb.test()
async def test_back_to_back(dut):
    s = await setup(dut)
    for i in range(10):
        a = SLAVE0 + 4 * i if i % 2 else SLAVE1 + 4 * i
        assert await write(dut, a, i) == OKAY
        assert (await read(dut, a))[0] == a ^ 0xFFFFFFFF
    assert len(s[0].writes) == 5 and len(s[1].writes) == 5
