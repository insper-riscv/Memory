"""Helpers shared by the SDRAM system tests: clocks and reset, one core access, the stored word of the chip model."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

MEM_NS = 7                 # 142.857 MHz
CPU_NS = 56                # the core clock: the memory clock divided by 8
LAST_WORD = (1 << 24) - 1  # 64 MB of 32-bit words


async def _post_edge(dut):
    await RisingEdge(dut.clk_cpu)
    await Timer(1, unit="ns")


async def start(dut, cpu_ns=CPU_NS, cpu_offset_ns=0):
    """Clocks, reset, and wait for the controller to finish its power-up sequence."""
    for sig in (dut.rden, dut.wren, dut.mem_advance, dut.dbg_flip):
        sig.value = 0
    dut.addr.value = 0
    dut.wdata.value = 0
    dut.byteena.value = 0
    dut.dbg_word_addr.value = 0
    dut.dbg_flip_addr.value = 0
    dut.dbg_flip_bit.value = 0
    dut.rst_mem.value = 1
    dut.rst_cpu.value = 1
    cocotb.start_soon(Clock(dut.clk_mem, MEM_NS, unit="ns").start())
    if cpu_offset_ns:
        await Timer(cpu_offset_ns, unit="ns")
    cocotb.start_soon(Clock(dut.clk_cpu, cpu_ns, unit="ns").start())
    for _ in range(6):
        await RisingEdge(dut.clk_cpu)
    dut.rst_mem.value = 0
    dut.rst_cpu.value = 0
    # 200 us of power-up wait, with a margin
    for _ in range(int(2 * 200_000 / cpu_ns)):
        await _post_edge(dut)
        if int(dut.init_done.value) and int(dut.dbg_init_ok.value):
            return
    raise AssertionError("the controller never finished its power-up sequence")


async def access(dut, we, word, wdata=0, be=0xF, hold=0):
    """One core access. Returns (read data, cpu cycles until ready).

    hold: extra cpu cycles the pipeline stays stopped after ready (e.g. a muldiv),
    during which ready must stay high and the read data must not change.
    """
    dut.addr.value = 0x40000000 | (word << 2)
    dut.wdata.value = wdata
    dut.byteena.value = be
    dut.wren.value = 1 if we else 0
    dut.rden.value = 0 if we else 1
    before = int(dut.rdata.value)
    cycles = 0
    while True:
        await _post_edge(dut)
        cycles += 1
        if int(dut.ready.value):
            break
        assert cycles < 400, "ready never came"
    for _ in range(hold):
        assert int(dut.ready.value) == 1, "ready dropped before the pipeline advanced"
        assert int(dut.rdata.value) == before, "read data changed before the pipeline advanced"
        await _post_edge(dut)
    assert int(dut.ready.value) == 1
    dut.mem_advance.value = 1          # the pipeline advances on the next edge
    await _post_edge(dut)
    dut.mem_advance.value = 0
    dut.rden.value = 0
    dut.wren.value = 0
    return int(dut.rdata.value), cycles


def merge(old, new, be):
    out = old
    for i in range(4):
        if (be >> i) & 1:
            out = (out & ~(0xFF << (8 * i))) | (new & (0xFF << (8 * i)))
    return out


async def model_word(dut, word):
    """The word as stored in the chip model."""
    dut.dbg_word_addr.value = word
    for _ in range(3):
        await RisingEdge(dut.clk_mem)
    await Timer(1, unit="ns")
    return int(dut.dbg_word_data.value)
