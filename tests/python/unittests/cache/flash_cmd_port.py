"""flash_cmd_port.

The command port of the FLASH chip model, against a storage model with a
registered read and a page buffer.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

WREN, ERASE, PROGRAM, PROTECT, UNPROTECT = 1, 2, 3, 4, 5
SIZE = 16384
SECTOR = 4096
PAGE = 256
ERASE_LATENCY = 40
PROGRAM_LATENCY = 10
BASE = 0x20000000
ERASED = 0xFFFFFFFF
ERASE_CLOCKS = ERASE_LATENCY + 1 + 3 * (SECTOR // 4)
PROGRAM_CLOCKS = PROGRAM_LATENCY + 1 + 3 * (PAGE // 4)


class Models:
    """The storage and the page buffer the entity is wired to."""

    def __init__(self) -> None:
        """Start with the storage and the buffer holding known data."""
        self.mem = [self.initial(i) for i in range(SIZE // 4)]
        self.buf = [ERASED] * (PAGE // 4)
        self.writes: list[tuple[int, int]] = []
        self.pulses: list[tuple[int, int]] = []

    @staticmethod
    def initial(index: int) -> int:
        """Return the content of the storage before any command."""
        return (0xA5A50000 + index * 0x10001) & 0xFFFFFFFF


async def run_models(dut: Dut, models: Models):
    """Sample the entity at every edge, as the memories do."""
    while True:
        await RisingEdge(dut.i_clk)
        addr = int(dut.o_mem_addr.value) >> 2
        if int(dut.o_mem_we.value) == 1:
            models.mem[addr] = int(dut.o_mem_wdata.value)
            models.writes.append((addr * 4, models.mem[addr]))
        dut.i_mem_data.value = models.mem[addr]
        dut.i_buf_data.value = models.buf[int(dut.o_buf_idx.value)]
        if int(dut.o_inval_valid.value) == 1:
            models.pulses.append(
                (int(dut.o_inval_first.value), int(dut.o_inval_last.value))
            )


async def start(dut: Dut) -> Models:
    """Start the clock, the models and reset the DUT."""
    models = Models()
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    dut.i_rst.value = 1
    dut.i_cmd_valid.value = 0
    dut.i_cmd_op.value = 0
    dut.i_cmd_addr.value = 0
    dut.i_mem_data.value = 0
    dut.i_buf_data.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    cocotb.start_soon(run_models(dut, models))
    await RisingEdge(dut.i_clk)
    return models


async def command(dut: Dut, op: int, addr: int = 0):
    """Send one command for one clock and look at the state after it."""
    dut.i_cmd_valid.value = 1
    dut.i_cmd_op.value = op
    dut.i_cmd_addr.value = addr
    await RisingEdge(dut.i_clk)
    dut.i_cmd_valid.value = 0
    await Timer(1, unit="ns")


async def finish(dut: Dut, limit: int = 10000):
    """Wait for busy to fall and return how many clocks it stayed up."""
    clocks = 0
    while int(dut.o_busy.value) == 1:
        clocks += 1
        check_true(clocks <= limit, "busy never fell")
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
    return clocks


async def erase(dut: Dut, addr: int):
    """Arm the latch, erase a sector and wait."""
    await command(dut, WREN)
    await command(dut, ERASE, addr)
    return await finish(dut)


async def program(dut: Dut, models: Models, addr: int, words: list[int]):
    """Fill the page buffer, arm the latch, program a page and wait."""
    models.buf = list(words) + [ERASED] * (PAGE // 4 - len(words))
    await command(dut, WREN)
    await command(dut, PROGRAM, addr)
    return await finish(dut)


def sector_words(mem: list[int], number: int):
    """Return the words of one sector of a storage image."""
    first = number * SECTOR // 4
    last = first + SECTOR // 4
    return mem[first:last]


@cocotb.test()
async def test_erase_sets_the_sector_to_ones(dut: Dut):
    """Check that erase sets one whole sector to ones, no more."""
    models = await start(dut)
    before = list(models.mem)
    await erase(dut, BASE + SECTOR + 0x123)
    check_equal(sector_words(models.mem, 1), [ERASED] * (SECTOR // 4))
    for number in (0, 2):
        check_equal(
            sector_words(models.mem, number), sector_words(before, number)
        )


@cocotb.test()
async def test_program_ands_bit_by_bit(dut: Dut):
    """Check that a program only takes bits from one to zero."""
    models = await start(dut)
    before = list(models.mem)
    data = [0x0F0F0F0F, 0xFFFF0000, 0x12345678]
    await program(dut, models, PAGE * 3, data)
    for i, value in enumerate(data):
        want = before[3 * PAGE // 4 + i] & value
        check_equal(models.mem[3 * PAGE // 4 + i], want, i)
    # the words past the data are written with ones and stay the same
    check_equal(models.mem[3 * PAGE // 4 + 3], before[3 * PAGE // 4 + 3])
    check_equal(models.mem[3 * PAGE // 4 - 1], before[3 * PAGE // 4 - 1])
    check_equal(models.mem[4 * PAGE // 4], before[4 * PAGE // 4])


@cocotb.test()
async def test_program_cannot_set_a_bit_without_erase(dut: Dut):
    """Check that a second program on the same page ANDs again."""
    models = await start(dut)
    await erase(dut, 0)
    await program(dut, models, 0, [0x00FF00FF, 0xF0F0F0F0])
    await program(dut, models, 0, [0xFFFFFF00, 0x0F0F0F0F])
    check_equal(models.mem[0], 0x00FF0000)
    check_equal(models.mem[1], 0x00000000)
    await erase(dut, 0)
    await program(dut, models, 0, [0xFFFFFF00])
    check_equal(models.mem[0], 0xFFFFFF00)


@cocotb.test()
async def test_a_command_without_the_latch_is_ignored(dut: Dut):
    """Check that erase and program without the latch change nothing."""
    models = await start(dut)
    before = list(models.mem)
    models.buf = [0] * (PAGE // 4)
    await command(dut, ERASE, 0)
    check_equal(int(dut.o_busy.value), 0)
    await command(dut, PROGRAM, 0)
    check_equal(int(dut.o_busy.value), 0)
    for _ in range(20):
        await RisingEdge(dut.i_clk)
    check_equal(models.mem, before)
    check_equal(models.writes, [])
    check_equal(models.pulses, [])
    check_equal(int(dut.o_refused.value), 0)


@cocotb.test()
async def test_the_latch_falls_with_the_operation(dut: Dut):
    """Check that WREN arms the latch and one operation spends it."""
    models = await start(dut)
    check_equal(int(dut.o_wel.value), 0)
    await command(dut, WREN)
    check_equal(int(dut.o_wel.value), 1)
    await command(dut, ERASE, 0)
    check_equal(int(dut.o_busy.value), 1)
    check_equal(int(dut.o_wel.value), 1)
    await finish(dut)
    check_equal(int(dut.o_wel.value), 0)
    before = list(models.mem)
    await command(dut, ERASE, SECTOR)
    check_equal(int(dut.o_busy.value), 0)
    check_equal(models.mem, before)


@cocotb.test()
async def test_a_protected_sector_refuses(dut: Dut):
    """Check that a protected sector refuses erase and program."""
    models = await start(dut)
    before = list(models.mem)
    await command(dut, PROTECT, SECTOR + 0x40)
    models.buf = [0] * (PAGE // 4)
    for op in (ERASE, PROGRAM):
        await command(dut, WREN)
        await command(dut, op, SECTOR + 0x80)
        check_equal(int(dut.o_busy.value), 0, op)
        check_equal(int(dut.o_refused.value), 1, op)
        check_equal(int(dut.o_wel.value), 0, op)
    check_equal(models.mem, before)
    check_equal(models.pulses, [])
    # the other sectors are not protected
    await erase(dut, 0)
    check_equal(int(dut.o_refused.value), 0)
    # unprotecting lets the sector be erased
    await command(dut, UNPROTECT, SECTOR)
    await erase(dut, SECTOR)
    check_equal(sector_words(models.mem, 1), [ERASED] * (SECTOR // 4))


@cocotb.test()
async def test_protect_works_without_the_latch(dut: Dut):
    """Check that protecting needs no latch and takes effect at once."""
    await start(dut)
    await command(dut, PROTECT, 0)
    await command(dut, WREN)
    await command(dut, ERASE, 0)
    check_equal(int(dut.o_refused.value), 1)
    await command(dut, WREN)
    check_equal(int(dut.o_refused.value), 0)


@cocotb.test()
async def test_an_address_outside_the_window_is_refused(dut: Dut):
    """Check that an erase past the end of the chip is refused."""
    models = await start(dut)
    before = list(models.mem)
    await command(dut, WREN)
    await command(dut, ERASE, BASE + SIZE)
    check_equal(int(dut.o_refused.value), 1)
    check_equal(int(dut.o_busy.value), 0)
    check_equal(models.mem, before)
    # the last sector of the window is inside
    await erase(dut, BASE + SIZE - 4)
    check_equal(
        sector_words(models.mem, SIZE // SECTOR - 1), [ERASED] * (SECTOR // 4)
    )


@cocotb.test()
async def test_busy_lasts_the_configured_latency(dut: Dut):
    """Check the clocks busy stays up for an erase and a program."""
    models = await start(dut)
    check_equal(await erase(dut, 0), ERASE_CLOCKS)
    clocks = await program(dut, models, 0, [0x1])
    check_equal(clocks, PROGRAM_CLOCKS)
    check_equal(len(models.writes), SECTOR // 4 + PAGE // 4)


@cocotb.test()
async def test_commands_are_ignored_while_busy(dut: Dut):
    """Check that nothing is accepted while an operation runs."""
    models = await start(dut)
    await command(dut, WREN)
    await command(dut, ERASE, 0)
    for op, addr in ((WREN, 0), (ERASE, SECTOR), (PROGRAM, 0), (PROTECT, 0)):
        await command(dut, op, addr)
        check_equal(int(dut.o_busy.value), 1)
    clocks = await finish(dut)
    check_true(clocks <= ERASE_CLOCKS, clocks)
    check_equal(sector_words(models.mem, 0), [ERASED] * (SECTOR // 4))
    # no second operation started, and the protect did not take effect
    check_equal(len(models.writes), SECTOR // 4)
    await erase(dut, 0)


@cocotb.test()
async def test_the_invalidation_pulse_ends_each_operation(dut: Dut):
    """Check the region and the instant of the invalidation pulse."""
    models = await start(dut)
    pulses = 0

    async def watch():
        nonlocal pulses
        while True:
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            if int(dut.o_inval_valid.value) == 1:
                pulses += 1
                check_equal(int(dut.o_busy.value), 0, "pulse with busy up")

    cocotb.start_soon(watch())
    await erase(dut, SECTOR * 2 + 8)
    await RisingEdge(dut.i_clk)
    check_equal(models.pulses, [(BASE + 2 * SECTOR, BASE + 3 * SECTOR - 1)])
    await program(dut, models, PAGE * 5 + 4, [0])
    await RisingEdge(dut.i_clk)
    check_equal(models.pulses[1], (BASE + 5 * PAGE, BASE + 6 * PAGE - 1))
    for _ in range(5):
        await RisingEdge(dut.i_clk)
    check_equal(pulses, 2)


@cocotb.test()
async def test_the_pulse_comes_after_the_last_write(dut: Dut):
    """Check that every write is done when the pulse comes."""
    models = await start(dut)
    seen: list[int] = []

    async def watch():
        while True:
            await RisingEdge(dut.i_clk)
            if int(dut.o_inval_valid.value) == 1:
                seen.append(len(models.writes))

    cocotb.start_soon(watch())
    await erase(dut, 0)
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    check_equal(len(models.writes), SECTOR // 4)
    check_equal(seen, [SECTOR // 4])


@cocotb.test()
async def test_reset_clears_the_state(dut: Dut):
    """Check that reset drops the latch and the protection."""
    models = await start(dut)
    await command(dut, PROTECT, 0)
    await command(dut, WREN)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await Timer(1, unit="ns")
    check_equal(int(dut.o_wel.value), 0)
    check_equal(int(dut.o_busy.value), 0)
    await erase(dut, 0)
    check_equal(sector_words(models.mem, 0), [ERASED] * (SECTOR // 4))
