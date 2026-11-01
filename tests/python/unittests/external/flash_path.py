"""The FLASH path end to end.

Icache, two region routers, the FLASH arbiter and the chip.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true

SLOW_CLOCKS = 12  # clocks a flash line takes, at least
FAST_CLOCKS = 2  # clocks a request that skips the chip takes, at most

FLASH = 0x20000000
SDRAM = 0x40000000


def word(addr):
    """Return the data word the models hold at an address."""
    return ((addr * 2654435761) ^ 0x5A5A1234) & 0xFFFFFFFF


async def start(dut):
    """Start the clock and reset the DUT."""
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    dut.i_rst.value = 1
    dut.i_addr.value = FLASH
    dut.i_sel.value = 1
    dut.i_invalidate.value = 0
    for n in ("i_b_rden", "i_b_wren", "i_b_line", "i_b_advance"):
        getattr(dut, n).value = 0
    dut.i_b_addr.value = FLASH
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0


async def fetch(dut, addr, timeout=400):
    """Fetch one instruction word and return it."""
    dut.i_addr.value = addr
    dut.i_sel.value = 1
    for n in range(timeout):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_ready.value) == 1:
            return int(dut.o_data.value), n
    raise AssertionError(f"no instruction for {addr:#x}")


async def b_request(dut, addr, rd=0, wr=0, line=0, timeout=400):  # noqa: PLR0913, PLR0917
    """Issue a request on port B and return the answer."""
    dut.i_b_addr.value = addr
    dut.i_b_rden.value = rd
    dut.i_b_wren.value = wr
    dut.i_b_line.value = line
    for n in range(timeout):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_b_ready.value) == 1:
            r, rx = int(dut.o_b_rdata.value), int(dut.o_b_rdata_x.value)
            dut.i_b_advance.value = 1
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            dut.i_b_rden.value = 0
            dut.i_b_wren.value = 0
            dut.i_b_advance.value = 0
            return r, rx, n
    raise AssertionError(f"no ready for B at {addr:#x}")


@cocotb.test()
async def test_instruction_fetch_from_the_flash(dut):
    """Check that instruction fetch from the flash."""
    await start(dut)
    base = FLASH + 0x10230
    for i in range(4):
        data, waited = await fetch(dut, base + 4 * i)
        check_equal(data, word(base + 4 * i))
        if i == 0:
            check_true(waited > SLOW_CLOCKS)
        else:
            check_true(waited <= 1)
    check_equal(int(dut.o_chip_reqs.value), 1)
    check_equal(int(dut.o_si_rden.value), 0)


@cocotb.test()
async def test_b_reads_a_line_while_the_icache_is_idle(dut):
    """Check that b reads a line while the icache is idle."""
    await start(dut)
    r, rx, _ = await b_request(dut, FLASH + 0x400, rd=1, line=1)
    got = [r] + [(rx >> (32 * i)) & 0xFFFFFFFF for i in range(3)]
    check_equal(got, [word(FLASH + 0x400 + 4 * i) for i in range(4)])
    check_equal(int(dut.o_chip_reqs.value), 1)


@cocotb.test()
async def test_both_masters_at_once_get_their_own_data(dut):
    """Check that both masters at once get their own data."""
    await start(dut)
    b = cocotb.start_soon(b_request(dut, FLASH + 0x800, rd=1, line=1))
    data, _ = await fetch(dut, FLASH + 0x100)
    r, rx, _ = await b
    check_equal(data, word(FLASH + 0x100))
    check_equal(r, word(FLASH + 0x800))
    check_equal(rx & 0xFFFFFFFF, word(FLASH + 0x804))
    check_equal(int(dut.o_chip_reqs.value), 2)


@cocotb.test()
async def test_a_store_to_the_flash_never_reaches_the_chip(dut):
    """Check that a store to the flash never reaches the chip."""
    await start(dut)
    _, _, waited = await b_request(dut, FLASH + 0x900, wr=1)
    check_true(waited <= FAST_CLOCKS)
    check_equal(int(dut.o_chip_reqs.value), 0)
    check_equal(int(dut.o_sd_wren.value), 0)


@cocotb.test()
async def test_a_read_past_the_window_is_zero_and_skips_the_chip(dut):
    """Check that a read past the window is zero and skips the chip."""
    await start(dut)
    r, rx, _ = await b_request(dut, FLASH + 0x200000, rd=1, line=1)
    check_true(r == 0 and rx == 0)
    check_equal(int(dut.o_chip_reqs.value), 0)


@cocotb.test()
async def test_sdram_requests_do_not_touch_the_flash_path(dut):
    """Check that sdram requests do not touch the flash path."""
    await start(dut)
    dut.i_addr.value = SDRAM + 0x40
    dut.i_sel.value = 1
    seen = 0
    for _ in range(30):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        seen |= int(dut.o_si_rden.value)
    check_equal(seen, 1, "the SDRAM fetch has to be steered to the SDRAM side")
    check_equal(int(dut.o_chip_reqs.value), 0)
