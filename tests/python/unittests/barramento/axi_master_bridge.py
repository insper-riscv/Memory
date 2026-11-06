"""axi_master_bridge, alone, against a Python AXI4 slave.

The testbench plays the core (the word contract: the access stays on the
ports, ready rises when it ends and stays up until the advance) and the
AXI4 slave behind the port. A word is one beat, a line is a burst of
four beats, INCR, 4 bytes; the bridge keeps one transaction at a time,
holds the address and the data stable while a valid is up and takes the
response only after its request was accepted.

"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut

SETTLE_NS = 1
BASE = 0x40000000
OKAY, SLVERR = 0, 2
LAST_BEAT = 3  # index of the last beat of a line
CLOCKS = 80  # clocks an access may take
WORD_MASK = 0xFFFFFFFF


def word_at(addr: int) -> int:
    """Return the word the slave holds at a byte address."""
    return (0xD0000000 + (addr >> 2) * 0x10001) & WORD_MASK


class Slave:
    """The AXI4 slave: it records the requests and answers them."""

    def __init__(self, stall: int = 0) -> None:
        """Start the slave; `stall` clocks of ready low per accept."""
        self.stall = stall
        self.bresp = OKAY
        self.rresp = OKAY
        self.rlast_at: int | None = None  # beat index; None = the last
        self.early_b = False
        self.aw: list[tuple[int, ...]] = []
        self.w: list[tuple[int, int, int]] = []
        self.ar: list[tuple[int, ...]] = []
        self.beats_wanted = 0
        self.beat = 0
        self.r_addr = 0
        self.problems: list[str] = []
        self.early_taken: list[str] = []
        self.waits = {"aw": stall, "w": stall, "ar": stall}
        self.held: dict[str, int] = {}
        self.b_pending = False

    @staticmethod
    def get(dut: Dut, name: str) -> int:
        """Return the value of a port."""
        return int(getattr(dut, name).value)

    def request(self, dut: Dut, channel: str) -> tuple[int, ...]:
        """Return the fields of an address channel: addr, len, ..."""
        names = ("addr", "len", "size", "burst", "prot")
        return tuple(self.get(dut, f"o_m_{channel}{n}") for n in names)

    def taken(self, dut: Dut, channel: str) -> bool:
        """Tell whether a channel completes a transfer at this edge."""
        return bool(
            self.get(dut, f"o_m_{channel}valid")
            and self.get(dut, f"i_m_{channel}ready")
        )

    async def run(self, dut: Dut) -> None:
        """Sample the ports at every edge and drive the answers."""
        while True:
            await RisingEdge(dut.i_clk)
            self.check_stable(dut)
            self.sample_write(dut)
            self.sample_read(dut)
            for channel, wait in self.waits.items():
                getattr(dut, f"i_m_{channel}ready").value = int(wait == 0)
                self.waits[channel] = max(0, wait - 1)
            self.drive_b(dut)
            self.drive_read(dut)

    def check_stable(self, dut: Dut) -> None:
        """Record a payload that moved while its valid was not taken."""
        payloads = {
            "aw": ("awaddr", "awlen"),
            "w": ("wdata", "wstrb"),
            "ar": ("araddr", "arlen"),
        }
        for channel, fields in payloads.items():
            snap = sum(
                self.get(dut, f"o_m_{f}") << (40 * i)
                for i, f in enumerate(fields)
            )
            valid = self.get(dut, f"o_m_{channel}valid")
            if valid and self.held.get(channel, snap) != snap:
                self.problems.append(f"{channel} payload moved under valid")
            self.held.pop(channel, None)
            if valid and not self.get(dut, f"i_m_{channel}ready"):
                self.held[channel] = snap

    def sample_write(self, dut: Dut) -> None:
        """Record the AW and W transfers and schedule the response."""
        if self.taken(dut, "aw"):
            self.aw.append(self.request(dut, "aw"))
            self.waits["aw"] = self.stall
            if self.early_b:
                dut.i_m_bvalid.value = 1
                dut.i_m_bresp.value = self.bresp
        if self.taken(dut, "w"):
            last = self.get(dut, "o_m_wlast")
            self.w.append(
                (
                    self.get(dut, "o_m_wdata"),
                    self.get(dut, "o_m_wstrb"),
                    last,
                )
            )
            self.waits["w"] = self.stall
            self.b_pending = bool(last) and not self.early_b

    def sample_read(self, dut: Dut) -> None:
        """Record the AR transfer and start the read burst."""
        if self.taken(dut, "ar"):
            self.ar.append(self.request(dut, "ar"))
            self.beats_wanted = self.get(dut, "o_m_arlen") + 1
            self.beat = 0
            self.r_addr = self.get(dut, "o_m_araddr")
            self.waits["ar"] = self.stall

    def drive_b(self, dut: Dut) -> None:
        """Offer the write response and watch when it is taken."""
        busy = self.get(dut, "o_m_awvalid") or self.get(dut, "o_m_wvalid")
        bvalid = self.get(dut, "i_m_bvalid")
        bready = self.get(dut, "o_m_bready")
        if self.early_b and bvalid and bready and busy:
            self.early_taken.append("B taken with a request pending")
        if bvalid and bready:
            dut.i_m_bvalid.value = 0
        if self.b_pending:
            dut.i_m_bvalid.value = 1
            dut.i_m_bresp.value = self.bresp
            self.b_pending = False

    def drive_read(self, dut: Dut) -> None:
        """Offer the beats of the read burst in progress."""
        if self.get(dut, "i_m_rvalid") and self.get(dut, "o_m_rready"):
            self.beat += 1
        if self.beat < self.beats_wanted:
            last_beat = (
                self.beats_wanted - 1
                if self.rlast_at is None
                else self.rlast_at
            )
            dut.i_m_rvalid.value = 1
            dut.i_m_rdata.value = word_at(self.r_addr + 4 * self.beat)
            dut.i_m_rresp.value = self.rresp
            dut.i_m_rlast.value = int(self.beat == last_beat)
        else:
            dut.i_m_rvalid.value = 0
            dut.i_m_rlast.value = 0


async def setup(dut: Dut, stall: int = 0) -> Slave:
    """Reset the bridge and start the clock and the slave."""
    slave = Slave(stall)
    idle = {
        "i_rst": 1,
        "i_rden": 0,
        "i_wren": 0,
        "i_mem_advance": 0,
        "i_line": 0,
        "i_addr": 0,
        "i_wdata": 0,
        "i_byteena": 0xF,
        "i_wdata_x": 0,
        "i_byteena_x": 0,
    }
    for name in ("awready", "wready", "arready", "bvalid", "rvalid", "rlast"):
        idle[f"i_m_{name}"] = 0
    for name in ("bresp", "rresp", "rdata"):
        idle[f"i_m_{name}"] = 0
    for name, value in idle.items():
        getattr(dut, name).value = value
    await Timer(SETTLE_NS, unit="ns")
    cocotb.start_soon(slave.run(dut))
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    await ClockCycles(dut.i_clk, 4)
    dut.i_rst.value = 0
    await RisingEdge(dut.i_clk)
    await Timer(SETTLE_NS, unit="ns")
    return slave


def request(dut: Dut, write: bool | None) -> None:
    """Ask the bridge for a write, a read, or nothing (None)."""
    levels = {"i_wren": write is True, "i_rden": write is False}
    for name, level in levels.items():
        getattr(dut, name).value = int(level)


async def access(  # noqa: PLR0913
    dut: Dut,
    addr: int,
    *,
    write: bool,
    line: bool = False,
    data: int = 0,
    be: int = 0xF,
    data_x: int = 0,
    be_x: int = 0,
    advance_after: int = 0,
):
    """Run one access; return (rdata, rdata_x, err, clocks)."""
    dut.i_addr.value = addr
    dut.i_wdata.value = data
    dut.i_byteena.value = be
    dut.i_wdata_x.value = data_x
    dut.i_byteena_x.value = be_x
    dut.i_line.value = int(line)
    request(dut, write)
    for n in range(1, CLOCKS):  # noqa: B007
        await RisingEdge(dut.i_clk)
        await Timer(SETTLE_NS, unit="ns")
        if int(dut.o_ready.value):
            break
    else:
        raise AssertionError("the access never finished")
    err = int(dut.o_err.value)
    for _ in range(advance_after):
        await RisingEdge(dut.i_clk)
        await Timer(SETTLE_NS, unit="ns")
        check_equal(int(dut.o_ready.value), 1, "ready waits for advance")
    request(dut, None)
    dut.i_mem_advance.value = 1
    await RisingEdge(dut.i_clk)
    await Timer(SETTLE_NS, unit="ns")
    dut.i_mem_advance.value = 0
    return int(dut.o_rdata.value), int(dut.o_rdata_x.value), err, n


@cocotb.test()
async def test_a_word_write_is_one_beat(dut: Dut):
    """Check the AW and W fields of a word write and the end of it."""
    slave = await setup(dut)
    _, _, err, _ = await access(
        dut, BASE + 0x1236, write=True, data=0xCAFEF00D, be=0x6
    )
    check_equal(slave.aw, [(BASE + 0x1234, 0, 2, 1, 0)], "word aligned INCR")
    check_equal(slave.w, [(0xCAFEF00D, 0x6, 1)])
    check_equal(err, 0)
    check_equal(slave.problems, [])


@cocotb.test()
async def test_a_word_read_returns_the_word_on_the_advance(dut: Dut):
    """Check the AR fields and the data showing with the advance."""
    slave = await setup(dut)
    dut.i_addr.value = BASE + 0x40
    first = await access(dut, BASE + 0x40, write=False)
    check_equal(first[0], word_at(BASE + 0x40))
    check_equal(slave.ar, [(BASE + 0x40, 0, 2, 1, 0)])
    dut.i_rden.value = 1
    dut.i_addr.value = BASE + 0x44
    for _ in range(CLOCKS):
        await RisingEdge(dut.i_clk)
        await Timer(SETTLE_NS, unit="ns")
        if int(dut.o_ready.value):
            break
    check_equal(int(dut.o_rdata.value), word_at(BASE + 0x40), "old word")
    dut.i_mem_advance.value = 1
    await RisingEdge(dut.i_clk)
    await Timer(SETTLE_NS, unit="ns")
    dut.i_mem_advance.value = 0
    dut.i_rden.value = 0
    check_equal(int(dut.o_rdata.value), word_at(BASE + 0x44))
    check_equal(slave.problems, [])


@cocotb.test()
async def test_a_line_write_is_a_burst_of_four(dut: Dut):
    """Check the burst fields, the order of the beats and wlast."""
    slave = await setup(dut)
    words = [0x11110000, 0x22220001, 0x33330002, 0x44440003]
    strobes = [0xF, 0x3, 0xC, 0x9]
    await access(
        dut,
        BASE + 0x2000,
        write=True,
        line=True,
        data=words[0],
        be=strobes[0],
        data_x=words[1] | (words[2] << 32) | (words[3] << 64),
        be_x=strobes[1] | (strobes[2] << 4) | (strobes[3] << 8),
    )
    check_equal(slave.aw, [(BASE + 0x2000, 3, 2, 1, 0)])
    check_equal(
        slave.w,
        [(words[i], strobes[i], int(i == LAST_BEAT)) for i in range(4)],
    )


@cocotb.test()
async def test_a_line_read_is_a_burst_of_four(dut: Dut):
    """Check the burst request and the four words delivered."""
    slave = await setup(dut)
    base = BASE + 0x3000
    value, extra, err, _ = await access(dut, base, write=False, line=True)
    check_equal(slave.ar, [(base, 3, 2, 1, 0)])
    check_equal(value, word_at(base))
    check_equal(
        extra,
        word_at(base + 4)
        | (word_at(base + 8) << 32)
        | (word_at(base + 12) << 64),
    )
    check_equal(err, 0)


@cocotb.test()
async def test_a_slow_slave_sees_stable_requests(dut: Dut):
    """Check ready stalls and the stability of valid."""
    slave = await setup(dut, stall=3)
    base = BASE + 0x4000
    await access(
        dut,
        base,
        write=True,
        line=True,
        data=0xA,
        be=0xF,
        data_x=0xB | (0xC << 32) | (0xD << 64),
        be_x=0xFFF,
    )
    value, _, err, _ = await access(dut, base, write=False, line=True)
    check_equal(len(slave.w), 4)
    check_equal(value, word_at(base))
    check_equal(err, 0)
    check_equal(slave.problems, [], "payload moved while valid was up")


@cocotb.test()
async def test_the_ready_waits_for_the_advance(dut: Dut):
    """Check that ready stays up until the advance."""
    slave = await setup(dut)
    await access(dut, BASE + 0x80, write=False, advance_after=6)
    check_equal(len(slave.ar), 1, "one request for one access")


@cocotb.test()
async def test_an_error_response_is_reported(dut: Dut):
    """Check err with SLVERR in B, in R and with a wrong rlast."""
    slave = await setup(dut)
    cases: list[tuple[str, dict[str, Any], dict[str, Any], int]] = [
        ("SLVERR in B", {"bresp": SLVERR}, {"write": True, "data": 1}, 1),
        ("SLVERR in R", {"rresp": SLVERR}, {"write": False}, 1),
        ("early rlast", {"rlast_at": 1}, {"write": False, "line": True}, 1),
        ("no rlast", {"rlast_at": 5}, {"write": False, "line": True}, 1),
        ("a good access", {}, {"write": False, "line": True}, 0),
    ]
    for name, fields, kwargs, want in cases:
        slave.bresp, slave.rresp, slave.rlast_at = OKAY, OKAY, None
        for field, value in fields.items():
            setattr(slave, field, value)
        err = (await access(dut, BASE + 0x20, **kwargs))[2]
        check_equal(err, want, name)


@cocotb.test()
async def test_a_response_before_the_request_is_not_taken(dut: Dut):
    """Check that bready waits for AW and W to be accepted."""
    slave = await setup(dut, stall=4)
    slave.early_b = True
    await access(dut, BASE + 0x90, write=True, data=0x1234)
    check_equal(len(slave.w), 1)
    check_equal(slave.early_taken, [])
    check_equal(slave.problems, [])
