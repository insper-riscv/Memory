"""flash_loader.

The loader alone, without the JTAG port: the testbench toggles the
command line the way flash_jtag_core does and plays the port B of the
FLASH with a Python copy of the memory.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

OP_HALT, OP_RUN, OP_WRITE, OP_READ, OP_SUMMARY = 1, 2, 3, 4, 5
HALTED, REFUSED = 1, 2
ADDR_WIDTH = 8  # generic addr_width of the entry
WORD_MASK = 0xFFFFFFFF
SETTLE_NS = 1  # time for the registered outputs to settle after an edge
DONE_CLOCKS = 20  # clocks the loader may take to answer a command


class Flash:
    """The port B of the FLASH: registered read, write-through."""

    def __init__(self) -> None:
        """Start with a memory that holds a known word per index."""
        self.mem = [0xC0DE0000 + i for i in range(1 << ADDR_WIDTH)]
        self.writes: list[tuple[int, int]] = []

    async def run(self, dut: Dut) -> None:
        """Sample the port at every edge, as the FLASH does."""
        while True:
            await RisingEdge(dut.i_clk)
            addr = int(dut.o_address_b.value)
            if int(dut.o_wren_b.value) == 1:
                data = int(dut.o_data_b.value)
                self.mem[addr] = data
                self.writes.append((addr, data))
                dut.i_q_b.value = data
            elif int(dut.o_rden_b.value) == 1:
                dut.i_q_b.value = self.mem[addr]


async def start(dut: Dut) -> Flash:
    """Start the clock and the FLASH and reset the loader."""
    flash = Flash()
    dut.i_rst.value = 1
    dut.i_cmd_tog.value = 0
    dut.i_op.value = 0
    dut.i_addr.value = 0
    dut.i_data.value = 0
    dut.i_mem_address.value = 0
    dut.i_mem_rden.value = 0
    dut.i_q_b.value = 0
    await Timer(SETTLE_NS, unit="ns")
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    cocotb.start_soon(flash.run(dut))
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await idle(dut, 1)
    return flash


async def command(dut: Dut, op: int, addr: int = 0, data: int = 0) -> None:
    """Send a command and wait for the answer of the loader."""
    done = int(dut.o_done_tog.value)
    dut.i_op.value = op
    dut.i_addr.value = addr
    dut.i_data.value = data
    dut.i_cmd_tog.value = 1 - int(dut.i_cmd_tog.value)
    for _ in range(DONE_CLOCKS):
        await RisingEdge(dut.i_clk)
        await Timer(SETTLE_NS, unit="ns")
        if int(dut.o_done_tog.value) != done:
            return
    raise AssertionError(f"op {op} was never answered")


def status(dut: Dut) -> int:
    """Return the status the loader answers with."""
    return int(dut.o_rsp_status.value)


async def idle(dut: Dut, clocks: int = 4) -> None:
    """Let some clocks pass."""
    for _ in range(clocks):
        await RisingEdge(dut.i_clk)
    await Timer(SETTLE_NS, unit="ns")


@cocotb.test()
async def test_the_loader_starts_with_the_core_running(dut: Dut):
    """Check the state after reset: running, nothing refused."""
    await start(dut)
    check_equal(int(dut.o_halt.value), 0)
    check_equal(status(dut), 0)
    check_equal(int(dut.o_wren_b.value), 0)


@cocotb.test()
async def test_halt_and_run_move_the_halt_line(dut: Dut):
    """Check that the halt command stops the core and run frees it."""
    await start(dut)
    await command(dut, OP_HALT)
    check_equal(int(dut.o_halt.value), 1)
    check_equal(status(dut) & HALTED, HALTED)
    await command(dut, OP_RUN)
    check_equal(int(dut.o_halt.value), 0)
    check_equal(status(dut) & HALTED, 0)


@cocotb.test()
async def test_a_write_reaches_the_flash_only_with_the_core_halted(
    dut: Dut,
):
    """Check that a write needs the core halted."""
    flash = await start(dut)
    await command(dut, OP_WRITE, 5, 0x11112222)
    await idle(dut)
    check_equal(flash.writes, [], "no write with the core running")
    check_equal(status(dut) & REFUSED, REFUSED, "the refusal is recorded")
    await command(dut, OP_HALT)
    check_equal(status(dut) & REFUSED, 0, "a halt clears the refusal")
    await command(dut, OP_WRITE, 5, 0x11112222)
    await idle(dut)
    check_equal(flash.writes, [(5, 0x11112222)])
    check_equal(flash.mem[5], 0x11112222)


@cocotb.test()
async def test_a_read_returns_the_word_and_its_address(dut: Dut):
    """Check that a read answers with the word and the index."""
    flash = await start(dut)
    await command(dut, OP_HALT)
    for addr in (0, 7, 200, 255):
        await command(dut, OP_READ, addr)
        check_equal(int(dut.o_rsp_data.value), flash.mem[addr], f"{addr}")
        check_equal(int(dut.o_rsp_addr.value), addr)


@cocotb.test()
async def test_a_read_is_refused_with_the_core_running(dut: Dut):
    """Check that a read does not touch port B of a running core."""
    await start(dut)
    await command(dut, OP_READ, 9)
    check_equal(status(dut) & REFUSED, REFUSED)
    check_equal(int(dut.o_rden_b.value), 0)


@cocotb.test()
async def test_the_summary_adds_data_and_address(dut: Dut):
    """Check the checksum and the count of the written words."""
    await start(dut)
    await command(dut, OP_HALT)
    words = [(3, 0xFFFFFFFF), (4, 0x00000002), (10, 0x12345678)]
    for addr, data in words:
        await command(dut, OP_WRITE, addr, data)
    await command(dut, OP_SUMMARY)
    expected = sum(addr + data for addr, data in words) & WORD_MASK
    check_equal(int(dut.o_rsp_data.value), expected)
    check_equal(int(dut.o_rsp_addr.value), len(words))
    await command(dut, OP_HALT)
    await command(dut, OP_SUMMARY)
    check_equal(int(dut.o_rsp_data.value), 0, "a halt clears the sum")
    check_equal(int(dut.o_rsp_addr.value), 0, "a halt clears the count")


@cocotb.test()
async def test_port_b_belongs_to_the_core_until_the_halt(dut: Dut):
    """Check who owns port B, the core or the loader."""
    await start(dut)
    dut.i_mem_address.value = 0x2A
    dut.i_mem_rden.value = 1
    await Timer(SETTLE_NS, unit="ns")
    check_equal(int(dut.o_address_b.value), 0x2A)
    check_equal(int(dut.o_rden_b.value), 1)
    await command(dut, OP_HALT)
    await command(dut, OP_WRITE, 0x10, 1)
    await idle(dut)
    check_equal(int(dut.o_address_b.value), 0x10, "the loader's index")
    check_equal(int(dut.o_rden_b.value), 0, "the core's read is off")
    await command(dut, OP_RUN)
    check_equal(int(dut.o_address_b.value), 0x2A)
    check_equal(int(dut.o_rden_b.value), 1)


@cocotb.test()
async def test_an_unknown_command_is_answered_and_ignored(dut: Dut):
    """Check that a command the loader does not know still completes."""
    flash = await start(dut)
    await command(dut, OP_HALT)
    await command(dut, 9, 3, 0xDEADBEEF)
    await idle(dut)
    check_equal(flash.writes, [])
    check_true(int(dut.o_halt.value) == 1, "the halt stays")


@cocotb.test()
async def test_reset_forgets_the_halt(dut: Dut):
    """Check that a reset releases the core and clears the status."""
    await start(dut)
    await command(dut, OP_HALT)
    dut.i_rst.value = 1
    await idle(dut, 2)
    dut.i_rst.value = 0
    await idle(dut, 4)
    check_equal(int(dut.o_halt.value), 0)
    check_equal(status(dut), 0)
