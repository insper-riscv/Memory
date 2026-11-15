"""epcs_ctrl.

The user access controller of the serial configuration flash against the
SPI chip model: identification, status, read and fast read, page program
and sector erase, and the guard that keeps the configuration bitstream
(everything below user_base) from ever being programmed or erased. The
chip model flags a violation when the controller does what a real chip
would only ignore, so every test also checks that flag.

"""

import cocotb
from cocotb.triggers import Timer

from tests.python.unittests.checks import Prng, check_equal, check_true
from tests.python.unittests.dut import Dut
from tests.python.unittests.regbus import (
    DONE,
    ERR,
    clear_flags,
    reg_read,
    reg_write,
    start,
    wait_done,
)

(
    STATUS,
    CONTROL,
    ADDRESS,
    LENGTH,
    COMMAND,
    ID,
    USER_BASE,
    SIZE,
    BUFIDX,
    BUFDATA,
) = range(10)
RDID, RDSR, WREN, READ, PP, SE = 1, 2, 3, 4, 5, 6
WEL = 8
SECTOR = 65536
USER = 262144
CHIP_SIZE = 524288


def pattern(addr: int) -> int:
    """Return the initial byte of the chip model at an address."""
    return (addr * 37 + addr // 256 * 11 + 5) % 251


async def command(dut: Dut, code: int, addr: int = 0, length: int = 0) -> int:
    """Issue a command and return the status when it ends."""
    await reg_write(dut, ADDRESS, addr)
    await reg_write(dut, LENGTH, length)
    await reg_write(dut, COMMAND, code)
    return await wait_done(dut)


async def read_bytes(
    dut: Dut, addr: int, length: int, fast: bool = False
) -> bytes:
    """Read bytes of the chip through the page buffer."""
    await reg_write(dut, CONTROL, 2 if fast else 0)
    status = await command(dut, READ, addr, length)
    check_equal(status & ERR, 0, f"read {addr:#x}+{length}")
    await clear_flags(dut)
    await reg_write(dut, BUFIDX, 0)
    await Timer(40, unit="ns")
    out = bytearray()
    for _ in range((length + 3) // 4):
        word = await reg_read(dut, BUFDATA)
        out += word.to_bytes(4, "little")
        await reg_write(dut, BUFIDX, len(out) // 4)
        await Timer(40, unit="ns")
    return bytes(out[:length])


async def load_buffer(dut: Dut, data: bytes):
    """Fill the page buffer, padding to a whole word."""
    padded = data + b"\xff" * (-len(data) % 4)
    await reg_write(dut, BUFIDX, 0)
    for i in range(0, len(padded), 4):
        await reg_write(dut, BUFDATA, int.from_bytes(padded[i:][:4], "little"))
        await Timer(40, unit="ns")


async def enable_write(dut: Dut) -> int:
    """Run WREN and return the status."""
    status = await command(dut, WREN)
    await clear_flags(dut)
    return status


def check_clean(dut: Dut, message: str) -> None:
    """Check that the chip model saw no violation."""
    check_equal(int(dut.o_violation.value), 0, f"violation: {message}")


@cocotb.test()
async def test_registers_after_reset(dut: Dut):
    """Check the constant registers and the status after the reset."""
    await start(dut)
    check_equal(await reg_read(dut, STATUS), 0, "status")
    check_equal(await reg_read(dut, USER_BASE), USER, "user base")
    check_equal(await reg_read(dut, SIZE), CHIP_SIZE, "size")
    check_clean(dut, "reset")


@cocotb.test()
async def test_read_id_and_status(dut: Dut):
    """Check RDID and RDSR against the chip model."""
    await start(dut)
    status = await command(dut, RDID)
    check_equal(status, DONE, "rdid done")
    check_equal(await reg_read(dut, ID), 0x202017, "id")
    await clear_flags(dut)
    status = await command(dut, RDSR)
    check_equal(status & 0xFF1F, DONE, "rdsr done, wip and wel low")
    check_equal((status >> 8) & 0xFF, 0, "status register")
    check_clean(dut, "id")


@cocotb.test()
async def test_read_matches_the_pattern(dut: Dut):
    """Check READ and FAST_READ in the bitstream and user regions."""
    await start(dut)
    for addr, length, fast in (
        (0, 16, False),
        (0x1234, 5, False),
        (USER - 8, 16, True),
        (USER + 0x100, 256, False),
        (CHIP_SIZE - 256, 256, True),
    ):
        got = await read_bytes(dut, addr, length, fast)
        want = bytes(pattern(addr + i) for i in range(length))
        check_equal(got, want, f"read {addr:#x}+{length} fast={fast}")
    check_clean(dut, "reads")


@cocotb.test()
async def test_read_out_of_range_is_refused(dut: Dut):
    """Check that a bad read length or past the chip is an error."""
    await start(dut)
    for addr, length in ((0, 0), (0, 257), (CHIP_SIZE - 4, 8)):
        status = await command(dut, READ, addr, length)
        check_equal(status, ERR, f"read {addr:#x}+{length}")
        await clear_flags(dut)
    check_clean(dut, "refused reads")


@cocotb.test()
async def test_erase_and_program_need_write_enable(dut: Dut):
    """Check that PP and SE without WREN make no frame at all."""
    await start(dut)
    before = await read_bytes(dut, USER, 32)
    await load_buffer(dut, bytes(range(32)))
    status = await command(dut, PP, USER, 32)
    check_equal(status, ERR, "PP refused")
    await clear_flags(dut)
    status = await command(dut, SE, USER, 0)
    check_equal(status, ERR, "SE refused")
    await clear_flags(dut)
    check_equal(await read_bytes(dut, USER, 32), before, "unchanged")
    check_clean(dut, "no WREN")


@cocotb.test()
async def test_sector_erase(dut: Dut):
    """Check that SE with WREN erases a sector and locks again."""
    await start(dut)
    status = await enable_write(dut)
    check_equal(status & WEL, WEL, "write enabled after WREN")
    status = await command(dut, SE, USER + 0x1234, 0)
    check_equal(status, DONE, "SE done, lock back on")
    check_equal(int(dut.o_chip_wel.value), 0, "chip latch low")
    check_equal(int(dut.o_chip_wip.value), 0, "chip idle")
    await clear_flags(dut)
    first = USER
    check_equal(await read_bytes(dut, first, 8), b"\xff" * 8, "start erased")
    check_equal(
        await read_bytes(dut, first + SECTOR - 8, 8),
        b"\xff" * 8,
        "end erased",
    )
    after = first + SECTOR
    want = bytes(pattern(after + i) for i in range(8))
    check_equal(await read_bytes(dut, after, 8), want, "next sector intact")
    status = await command(dut, SE, USER, 0)
    check_equal(status, ERR, "the erase used the write enable")
    check_clean(dut, "erase")


@cocotb.test()
async def test_page_program_is_an_and(dut: Dut):
    """Check PP: the page lands, and a second PP ANDs into it."""
    await start(dut)
    await enable_write(dut)
    await command(dut, SE, USER, 0)
    await clear_flags(dut)
    prng = Prng(0xEC5)
    data = bytes(prng.getrandbits(8) for _ in range(100))
    await enable_write(dut)
    await load_buffer(dut, data)
    status = await command(dut, PP, USER + 0x40, 100)
    check_equal(status, DONE, "PP done")
    await clear_flags(dut)
    check_equal(await read_bytes(dut, USER + 0x40, 100), data, "page")
    check_equal(await read_bytes(dut, USER + 0x3F, 1), b"\xff", "before")
    check_equal(await read_bytes(dut, USER + 0xA4, 1), b"\xff", "after")
    second = bytes(prng.getrandbits(8) for _ in range(100))
    await enable_write(dut)
    await load_buffer(dut, second)
    await command(dut, PP, USER + 0x40, 100)
    await clear_flags(dut)
    want = bytes(a & b for a, b in zip(data, second, strict=True))
    check_equal(await read_bytes(dut, USER + 0x40, 100), want, "AND")
    check_clean(dut, "program")


@cocotb.test()
async def test_full_page_program(dut: Dut):
    """Check a program of the whole 256-byte page."""
    await start(dut)
    await enable_write(dut)
    await command(dut, SE, USER + SECTOR, 0)
    await clear_flags(dut)
    data = bytes((i * 7 + 3) & 0xFF for i in range(256))
    await enable_write(dut)
    await load_buffer(dut, data)
    status = await command(dut, PP, USER + SECTOR + 256, 256)
    check_equal(status, DONE, "PP done")
    await clear_flags(dut)
    got = await read_bytes(dut, USER + SECTOR + 256, 256, True)
    check_equal(got, data, "page")
    check_clean(dut, "full page")


@cocotb.test()
async def test_bitstream_region_is_protected(dut: Dut):
    """Check that PP and SE below user_base never reach the chip."""
    await start(dut)
    cases = ((PP, 0, 16), (PP, USER - 16, 16), (SE, 0, 0), (SE, USER - 1, 0))
    for code, addr, length in cases:
        await enable_write(dut)
        await load_buffer(dut, bytes(16))
        status = await command(dut, code, addr, length)
        check_equal(status, ERR, f"cmd {code} at {addr:#x} refused")
        check_equal(status & WEL, 0, "the refusal drops the write enable")
        await clear_flags(dut)
    for addr in (0, 0x2000, USER - 16):
        want = bytes(pattern(addr + i) for i in range(16))
        check_equal(await read_bytes(dut, addr, 16), want, f"{addr:#x} intact")
    check_clean(dut, "bitstream guard")


@cocotb.test()
async def test_program_that_crosses_a_page_is_refused(dut: Dut):
    """Check the page bounds of PP and the end of the chip."""
    await start(dut)
    cases = (
        (USER + 250, 10),
        (USER, 0),
        (USER, 257),
        (CHIP_SIZE - 128, 256),
        (CHIP_SIZE, 4),
    )
    for addr, length in cases:
        await enable_write(dut)
        status = await command(dut, PP, addr, length)
        check_equal(status, ERR, f"PP {addr:#x}+{length} refused")
        await clear_flags(dut)
    check_clean(dut, "page bounds")


@cocotb.test()
async def test_command_while_busy_is_an_error(dut: Dut):
    """Check that a command issued during a frame raises the error."""
    await start(dut)
    await reg_write(dut, ADDRESS, 0)
    await reg_write(dut, LENGTH, 64)
    await reg_write(dut, COMMAND, READ)
    await reg_write(dut, COMMAND, RDID)
    status = await wait_done(dut)
    check_equal(status & (DONE | ERR), DONE | ERR, "first ran, second refused")
    await clear_flags(dut)
    check_clean(dut, "busy command")


@cocotb.test()
async def test_interrupt(dut: Dut):
    """Check that the interrupt follows done and its enable."""
    await start(dut)
    await command(dut, RDSR)
    check_equal(int(dut.o_irq.value), 0, "masked")
    await reg_write(dut, CONTROL, 1)
    await Timer(1, unit="ns")
    check_equal(int(dut.o_irq.value), 1, "raised")
    await clear_flags(dut)
    await Timer(1, unit="ns")
    check_true(int(dut.o_irq.value) == 0, "cleared")
