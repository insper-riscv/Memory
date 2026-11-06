"""mem_region_router with hold_rdata.

The master does not keep the data it read, so its address keeps changing
after the request ends. The data read stays the one of the region of the
last completed request until the next one completes.

"""

import cocotb
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.cache.mem_region_router import (
    FLASH,
    SDRAM,
    start,
    word,
)
from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut


async def complete(dut: Dut, addr: int, rd: int = 0, wr: int = 0) -> None:
    """Hold the request until ready, advance for a cycle, then drop.

    Unlike the plain request helper, it reads nothing before the advance:
    with hold_rdata the data read is only the request's own after it.

    """
    dut.i_addr.value = addr
    dut.i_rden.value = rd
    dut.i_wren.value = wr
    for _ in range(100):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_ready.value) == 1:
            dut.i_advance.value = 1
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            dut.i_rden.value = 0
            dut.i_wren.value = 0
            dut.i_advance.value = 0
            return
    raise AssertionError(f"no ready for {addr:#x}")


@cocotb.test()
async def test_flash_data_survives_a_new_address(dut: Dut):
    """Check that the FLASH word stays after the address leaves the FLASH."""
    await start(dut)
    await complete(dut, FLASH + 0x400, rd=1)
    wanted = word(0x22220000, (FLASH + 0x400) & ~0xF)
    check_equal(int(dut.o_rdata.value), wanted)
    dut.i_addr.value = SDRAM + 0x40
    await Timer(1, unit="ns")
    check_equal(int(dut.o_rdata.value), wanted)


@cocotb.test()
async def test_sdram_data_survives_a_new_address(dut: Dut):
    """Check that the SDRAM word stays after the address enters the FLASH."""
    await start(dut)
    await complete(dut, SDRAM + 0x80, rd=1)
    wanted = word(0x11110000, (SDRAM + 0x80) & ~0xF)
    check_equal(int(dut.o_rdata.value), wanted)
    dut.i_addr.value = FLASH + 0x10
    await Timer(1, unit="ns")
    check_equal(int(dut.o_rdata.value), wanted)


@cocotb.test()
async def test_an_absorbed_store_leaves_zero(dut: Dut):
    """Check that a store absorbed by the router leaves zero as the data."""
    await start(dut)
    await complete(dut, SDRAM + 0x80, rd=1)
    await complete(dut, FLASH + 0x20, wr=1)
    check_equal(int(dut.o_rdata.value), 0)
