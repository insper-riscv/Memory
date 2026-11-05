"""flash_dual.

The FLASH model with both ports: the read chip on port A and the command
port on port B, over one two-port storage.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

WREN, ERASE, PROGRAM = 1, 2, 3
SIZE = 16384
SECTOR = 4096
PAGE = 256
BASE = 0x20000000
ERASED = 0xFFFFFFFF
MIN_READS = 20


# The storage keeps its content from one test to the next, so each
# test uses sectors the earlier ones left alone (sector 3 is erased
# only by the test that reads it while it is erased).
PATTERN = [0xC0DE0000 + i for i in range(PAGE // 4)]
PATTERN_AT = 2 * SECTOR + PAGE


async def start(dut: Dut):
    """Start the clock, load the storage and reset the DUT."""
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    dut.i_rst.value = 1
    for name in ("i_rden", "i_line", "i_advance", "i_cmd_valid", "i_buf_we"):
        getattr(dut, name).value = 0
    dut.i_addr.value = 0
    dut.i_cmd_op.value = 0
    dut.i_cmd_addr.value = 0
    dut.i_buf_widx.value = 0
    dut.i_buf_wdata.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await RisingEdge(dut.i_clk)


async def read_line(dut: Dut, addr: int, timeout: int = 200):
    """Read a line through port A and return its four words."""
    dut.i_addr.value = addr
    dut.i_line.value = 1
    dut.i_rden.value = 1
    for _ in range(timeout):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_ready.value) == 1:
            x = int(dut.o_rdata_x.value)
            words = [int(dut.o_rdata.value)]
            words += [(x >> (32 * i)) & 0xFFFFFFFF for i in range(3)]
            dut.i_rden.value = 0
            dut.i_advance.value = 1
            await RisingEdge(dut.i_clk)
            dut.i_advance.value = 0
            await Timer(1, unit="ns")
            return words
    raise AssertionError(f"no line for {addr:#x}")


async def command(dut: Dut, op: int, addr: int = 0):
    """Send one command for one clock."""
    dut.i_cmd_valid.value = 1
    dut.i_cmd_op.value = op
    dut.i_cmd_addr.value = addr
    await RisingEdge(dut.i_clk)
    dut.i_cmd_valid.value = 0
    await Timer(1, unit="ns")


async def wait_idle(dut: Dut, limit: int = 20000):
    """Wait for busy to fall."""
    for _ in range(limit):
        if int(dut.o_busy.value) == 0:
            return
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
    raise AssertionError("busy never fell")


async def fill_buffer(dut: Dut, words: list[int]):
    """Write the words of a page into the buffer."""
    for index in range(PAGE // 4):
        dut.i_buf_we.value = 1
        dut.i_buf_widx.value = index
        dut.i_buf_wdata.value = words[index] if index < len(words) else ERASED
        await RisingEdge(dut.i_clk)
    dut.i_buf_we.value = 0
    await Timer(1, unit="ns")


async def seed(dut: Dut):
    """Erase the third sector and program a known page into it."""
    await command(dut, WREN)
    await command(dut, ERASE, BASE + 2 * SECTOR)
    await wait_idle(dut)
    await fill_buffer(dut, PATTERN)
    await command(dut, WREN)
    await command(dut, PROGRAM, BASE + PATTERN_AT)
    await wait_idle(dut)


@cocotb.test()
async def test_port_a_reads_the_loaded_content(dut: Dut):
    """Check that port A reads what the storage holds."""
    await start(dut)
    check_equal(await read_line(dut, BASE + 0x40), [0] * 4)
    await seed(dut)
    check_equal(await read_line(dut, BASE + PATTERN_AT + 0x10), PATTERN[4:8])
    check_equal(await read_line(dut, BASE + PATTERN_AT - 16), [ERASED] * 4)


@cocotb.test()
async def test_port_a_sees_an_erase_and_a_program(dut: Dut):
    """Check that reads after a command see the new content."""
    await start(dut)
    await command(dut, WREN)
    await command(dut, ERASE, BASE + SECTOR)
    await wait_idle(dut)
    check_equal(await read_line(dut, BASE + SECTOR + 0x10), [ERASED] * 4)
    data = [0x11111111, 0x22222222, 0x33333333, 0x44444444]
    await fill_buffer(dut, data)
    await command(dut, WREN)
    await command(dut, PROGRAM, BASE + SECTOR + PAGE)
    await wait_idle(dut)
    check_equal(await read_line(dut, BASE + SECTOR + PAGE), data)
    check_equal(await read_line(dut, BASE + SECTOR + PAGE + 16), [ERASED] * 4)
    # the sector before is untouched
    check_equal(await read_line(dut, BASE + SECTOR - 16), [0] * 4)


@cocotb.test()
async def test_reads_go_on_while_the_other_port_erases(dut: Dut):
    """Check that port A reads another sector during an erase."""
    await start(dut)
    await seed(dut)
    await command(dut, WREN)
    await command(dut, ERASE, BASE)
    reads = 0
    while int(dut.o_busy.value) == 1:
        words = await read_line(dut, BASE + PATTERN_AT + 0x20)
        check_equal(words, PATTERN[8:12])
        reads += 1
    check_true(reads >= MIN_READS, reads)
    check_equal(await read_line(dut, BASE), [ERASED] * 4)


@cocotb.test()
async def test_a_read_in_the_erased_sector_never_mixes_a_word(dut: Dut):
    """Check that a word read during an erase is old or erased."""
    await start(dut)
    await command(dut, WREN)
    await command(dut, ERASE, BASE + 3 * SECTOR)
    seen_old = seen_new = 0
    while int(dut.o_busy.value) == 1:
        words = await read_line(dut, BASE + 4 * SECTOR - 16)
        for word in words:
            check_true(word in (0, ERASED), hex(word))
            seen_old += word == 0
            seen_new += word == ERASED
    check_true(seen_old > 0 and seen_new > 0, (seen_old, seen_new))


@cocotb.test()
async def test_the_pulse_marks_the_region_of_the_program(dut: Dut):
    """Check the invalidation region of a program on the system."""
    await start(dut)
    await fill_buffer(dut, [0])
    await command(dut, WREN)
    await command(dut, PROGRAM, BASE + 3 * PAGE)
    first = last = None
    for _ in range(2000):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_inval_valid.value) == 1:
            first = int(dut.o_inval_first.value)
            last = int(dut.o_inval_last.value)
            check_equal(int(dut.o_busy.value), 0)
            break
    check_equal((first, last), (BASE + 3 * PAGE, BASE + 4 * PAGE - 1))
