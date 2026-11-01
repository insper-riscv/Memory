"""The AXI4 slave of the SDRAM, with the SDRAM system behind it.

The testbench plays the AXI4 master. A burst of four beats aligned to 16 bytes is one line access of
the memory; any other INCR burst is one word access per beat; what the slave does not serve (a size
other than 4 bytes, a burst type other than INCR, an address not aligned to 4 bytes) is answered
with SLVERR and never reaches the chip. Every test compares the chip with a Python copy.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.external.AxiRouter import (
    OKAY,
    read_burst,
    write_burst,
)
from tests.python.unittests.external.sdram_helpers import CPU_NS, MEM_NS, merge

SLVERR = 2
INCR, FIXED, WRAP = 1, 0, 2
BASE = 0x40000000


async def setup(dut):
    for sig in ("awvalid", "wvalid", "arvalid", "bready", "rready"):
        getattr(dut, f"i_s_{sig}").value = 0
    for ch in ("aw", "ar"):
        getattr(dut, f"i_s_{ch}len").value = 0
        getattr(dut, f"i_s_{ch}size").value = 2
        getattr(dut, f"i_s_{ch}burst").value = 1
    dut.i_s_wlast.value = 1
    dut.i_dbg_word_addr.value = 0
    dut.i_rst.value = 1
    dut.i_rst_mem.value = 1
    cocotb.start_soon(Clock(dut.i_clk_mem, MEM_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.i_clk, CPU_NS, unit="ns").start())
    for _ in range(6):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    dut.i_rst_mem.value = 0
    for _ in range(int(2 * 200_000 / CPU_NS)):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_init_done.value) and int(dut.o_dbg_init_ok.value):
            return
    raise AssertionError("the controller never finished its power-up sequence")


async def chip_word(dut, word):
    dut.i_dbg_word_addr.value = word
    for _ in range(3):
        await RisingEdge(dut.i_clk_mem)
    await Timer(1, unit="ns")
    return int(dut.o_dbg_word_data.value)


def word_of(addr):
    return (addr - BASE) >> 2


@cocotb.test()
async def test_a_line_burst_is_written_and_read_whole(dut):
    await setup(dut)
    addr = BASE + 0x1230
    beats = [(0xA0000000 + i, 0xF) for i in range(4)]
    assert await write_burst(dut, addr, beats) == OKAY
    for i in range(4):
        assert await chip_word(dut, word_of(addr) + i) == 0xA0000000 + i
    got = await read_burst(dut, addr, 4)
    assert got == [
        (0xA0000000 + i, OKAY, 1 if i == 3 else 0) for i in range(4)
    ], got


@cocotb.test()
async def test_byte_strobes_of_a_line_burst(dut):
    await setup(dut)
    addr = BASE + 0x2000
    assert (
        await write_burst(
            dut, addr, [(0x11111111 * (i + 1), 0xF) for i in range(4)]
        )
        == OKAY
    )
    new = [0xA1B2C3D4, 0x55667788, 0x99AABBCC, 0x0F1E2D3C]
    strobes = [0x3, 0xC, 0x5, 0xA]
    assert await write_burst(dut, addr, list(zip(new, strobes))) == OKAY
    for i in range(4):
        want = merge(0x11111111 * (i + 1), new[i], strobes[i])
        assert await chip_word(dut, word_of(addr) + i) == want, f"word {i}"


@cocotb.test()
async def test_other_lengths_are_one_word_per_beat(dut):
    """One, two, three, five and eight beats, aligned or not to 16 bytes, one word access per beat."""
    await setup(dut)
    for n, off in [
        (1, 0x40),
        (2, 0x84),
        (3, 0x108),
        (5, 0x200),
        (8, 0x330),
        (8, 0x430),
        (4, 0x504),
    ]:
        addr = BASE + 0x3000 + off
        beats = [(0xC0DE0000 + 16 * n + i, 0xF) for i in range(n)]
        assert await write_burst(dut, addr, beats) == OKAY, (
            f"{n} beats at +{off:#x}"
        )
        for i in range(n):
            assert await chip_word(dut, word_of(addr) + i) == beats[i][0], (
                f"{n} beats at +{off:#x}, word {i}"
            )
        got = await read_burst(dut, addr, n)
        assert got == [
            (beats[i][0], OKAY, 1 if i == n - 1 else 0) for i in range(n)
        ], f"{n} beats at +{off:#x}: {got}"


@cocotb.test()
async def test_what_it_does_not_serve_is_slverr_and_touches_nothing(dut):
    await setup(dut)
    addr = BASE + 0x4000
    assert await write_burst(dut, addr, [(0x77777777, 0xF)]) == OKAY
    before = await chip_word(dut, word_of(addr))
    cases = [
        ("wrap", dict(burst=WRAP), addr, 4),
        ("fixed", dict(burst=FIXED), addr, 4),
        ("half-word size", dict(size=1), addr, 2),
        ("byte size", dict(size=0), addr, 3),
        ("8-byte size", dict(size=3), addr, 2),
        ("unaligned", {}, addr + 2, 1),
    ]
    for name, kw, a, n in cases:
        resp = await write_burst(
            dut, a, [(0xBAD00000 + i, 0xF) for i in range(n)], **kw
        )
        assert resp == SLVERR, f"{name}: write answered {resp}"
        got = await read_burst(dut, a, n, **kw)
        assert got == [
            (0, SLVERR, 1 if i == n - 1 else 0) for i in range(n)
        ], f"{name}: {got}"
        assert await chip_word(dut, word_of(addr)) == before, (
            f"{name} reached the chip"
        )
    # and the slave serves a good one after all of them
    assert await write_burst(dut, addr, [(0x12345678, 0xF)]) == OKAY
    assert await chip_word(dut, word_of(addr)) == 0x12345678


@cocotb.test()
async def test_a_line_read_is_faster_than_four_single_reads(dut):
    await setup(dut)
    addr = BASE + 0x5000

    async def timed(coro):
        t = [0]

        async def count():
            while True:
                await RisingEdge(dut.i_clk)
                t[0] += 1

        c = cocotb.start_soon(count())
        await coro
        c.cancel()
        return t[0]

    line = await timed(read_burst(dut, addr, 4))
    singles = 0
    for i in range(4):
        singles += await timed(read_burst(dut, addr + 4 * i, 1))
    dut._log.info(f"a line read took {line} clocks, four word reads {singles}")
    assert line < singles - 4, f"{line} against {singles}"
