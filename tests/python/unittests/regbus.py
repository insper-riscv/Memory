"""Register bus helpers shared by the tests of the flash controllers."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.dut import Dut

BUSY, DONE, ERR = 1, 2, 4


async def start(dut: Dut) -> None:
    """Start the clock and reset a controller with a register bus."""
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    dut.i_rst.value = 1
    dut.i_write.value = 0
    dut.i_read.value = 0
    dut.i_address.value = 0
    dut.i_data_in.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await RisingEdge(dut.i_clk)


async def reg_write(dut: Dut, reg: int, value: int) -> None:
    """Write a register for one clock."""
    dut.i_address.value = reg
    dut.i_data_in.value = value
    dut.i_write.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_write.value = 0
    await Timer(1, unit="ns")


async def reg_read(dut: Dut, reg: int) -> int:
    """Return a register."""
    dut.i_address.value = reg
    await Timer(1, unit="ns")
    return int(dut.o_data_out.value)


async def wait_done(dut: Dut, limit: int = 400000) -> int:
    """Wait for the busy flag of register 0 to fall; return status."""
    for _ in range(limit):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        status = await reg_read(dut, 0)
        if not status & BUSY:
            return status
    raise AssertionError("the controller stayed busy")


async def clear_flags(dut: Dut) -> None:
    """Clear the done and error flags of register 0."""
    await reg_write(dut, 0, DONE | ERR)
