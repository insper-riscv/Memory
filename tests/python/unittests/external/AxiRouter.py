"""The AXI4 router: one master, two slaves chosen by address, DECERR where there is none.

The testbench plays the master and both slaves. A slave accepts every request in the clock it is
offered, and answers a write with OKAY one clock after both AW and W, and a read with the address
it saw (one beat of the address of each word of a burst), one clock after AR; each answer waits for
the router to take it.
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
        self.writes = []         # single-beat writes: (address, data, strobes)
        self.bursts = []         # longer writes: (address, [(data, strobes), ...])
        self.reads = []          # (address, length) of every read
        self.aw = None
        self.beats = []
        self.b = False
        self.r_left = None       # beats of the read in service still to give, minus one
        self.rd_addr = 0
        for ch in ("awready", "wready", "arready"):
            self.sig(ch).value = 1
        self.sig("bvalid").value = 0
        self.sig("rvalid").value = 0
        self.sig("rlast").value = 0
        self.sig("bresp").value = OKAY
        self.sig("rresp").value = OKAY
        cocotb.start_soon(self.run())

    def sig(self, name):
        direction = "i" if name in SLAVE_DRIVEN else "o"
        return getattr(self.dut, f"{direction}_m{self.n}_{name}")

    async def run(self):
        while True:
            await RisingEdge(self.dut.i_clk)
            v = lambda name: int(self.sig(name).value)
            # the values at the edge: handshakes of this clock
            if v("awvalid") and v("awready"):
                self.aw = int(self.sig("awaddr").value)
            if v("wvalid") and v("wready"):
                self.beats.append((int(self.sig("wdata").value), int(self.sig("wstrb").value)))
                if v("wlast"):
                    done = self.beats
                    self.beats = []
                    if len(done) == 1:
                        self.writes.append((self.aw, *done[0]))
                    else:
                        self.bursts.append((self.aw, done))
                    self.aw = None
                    self.b = True
            if v("arvalid") and v("arready"):
                self.rd_addr = int(self.sig("araddr").value)
                self.reads.append((self.rd_addr, v("arlen")))
                self.r_left = v("arlen")
            if v("bvalid") and v("bready"):
                self.b = False
            if v("rvalid") and v("rready"):
                if self.r_left == 0:
                    self.r_left = None
                else:
                    self.r_left -= 1
                    self.rd_addr += 4
            self.sig("bvalid").value = 1 if self.b else 0
            if self.r_left is not None:
                self.sig("rvalid").value = 1
                self.sig("rdata").value = self.rd_addr ^ 0xFFFFFFFF
                self.sig("rlast").value = 1 if self.r_left == 0 else 0
            else:
                self.sig("rvalid").value = 0
                self.sig("rlast").value = 0


# Signals of a master port that the slave (this testbench) drives into the router.
SLAVE_DRIVEN = {"awready", "wready", "arready", "bvalid", "bresp", "rvalid", "rdata", "rresp", "rlast"}


async def setup(dut):
    for sig in ("awvalid", "wvalid", "arvalid", "bready", "rready"):
        getattr(dut, f"i_s_{sig}").value = 0
    for ch in ("aw", "ar"):
        getattr(dut, f"i_s_{ch}len").value = 0
        getattr(dut, f"i_s_{ch}size").value = 2
        getattr(dut, f"i_s_{ch}burst").value = 1
    dut.i_s_wlast.value = 1
    for n in (0, 1):
        for ch in ("awready", "wready", "arready", "bvalid", "rvalid"):
            getattr(dut, f"i_m{n}_{ch}").value = 0
    dut.i_rst.value = 1
    cocotb.start_soon(Clock(dut.i_clk, 20, unit="ns").start())
    s = [Slave(dut, 0), Slave(dut, 1)]
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await Timer(1, unit="ns")
    return s


async def write(dut, addr, data, strb=0xF, w_first=False):
    """A write; returns the response. With w_first W is offered a clock before AW."""
    dut.i_s_awaddr.value = addr
    dut.i_s_wdata.value = data
    dut.i_s_wstrb.value = strb
    aw_done = w_done = False
    if w_first:
        dut.i_s_wvalid.value = 1
    else:
        dut.i_s_awvalid.value = 1
        dut.i_s_wvalid.value = 1
    for cycle in range(40):
        await Timer(1, unit="ns")
        aw_hs = int(dut.i_s_awvalid.value) and int(dut.o_s_awready.value)
        w_hs = int(dut.i_s_wvalid.value) and int(dut.o_s_wready.value)
        if w_first and cycle == 0:
            assert not w_hs, "W was taken before its AW"
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if aw_hs:
            dut.i_s_awvalid.value = 0
            aw_done = True
        if w_hs:
            dut.i_s_wvalid.value = 0
            w_done = True
        if w_first and cycle == 0:
            dut.i_s_awvalid.value = 1
        if aw_done and w_done:
            break
    assert aw_done and w_done, "the write request was never accepted"
    dut.i_s_bready.value = 1
    for _ in range(40):
        await Timer(1, unit="ns")
        if int(dut.o_s_bvalid.value):
            resp = int(dut.o_s_bresp.value)
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            dut.i_s_bready.value = 0
            return resp
        await RisingEdge(dut.i_clk)
    raise AssertionError("no write response")


async def read(dut, addr):
    dut.i_s_araddr.value = addr
    dut.i_s_arvalid.value = 1
    for _ in range(40):
        await Timer(1, unit="ns")
        hs = int(dut.o_s_arready.value)
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if hs:
            break
    else:
        raise AssertionError("the read request was never accepted")
    dut.i_s_arvalid.value = 0
    dut.i_s_rready.value = 1
    for _ in range(40):
        await Timer(1, unit="ns")
        if int(dut.o_s_rvalid.value):
            out = (int(dut.o_s_rdata.value), int(dut.o_s_rresp.value))
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            dut.i_s_rready.value = 0
            return out
        await RisingEdge(dut.i_clk)
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
    assert s[0].reads == [(SLAVE0, 0)] and s[1].reads == [(SLAVE1, 0)]


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


async def write_burst(dut, addr, beats, w_first=False, size=2, burst=1):
    """A burst write of len(beats) beats of (data, strobes); returns the response."""
    dut.i_s_awaddr.value = addr
    dut.i_s_awlen.value = len(beats) - 1
    dut.i_s_awsize.value = size
    dut.i_s_awburst.value = burst
    dut.i_s_awvalid.value = 0 if w_first else 1
    aw_done = False
    i = 0
    dut.i_s_wvalid.value = 1
    for cycle in range(200):
        data, strb = beats[i]
        dut.i_s_wdata.value = data
        dut.i_s_wstrb.value = strb
        dut.i_s_wlast.value = 1 if i == len(beats) - 1 else 0
        if w_first and cycle == 2:
            dut.i_s_awvalid.value = 1
        await Timer(1, unit="ns")
        aw_hs = int(dut.i_s_awvalid.value) and int(dut.o_s_awready.value)
        w_hs = int(dut.i_s_wvalid.value) and int(dut.o_s_wready.value)
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if aw_hs:
            dut.i_s_awvalid.value = 0
            aw_done = True
        if w_hs:
            if i == len(beats) - 1:
                dut.i_s_wvalid.value = 0
                dut.i_s_wlast.value = 1
                if aw_done:
                    break
                i = len(beats) - 1
            else:
                i += 1
        if not dut.i_s_wvalid.value and aw_done:
            break
    dut.i_s_awlen.value = 0
    dut.i_s_awsize.value = 2
    dut.i_s_awburst.value = 1
    dut.i_s_wlast.value = 1
    dut.i_s_bready.value = 1
    for _ in range(100):
        await Timer(1, unit="ns")
        if int(dut.o_s_bvalid.value):
            resp = int(dut.o_s_bresp.value)
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            dut.i_s_bready.value = 0
            return resp
        await RisingEdge(dut.i_clk)
    raise AssertionError("no write response")


async def read_burst(dut, addr, n, size=2, burst=1):
    """A burst read of n beats; returns [(data, resp, last)]."""
    dut.i_s_araddr.value = addr
    dut.i_s_arlen.value = n - 1
    dut.i_s_arsize.value = size
    dut.i_s_arburst.value = burst
    dut.i_s_arvalid.value = 1
    for _ in range(60):
        await Timer(1, unit="ns")
        hs = int(dut.o_s_arready.value)
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if hs:
            break
    else:
        raise AssertionError("the read request was never accepted")
    dut.i_s_arvalid.value = 0
    dut.i_s_arlen.value = 0
    dut.i_s_arsize.value = 2
    dut.i_s_arburst.value = 1
    dut.i_s_rready.value = 1
    got = []
    for _ in range(200):
        await Timer(1, unit="ns")
        if int(dut.o_s_rvalid.value):
            got.append((int(dut.o_s_rdata.value), int(dut.o_s_rresp.value), int(dut.o_s_rlast.value)))
            last = got[-1][2]
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            if last:
                dut.i_s_rready.value = 0
                return got
        else:
            await RisingEdge(dut.i_clk)
    raise AssertionError(f"the burst ended after {len(got)} beats")


@cocotb.test()
async def test_a_write_burst_goes_whole_to_one_slave(dut):
    s = await setup(dut)
    beats = [(0x100 + i, 0xF) for i in range(4)]
    assert await write_burst(dut, SLAVE1, beats) == OKAY
    assert s[1].bursts == [(SLAVE1, beats)] and s[0].bursts == [] and s[0].writes == []
    beats = [(0x200 + i, 0x3) for i in range(4)]
    assert await write_burst(dut, SLAVE0, beats, w_first=True) == OKAY
    assert s[0].bursts == [(SLAVE0, beats)]


@cocotb.test()
async def test_a_read_burst_comes_whole_from_one_slave(dut):
    s = await setup(dut)
    got = await read_burst(dut, SLAVE0, 4)
    assert got == [((SLAVE0 + 4 * i) ^ 0xFFFFFFFF, OKAY, 1 if i == 3 else 0) for i in range(4)], got
    assert s[0].reads == [(SLAVE0, 3)] and s[1].reads == []


@cocotb.test()
async def test_a_burst_to_no_slave_is_consumed_and_answered_decerr(dut):
    s = await setup(dut)
    assert await write_burst(dut, NOBODY, [(i, 0xF) for i in range(4)]) == DECERR
    got = await read_burst(dut, NOBODY, 4)
    assert got == [(0, DECERR, 1 if i == 3 else 0) for i in range(4)], got
    assert s[0].writes == s[1].writes == [] and s[0].bursts == s[1].bursts == [] and s[0].reads == s[1].reads == []
    assert await write(dut, SLAVE1, 0x9) == OKAY             # and the router is fine after it
