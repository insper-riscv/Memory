"""Read face of the flash chips: request, handshake and clocks.

The adapters of the serial flash and of the MAX 10 flash give the SoC
the face of the parallel NOR controller: the request stays on the
address, read and line inputs until ready rises, ready holds until
advance, and the data holds with it.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut

MASK32 = 0xFFFFFFFF


async def start(dut: Dut, period_ns: int = 10) -> None:
    """Start the clock and reset a read face with no request."""
    cocotb.start_soon(Clock(dut.i_clk, period_ns, unit="ns").start())
    dut.i_rst.value = 1
    dut.i_rden.value = 0
    dut.i_line.value = 0
    dut.i_advance.value = 0
    dut.i_addr.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")


async def read(
    dut: Dut, addr: int, line: int, timeout: int = 4000
) -> tuple[list[int], int]:
    """Hold a request until ready, check the hold, then advance.

    Return the words read (one, or four for a line) and the clocks from
    the request to ready.
    """
    dut.i_addr.value = addr
    dut.i_line.value = line
    dut.i_rden.value = 1
    for clocks in range(1, timeout):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_ready.value) == 1:
            check_equal(int(dut.o_busy.value), 0, "busy and ready together")
            words = [int(dut.o_rdata.value)]
            if line:
                x = int(dut.o_rdata_x.value)
                words += [(x >> (32 * i)) & MASK32 for i in range(3)]
            # The data and the ready hold until the request advances.
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            check_equal(int(dut.o_ready.value), 1, "ready has to hold")
            check_equal(int(dut.o_rdata.value), words[0], "data has to hold")
            dut.i_rden.value = 0
            dut.i_advance.value = 1
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            dut.i_advance.value = 0
            check_equal(int(dut.o_ready.value), 0, "ready drops on advance")
            return words, clocks
    raise AssertionError(f"no ready for {addr:#x}")
