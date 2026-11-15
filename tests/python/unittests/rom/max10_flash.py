"""max10_flash.

The bus controller of the MAX 10 user flash against the behavioural
model of the on-chip flash megafunction: word read, word program and
sector erase through the CSR, the busy, done and error flags, the write
enable guard and the interrupt.

"""

import cocotb
from cocotb.triggers import Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut
from tests.python.unittests.regbus import (
    BUSY,
    DONE,
    ERR,
    clear_flags,
    reg_read,
    reg_write,
    start,
    wait_done,
)

STATUS, CONTROL, ADDRESS, DATA, SECTOR, COMMAND, IP_STATUS = range(7)
READ, WRITE, ERASE, ENABLE, DISABLE = 1, 2, 3, 4, 5
WEN = 8
ERASED = 0xFFFFFFFF


async def command(dut: Dut, code: int) -> int:
    """Issue a command and return the status when it ends."""
    await reg_write(dut, COMMAND, code)
    return await wait_done(dut)


async def read_word(dut: Dut, addr: int) -> tuple[int, int]:
    """Read a word and return it with the status."""
    await reg_write(dut, ADDRESS, addr)
    status = await command(dut, READ)
    return await reg_read(dut, DATA), status


async def write_word(dut: Dut, addr: int, value: int) -> int:
    """Program a word and return the status."""
    await reg_write(dut, ADDRESS, addr)
    await reg_write(dut, DATA, value)
    return await command(dut, WRITE)


async def erase_sector(dut: Dut, sector: int) -> int:
    """Erase a sector and return the status."""
    await reg_write(dut, SECTOR, sector)
    return await command(dut, ERASE)


def generic(dut: Dut, name: str) -> int:
    """Return an integer generic of the design."""
    return int(getattr(dut, name).value)


@cocotb.test()
async def test_reset_state(dut: Dut):
    """Check the registers after the reset."""
    await start(dut)
    check_equal(await reg_read(dut, STATUS), 0, "status")
    check_equal(await reg_read(dut, CONTROL), 0, "control")
    check_equal(int(dut.o_irq.value), 0, "irq")
    check_equal(await reg_read(dut, 7), 0, "reserved reads zero")


@cocotb.test()
async def test_read_of_an_erased_word(dut: Dut):
    """Check that a read returns ones and ends with no error."""
    await start(dut)
    word, status = await read_word(dut, 3)
    check_equal(word, ERASED, "erased word")
    check_equal(status, DONE, "done and no error")
    ip = await reg_read(dut, IP_STATUS)
    check_true(ip & 4, "the megafunction reports the read as passed")


@cocotb.test()
async def test_read_outside_the_flash_is_an_error(dut: Dut):
    """Check that the failed read of the megafunction sets the error."""
    await start(dut)
    last = 5 * generic(dut, "sector_words")
    word, status = await read_word(dut, last)
    check_equal(word, ERASED, "ones")
    check_equal(status, DONE | ERR, "done with error")


@cocotb.test()
async def test_write_is_refused_without_enable(dut: Dut):
    """Check that a write with the lock on does not reach the flash."""
    await start(dut)
    status = await write_word(dut, 2, 0x12345678)
    check_equal(status, ERR, "refused: error, no done")
    await clear_flags(dut)
    word, _ = await read_word(dut, 2)
    check_equal(word, ERASED, "the flash is unchanged")


@cocotb.test()
async def test_enable_write_read_back_and_disable(dut: Dut):
    """Check program and read of a word, and the lock after disable."""
    await start(dut)
    status = await command(dut, ENABLE)
    check_equal(status, DONE | WEN, "enabled")
    await clear_flags(dut)
    status = await write_word(dut, 5, 0xA5A5F0F0)
    check_equal(status, DONE | WEN, "programmed")
    await clear_flags(dut)
    word, _ = await read_word(dut, 5)
    check_equal(word, 0xA5A5F0F0, "read back")
    await clear_flags(dut)
    status = await command(dut, DISABLE)
    check_equal(status & WEN, 0, "disabled")
    await clear_flags(dut)
    status = await write_word(dut, 6, 0)
    check_equal(status, ERR, "refused again")


@cocotb.test()
async def test_program_only_clears_bits(dut: Dut):
    """Check that a second program on a word is the AND of the two."""
    await start(dut)
    await command(dut, ENABLE)
    await clear_flags(dut)
    await write_word(dut, 9, 0xF0F0F0F0)
    await clear_flags(dut)
    await write_word(dut, 9, 0x0FF00FF0)
    await clear_flags(dut)
    word, _ = await read_word(dut, 9)
    check_equal(word, 0x00F000F0, "AND of the two words")


@cocotb.test()
async def test_erase_a_sector(dut: Dut):
    """Check that an erase restores its sector and no other."""
    await start(dut)
    size = generic(dut, "sector_words")
    await command(dut, ENABLE)
    await clear_flags(dut)
    for addr in (1, size + 1):
        await write_word(dut, addr, 0)
        await clear_flags(dut)
    await command(dut, ENABLE)
    await clear_flags(dut)
    status = await erase_sector(dut, 1)
    check_equal(status & ~WEN, DONE, "erase done, no error")
    check_equal(status & WEN, 0, "the erase locks the flash again")
    await clear_flags(dut)
    word, _ = await read_word(dut, 1)
    check_equal(word, ERASED, "sector 1 erased")
    await clear_flags(dut)
    word, _ = await read_word(dut, size + 1)
    check_equal(word, 0, "sector 2 intact")
    ip = await reg_read(dut, IP_STATUS)
    check_true(ip & 4, "the erase leaves the read flag up")


@cocotb.test()
async def test_erase_is_refused(dut: Dut):
    """Check the refusals: no enable, bad sector or not allowed."""
    await start(dut)
    status = await erase_sector(dut, 1)
    check_equal(status, ERR, "locked")
    await clear_flags(dut)
    await command(dut, ENABLE)
    await clear_flags(dut)
    for sector in (0, 3, 4, 5, 6, 7):
        status = await erase_sector(dut, sector)
        check_equal(status & ERR, ERR, f"sector {sector} refused")
        check_equal(status & DONE, 0, f"sector {sector} not done")
        await clear_flags(dut)


@cocotb.test()
async def test_command_while_busy_is_refused(dut: Dut):
    """Check that a command during an operation raises the error."""
    await start(dut)
    await command(dut, ENABLE)
    await clear_flags(dut)
    await reg_write(dut, ADDRESS, 0)
    await reg_write(dut, DATA, 0)
    await reg_write(dut, COMMAND, WRITE)
    status = await reg_read(dut, STATUS)
    check_equal(status & BUSY, BUSY, "busy")
    await reg_write(dut, COMMAND, READ)
    status = await wait_done(dut)
    check_equal(status & (DONE | ERR), DONE | ERR, "ended, second refused")
    await clear_flags(dut)
    word, _ = await read_word(dut, 0)
    check_equal(word, 0, "only the first command ran")


@cocotb.test()
async def test_interrupt(dut: Dut):
    """Check that the interrupt follows done and its enable."""
    await start(dut)
    await reg_write(dut, ADDRESS, 0)
    await command(dut, READ)
    check_equal(int(dut.o_irq.value), 0, "masked")
    await reg_write(dut, CONTROL, 1)
    await Timer(1, unit="ns")
    check_equal(int(dut.o_irq.value), 1, "raised by done")
    await clear_flags(dut)
    await Timer(1, unit="ns")
    check_equal(int(dut.o_irq.value), 0, "cleared with the flag")
