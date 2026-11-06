"""axi_slave_word_bridge, alone, with a Python word memory behind it.

The testbench plays the AXI4 master (the burst helpers) and the memory
of the word contract. A burst of four beats aligned to 16 bytes is one
line access of the memory, any other INCR burst is one word access per
beat, and what the bridge does not serve is answered with SLVERR with
no access at all.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from tests.python.unittests.barramento.axi_burst import (
    OKAY,
    read_burst,
    write_burst,
)
from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

LAST_BEAT = 3  # index of the last beat of a line
SIGNALS = ("awvalid", "wvalid", "arvalid", "bready", "rready")
SLVERR = 2
INCR, FIXED, WRAP = 1, 0, 2
BASE = 0x40000000
LATENCY = 2  # clocks the memory takes to answer an access
SETTLE_NS = 1


def merge(old: int, new: int, strobes: int) -> int:
    """Return old with the bytes of new enabled by the strobes."""
    out = old
    for b in range(4):
        if (strobes >> b) & 1:
            mask = 0xFF << (8 * b)
            out = (out & ~mask) | (new & mask)
    return out


class Memory:
    """The memory of the word contract, with a fixed latency."""

    def __init__(self) -> None:
        """Start empty; unwritten words depend on the address."""
        self.words: dict[int, int] = {}
        self.accesses: list[tuple[str, int, bool]] = []

    def read(self, addr: int) -> int:
        """Return the word at a byte address."""
        return self.words.get(addr >> 2, 0x5EED0000 + (addr >> 2 & 0xFFFF))

    async def run(self, dut: Dut) -> None:
        """Answer the accesses of the bridge, one at a time."""
        waited = 0
        while True:
            await RisingEdge(dut.i_clk)
            if int(dut.o_mem_advance.value) == 1:
                dut.i_ready.value = 0
                waited = 0
                continue
            rd, wr = int(dut.o_rden.value), int(dut.o_wren.value)
            if not (rd or wr) or int(dut.i_ready.value) == 1:
                continue
            waited += 1
            if waited >= LATENCY:
                self.serve(dut, bool(wr))
                dut.i_ready.value = 1

    def serve(self, dut: Dut, write: bool) -> None:
        """Perform the access that is on the ports."""
        addr = int(dut.o_addr.value)
        line = int(dut.o_line.value) == 1
        self.accesses.append(("w" if write else "r", addr, line))
        if write:
            self.store(dut, addr, 4 if line else 1)
        else:
            dut.i_rdata.value = self.read(addr)
            extra = 0
            for k in range(3):
                extra |= self.read(addr + 4 * (k + 1)) << (32 * k)
            dut.i_rdata_x.value = extra if line else 0

    def store(self, dut: Dut, addr: int, count: int) -> None:
        """Write `count` words, the first from the word-0 ports."""
        x_data = int(dut.o_wdata_x.value)
        x_be = int(dut.o_byteena_x.value)
        data = [int(dut.o_wdata.value)]
        be = [int(dut.o_byteena.value)]
        data += [(x_data >> (32 * k)) & 0xFFFFFFFF for k in range(3)]
        be += [(x_be >> (4 * k)) & 0xF for k in range(3)]
        for k in range(count):
            old = self.read(addr + 4 * k)
            self.words[(addr >> 2) + k] = merge(old, data[k], be[k])


async def setup(dut: Dut) -> Memory:
    """Reset the DUT and start the clock and the memory."""
    memory = Memory()
    idle = {f"i_s_{sig}": 0 for sig in SIGNALS}
    for ch in ("aw", "ar"):
        idle.update({f"i_s_{ch}len": 0, f"i_s_{ch}size": 2})
        idle[f"i_s_{ch}burst"] = 1
    idle.update(
        i_s_awaddr=0,
        i_s_araddr=0,
        i_s_wdata=0,
        i_s_wstrb=0,
        i_s_wlast=1,
        i_ready=0,
        i_rdata=0,
        i_rdata_x=0,
    )
    for name, value in idle.items():
        getattr(dut, name).value = value
    dut.i_rst.value = 1
    await Timer(SETTLE_NS, unit="ns")
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    cocotb.start_soon(memory.run(dut))
    await ClockCycles(dut.i_clk, 4)
    dut.i_rst.value = 0
    await ClockCycles(dut.i_clk, 1)
    await Timer(SETTLE_NS, unit="ns")
    return memory


@cocotb.test()
async def test_a_line_burst_is_one_line_access(dut: Dut):
    """Check that a 16-byte aligned burst of four is a line access."""
    memory = await setup(dut)
    addr = BASE + 0x1230
    beats = [(0xA0000000 + i, 0xF) for i in range(4)]
    check_equal(await write_burst(dut, addr, beats), OKAY)
    check_equal(memory.accesses, [("w", addr, True)])
    for i in range(4):
        check_equal(memory.words[(addr >> 2) + i], 0xA0000000 + i)
    memory.accesses.clear()
    got = await read_burst(dut, addr, 4)
    check_equal(memory.accesses, [("r", addr, True)])
    check_equal(
        got, [(0xA0000000 + i, OKAY, int(i == LAST_BEAT)) for i in range(4)]
    )


@cocotb.test()
async def test_the_strobes_reach_the_memory_as_byte_enables(dut: Dut):
    """Check that each beat of a line keeps its own strobes."""
    memory = await setup(dut)
    addr = BASE + 0x2000
    old = [memory.read(addr + 4 * i) for i in range(4)]
    new = [0xA1B2C3D4, 0x55667788, 0x99AABBCC, 0x0F1E2D3C]
    strobes = [0x3, 0xC, 0x5, 0xA]
    check_equal(
        await write_burst(dut, addr, list(zip(new, strobes, strict=True))),
        OKAY,
    )
    for i in range(4):
        want = merge(old[i], new[i], strobes[i])
        check_equal(memory.words[(addr >> 2) + i], want, f"word {i}")


@cocotb.test()
async def test_other_lengths_are_one_word_access_per_beat(dut: Dut):
    """Check the word accesses, in order, of the other bursts."""
    memory = await setup(dut)
    for n, off in [(1, 0x40), (2, 0x84), (3, 0x108), (8, 0x330), (4, 0x504)]:
        addr = BASE + 0x3000 + off
        memory.accesses.clear()
        beats = [(0xC0DE0000 + 16 * n + i, 0xF) for i in range(n)]
        check_equal(await write_burst(dut, addr, beats), OKAY, f"{n}")
        check_equal(
            memory.accesses,
            [("w", addr + 4 * i, False) for i in range(n)],
            f"{n} beats at +{off:#x}",
        )
        memory.accesses.clear()
        got = await read_burst(dut, addr, n)
        check_equal(
            got,
            [(beats[i][0], OKAY, int(i == n - 1)) for i in range(n)],
            f"{n} beats at +{off:#x}",
        )
        check_equal(
            memory.accesses, [("r", addr + 4 * i, False) for i in range(n)]
        )


@cocotb.test()
async def test_what_is_not_served_is_slverr_without_an_access(dut: Dut):
    """Check the errors: wrong size, wrong type, unaligned address."""
    memory = await setup(dut)
    addr = BASE + 0x4000
    cases = [
        ("wrap", 2, WRAP, addr, 4),
        ("fixed", 2, FIXED, addr, 4),
        ("half-word size", 1, INCR, addr, 2),
        ("byte size", 0, INCR, addr, 3),
        ("8-byte size", 3, INCR, addr, 2),
        ("unaligned", 2, INCR, addr + 2, 1),
    ]
    for name, size, burst, a, n in cases:
        resp = await write_burst(
            dut,
            a,
            [(0xBAD00000 + i, 0xF) for i in range(n)],
            size=size,
            burst=burst,
        )
        check_equal(resp, SLVERR, f"{name}: write")
        got = await read_burst(dut, a, n, size=size, burst=burst)
        check_equal(
            got,
            [(0, SLVERR, int(i == n - 1)) for i in range(n)],
            f"{name}: read",
        )
        check_equal(memory.accesses, [], f"{name} reached the memory")
    check_equal(await write_burst(dut, addr, [(0x12345678, 0xF)]), OKAY)
    check_equal(memory.words[addr >> 2], 0x12345678)


@cocotb.test()
async def test_a_write_goes_before_a_read_offered_with_it(dut: Dut):
    """Check that a write and a read at once are served write first."""
    await setup(dut)
    dut.i_s_awvalid.value = 1
    dut.i_s_awaddr.value = BASE + 0x100
    dut.i_s_arvalid.value = 1
    dut.i_s_araddr.value = BASE + 0x200
    await Timer(SETTLE_NS, unit="ns")
    check_equal(int(dut.o_s_awready.value), 1)
    check_equal(int(dut.o_s_arready.value), 0, "the read waits")
    await RisingEdge(dut.i_clk)
    await Timer(SETTLE_NS, unit="ns")
    dut.i_s_awvalid.value = 0
    check_equal(int(dut.o_s_awready.value), 0, "busy with the write")
    check_equal(int(dut.o_s_arready.value), 0)


@cocotb.test()
async def test_the_response_waits_for_bready(dut: Dut):
    """Check that bvalid is held until the master takes the response."""
    await setup(dut)
    dut.i_s_wvalid.value = 1
    dut.i_s_wdata.value = 0xAB
    dut.i_s_wstrb.value = 0xF
    dut.i_s_awaddr.value = BASE + 0x80
    dut.i_s_awvalid.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_s_awvalid.value = 0
    for _ in range(40):
        await RisingEdge(dut.i_clk)
        await Timer(SETTLE_NS, unit="ns")
        if int(dut.o_s_bvalid.value):
            break
    check_true(int(dut.o_s_bvalid.value), "no response")
    for _ in range(5):
        await RisingEdge(dut.i_clk)
        await Timer(SETTLE_NS, unit="ns")
        check_equal(int(dut.o_s_bvalid.value), 1, "held")
        check_equal(int(dut.o_s_awready.value), 0, "no new request yet")
    dut.i_s_bready.value = 1
    await RisingEdge(dut.i_clk)
    await Timer(SETTLE_NS, unit="ns")
    dut.i_s_bready.value = 0
    dut.i_s_wvalid.value = 0
    check_equal(int(dut.o_s_bvalid.value), 0)
    check_equal(int(dut.o_s_awready.value), 1, "free again")
