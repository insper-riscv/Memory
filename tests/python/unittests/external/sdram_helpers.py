"""Helpers shared by the SDRAM system tests.

Clocks and reset, one core access, the stored word of the chip model.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

MEM_NS = 7  # 142.857 MHz
CPU_NS = 56  # the core clock: the memory clock divided by 8
LAST_WORD = (1 << 24) - 1  # 64 MB of 32-bit words


async def _post_edge(dut):
    await RisingEdge(dut.i_clk_cpu)
    await Timer(1, unit="ns")


async def start(dut, cpu_ns=CPU_NS, cpu_offset_ns=0):
    """Start the clocks, reset, and wait for the power-up sequence."""
    for sig in (dut.i_rden, dut.i_wren, dut.i_mem_advance, dut.i_dbg_flip):
        sig.value = 0
    if hasattr(dut, "i_line"):
        dut.i_line.value = 0
        dut.i_wdata_x.value = 0
        dut.i_byteena_x.value = 0
    dut.i_addr.value = 0
    dut.i_wdata.value = 0
    dut.i_byteena.value = 0
    dut.i_dbg_word_addr.value = 0
    dut.i_dbg_flip_addr.value = 0
    dut.i_dbg_flip_bit.value = 0
    dut.i_rst_mem.value = 1
    dut.i_rst_cpu.value = 1
    cocotb.start_soon(Clock(dut.i_clk_mem, MEM_NS, unit="ns").start())
    if cpu_offset_ns:
        await Timer(cpu_offset_ns, unit="ns")
    cocotb.start_soon(Clock(dut.i_clk_cpu, cpu_ns, unit="ns").start())
    for _ in range(6):
        await RisingEdge(dut.i_clk_cpu)
    dut.i_rst_mem.value = 0
    dut.i_rst_cpu.value = 0
    # 200 us of power-up wait, with a margin
    for _ in range(int(2 * 200_000 / cpu_ns)):
        await _post_edge(dut)
        if int(dut.o_init_done.value) and int(dut.o_dbg_init_ok.value):
            return
    raise AssertionError("the controller never finished its power-up sequence")


async def access(dut, we, word, wdata=0, be=0xF, hold=0):  # noqa: PLR0913, PLR0917
    """One core access. Returns (read data, cpu cycles until ready).

    Hold: extra cpu cycles the pipeline stays stopped after ready (e.g.
    a muldiv), during which ready must stay high and the read data must
    not change.

    """
    dut.i_addr.value = 0x40000000 | (word << 2)
    dut.i_wdata.value = wdata
    dut.i_byteena.value = be
    dut.i_wren.value = 1 if we else 0
    dut.i_rden.value = 0 if we else 1
    before = int(dut.o_rdata.value)
    cycles = 0
    while True:
        await _post_edge(dut)
        cycles += 1
        if int(dut.o_ready.value):
            break
        assert cycles < 400, "ready never came"
    for _ in range(hold):
        assert int(dut.o_ready.value) == 1, (
            "ready dropped before the pipeline advanced"
        )
        assert int(dut.o_rdata.value) == before, (
            "read data changed before the pipeline advanced"
        )
        await _post_edge(dut)
    assert int(dut.o_ready.value) == 1
    dut.i_mem_advance.value = 1  # the pipeline advances on the next edge
    await _post_edge(dut)
    dut.i_mem_advance.value = 0
    dut.i_rden.value = 0
    dut.i_wren.value = 0
    return int(dut.o_rdata.value), cycles


def merge(old, new, be):
    """Merge new bytes into an old word by byte enable."""
    out = old
    for i in range(4):
        if (be >> i) & 1:
            out = (out & ~(0xFF << (8 * i))) | (new & (0xFF << (8 * i)))
    return out


async def model_word(dut, word):
    """Return the word as stored in the chip model."""
    dut.i_dbg_word_addr.value = word
    for _ in range(3):
        await RisingEdge(dut.i_clk_mem)
    await Timer(1, unit="ns")
    return int(dut.o_dbg_word_data.value)


async def line_access(dut, we, word, words=None, bes=None, hold=0):  # noqa: PLR0913, PLR0917
    """One access of a line (four words from the word address `word`.

    Aligned down to 4).

    words/bes: the four words and their byte enables for a write.
    Returns (the four words read, cpu cycles until ready). The extra
    words travel on wdata_x/byteena_x/rdata_x.

    """
    word &= ~3
    words = words or [0, 0, 0, 0]
    bes = bes or [0xF] * 4
    dut.i_addr.value = 0x40000000 | (word << 2)
    dut.i_wdata.value = words[0]
    dut.i_byteena.value = bes[0]
    dut.i_wdata_x.value = words[1] | (words[2] << 32) | (words[3] << 64)
    dut.i_byteena_x.value = bes[1] | (bes[2] << 4) | (bes[3] << 8)
    dut.i_line.value = 1
    dut.i_wren.value = 1 if we else 0
    dut.i_rden.value = 0 if we else 1
    before = (int(dut.o_rdata.value), int(dut.o_rdata_x.value))
    cycles = 0
    while True:
        await _post_edge(dut)
        cycles += 1
        if int(dut.o_ready.value):
            break
        assert cycles < 400, "ready never came"
    for _ in range(hold):
        assert int(dut.o_ready.value) == 1, (
            "ready dropped before the pipeline advanced"
        )
        assert (int(dut.o_rdata.value), int(dut.o_rdata_x.value)) == before, (
            "read data changed before the pipeline advanced"
        )
        await _post_edge(dut)
    dut.i_mem_advance.value = 1
    await _post_edge(dut)
    dut.i_mem_advance.value = 0
    dut.i_rden.value = 0
    dut.i_wren.value = 0
    dut.i_line.value = 0
    x = int(dut.o_rdata_x.value)
    return [
        int(dut.o_rdata.value),
        x & 0xFFFFFFFF,
        (x >> 32) & 0xFFFFFFFF,
        x >> 64,
    ], cycles
