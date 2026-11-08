"""nor_flash_ctrl.

The parallel NOR FLASH controller against the chip model: the contract
of the flash chip (word and line reads), the K4 commands (erase a
sector, program a page, protect) and the cycle counts of the timing
generics. The chip model fails the simulation when the controller breaks
a chip timing, so a test that finishes also proved the timing.

"""

import math

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import Prng, check_equal
from tests.python.unittests.dut import Dut

WREN, ERASE, PROGRAM, PROTECT, UNPROTECT = 1, 2, 3, 4, 5
SIZE = 65536
SECTOR = 4096
PAGE = 64
BASE = 0x20000000
MASK32 = 0xFFFFFFFF


def pattern(addr: int) -> int:
    """Return the initial byte of the chip model at a byte address."""
    return ((((addr * 0x9E3779B1) & MASK32) ^ 0x5A5A1234) >> 24) & 0xFF


class Chip:
    """The reference content of the chip."""

    def __init__(self) -> None:
        """Start with the pattern the model starts with."""
        self.mem = bytearray(pattern(a) for a in range(SIZE))

    def erase(self, addr: int) -> None:
        """Set the sector of the address to ones."""
        first = addr & (SIZE - 1) & ~(SECTOR - 1)
        end = first + SECTOR
        self.mem[first:end] = b"\xff" * SECTOR

    def program(self, addr: int, words: list[int]) -> None:
        """AND the words of the buffer into the page of the address."""
        first = addr & (SIZE - 1) & ~(PAGE - 1)
        for i, word in enumerate(words):
            for b in range(4):
                self.mem[first + 4 * i + b] &= (word >> (8 * b)) & 0xFF

    def word(self, addr: int) -> int:
        """Return the word at a byte address."""
        end = addr + 4
        return int.from_bytes(self.mem[addr:end], "little")

    def line(self, addr: int) -> list[int]:
        """Return the four words of the line that holds the address."""
        base = addr & ~15
        return [self.word(base + 4 * i) for i in range(4)]


# The chip keeps its content from one test to the next, so the reference
# does too.
CHIP = Chip()


def cycles(t_ns: int, period: int, margin: int = 0) -> int:
    """Return the number of clocks that cover a time."""
    return max(1, math.ceil((t_ns + margin) / period))


def generic(dut: Dut, name: str) -> int:
    """Return an integer generic of the design."""
    return int(getattr(dut, name).value)


async def start(dut: Dut):
    """Start the clock and reset the DUT."""
    period = generic(dut, "clk_period_ns")
    cocotb.start_soon(Clock(dut.i_clk, period, unit="ns").start())
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
    await wait_idle(dut)


async def wait_idle(dut: Dut, limit: int = 40000):
    """Wait for the controller to accept commands."""
    for _ in range(limit):
        await Timer(1, unit="ns")
        if int(dut.o_cmd_busy.value) == 0:
            return
        await RisingEdge(dut.i_clk)
    raise AssertionError("o_cmd_busy never fell")


async def read(dut: Dut, addr: int, line: int, timeout: int = 400):
    """Hold a request until ready, then advance.

    Return the words read and the busy clocks.
    """
    dut.i_addr.value = addr
    dut.i_line.value = line
    dut.i_rden.value = 1
    busy = 0
    for _ in range(timeout):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        busy += int(dut.o_busy.value)
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
            return words, busy
    raise AssertionError(f"no ready for {addr:#x}")


async def command(dut: Dut, op: int, addr: int = 0):
    """Send one command for one clock."""
    dut.i_cmd_valid.value = 1
    dut.i_cmd_op.value = op
    dut.i_cmd_addr.value = addr
    await RisingEdge(dut.i_clk)
    dut.i_cmd_valid.value = 0
    await Timer(1, unit="ns")


async def fill_buffer(dut: Dut, words: list[int]):
    """Write the words of a page into the buffer."""
    for index in range(PAGE // 4):
        dut.i_buf_we.value = 1
        dut.i_buf_widx.value = index
        dut.i_buf_wdata.value = words[index] if index < len(words) else MASK32
        await RisingEdge(dut.i_clk)
    dut.i_buf_we.value = 0
    await Timer(1, unit="ns")


async def erase(dut: Dut, chip: Chip, addr: int) -> list[tuple[int, int, int]]:
    """Run WREN and erase on the chip and the reference."""
    pulses = await run_op(dut, ERASE, addr)
    chip.erase(addr)
    return pulses


async def program(dut: Dut, chip: Chip, addr: int, words: list[int]):
    """Fill the buffer, run WREN and program on both models."""
    await fill_buffer(dut, words)
    pulses = await run_op(dut, PROGRAM, addr)
    chip.program(addr, words)
    return pulses


async def run_op(dut: Dut, op: int, addr: int) -> list[tuple[int, int, int]]:
    """Arm the latch, send the command and wait for the end.

    Return the invalidations; each pulse is (cycles busy, first, last).
    """
    await command(dut, WREN)
    check_equal(int(dut.o_wel.value), 1, "latch armed")
    await command(dut, op, addr)
    pulses: list[tuple[int, int, int]] = []
    for busy in range(2_000_000):
        await Timer(1, unit="ns")
        if int(dut.o_inval_valid.value) == 1:
            pulses.append(
                (
                    busy,
                    int(dut.o_inval_first.value),
                    int(dut.o_inval_last.value),
                )
            )
            check_equal(
                int(dut.o_cmd_busy.value), 0, "busy drops with the pulse"
            )
            check_equal(int(dut.o_wel.value), 0, "latch drops with the pulse")
            return pulses
        await RisingEdge(dut.i_clk)
    raise AssertionError("the operation never ended")


async def check_line(dut: Dut, chip: Chip, addr: int):
    """Read a line and compare with the reference."""
    words, _ = await read(dut, addr, 1)
    check_equal(
        [hex(w) for w in words],
        [hex(w) for w in chip.line(addr)],
        f"line {addr:#x}",
    )


@cocotb.test()
async def test_read_latency_follows_the_timing_generics(dut: Dut):
    """Check the busy clocks of a word and a line by the formula."""
    await start(dut)
    period = generic(dut, "clk_period_ns")
    margin = generic(dut, "margin_ns")
    n_first = cycles(generic(dut, "t_acc_ns"), period, margin)
    n_next = cycles(generic(dut, "t_pacc_ns"), period, margin)
    chip = CHIP
    words, busy = await read(dut, 0x1234, 0)
    check_equal(words, [chip.word(0x1234)], "word")
    check_equal(busy, n_first + 3 * n_next, "word latency")
    words, busy = await read(dut, 0x2230, 1)
    check_equal(words, chip.line(0x2230), "line")
    check_equal(busy, n_first + 15 * n_next, "line latency")


@cocotb.test()
async def test_random_reads_match_the_reference(dut: Dut):
    """Check random word and line reads against the pattern."""
    await start(dut)
    chip = CHIP
    prng = Prng(0x4E4F52)
    for n in range(60):
        addr = prng.randrange(SIZE) if n % 2 else (prng.randrange(SIZE) & ~3)
        line = n % 3 == 0
        words, _ = await read(dut, addr, int(line))
        want = chip.line(addr) if line else [chip.word(addr & ~3)]
        check_equal(words, want, f"read {addr:#x} line={line}")


@cocotb.test()
async def test_out_of_window_reads_zero(dut: Dut):
    """Check that a read past the 64 KB chip returns zero."""
    await start(dut)
    words, _ = await read(dut, 0x20010, 1)
    check_equal(words, [0] * 4, "out of window line")
    words, _ = await read(dut, 0x20104, 0)
    check_equal(words, [0], "out of window word")
    chip = CHIP
    words, _ = await read(dut, 0x100, 0)
    check_equal(words, [chip.word(0x100)], "inside again")


@cocotb.test()
async def test_erase_a_sector(dut: Dut):
    """Check that an erase sets only its sector to ones."""
    await start(dut)
    chip = CHIP
    pulses = await erase(dut, chip, BASE + 2 * SECTOR + 0x10)
    check_equal(len(pulses), 1, "one pulse")
    _, first, last = pulses[0]
    check_equal(
        (first, last), (BASE + 2 * SECTOR, BASE + 3 * SECTOR - 1), "region"
    )
    for addr in (2 * SECTOR - 16, 2 * SECTOR, 3 * SECTOR - 16, 3 * SECTOR):
        await check_line(dut, chip, addr)


@cocotb.test()
async def test_program_a_page_and_not_to_ones_without_erase(dut: Dut):
    """Check the AND of the buffer with the content."""
    await start(dut)
    chip = CHIP
    await erase(dut, chip, 5 * SECTOR)
    words = [0xC0DE0000 + i for i in range(PAGE // 4)]
    words[3] = MASK32
    words[4] = 0xFF00FF00
    pulses = await program(dut, chip, BASE + 5 * SECTOR + 2 * PAGE, words)
    _, first, last = pulses[0]
    check_equal(
        (first, last),
        (BASE + 5 * SECTOR + 2 * PAGE, BASE + 5 * SECTOR + 3 * PAGE - 1),
        "region",
    )
    for off in range(0, 4 * PAGE, 16):
        await check_line(dut, chip, 5 * SECTOR + off)
    # A second program over the same page only clears more bits.
    await program(
        dut, chip, BASE + 5 * SECTOR + 2 * PAGE, [0x0F0F0F0F] * (PAGE // 4)
    )
    for off in range(2 * PAGE, 3 * PAGE, 16):
        await check_line(dut, chip, 5 * SECTOR + off)


@cocotb.test()
async def test_command_rules(dut: Dut):
    """Check the latch, the refusals and the K4 protection."""
    await start(dut)
    chip = CHIP
    # Without the latch the erase is ignored by the whole.
    await command(dut, ERASE, 7 * SECTOR)
    await Timer(5, unit="ns")
    check_equal(
        int(dut.o_cmd_busy.value), 0, "ignored erase does not busy the chip"
    )
    check_equal(int(dut.o_refused.value), 0, "ignored erase does not refuse")
    await check_line(dut, chip, 7 * SECTOR)
    # A protected sector is refused and drops the latch.
    await command(dut, PROTECT, 7 * SECTOR)
    await command(dut, WREN)
    await command(dut, ERASE, 7 * SECTOR + 0x20)
    check_equal(
        (int(dut.o_refused.value), int(dut.o_wel.value)),
        (1, 0),
        "protected refused",
    )
    await check_line(dut, chip, 7 * SECTOR)
    # An address outside the window is refused.
    await command(dut, WREN)
    check_equal(int(dut.o_refused.value), 0, "wren clears the refusal")
    await command(dut, ERASE, BASE + 0x40000)
    check_equal(
        (int(dut.o_refused.value), int(dut.o_wel.value)),
        (1, 0),
        "window refused",
    )
    # Unprotect releases the sector.
    await command(dut, UNPROTECT, 7 * SECTOR)
    await erase(dut, chip, 7 * SECTOR)
    await check_line(dut, chip, 7 * SECTOR)
    # A reset clears the protection.
    await command(dut, PROTECT, 8 * SECTOR)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await RisingEdge(dut.i_clk)
    await wait_idle(dut)
    await erase(dut, chip, 8 * SECTOR)
    await check_line(dut, chip, 8 * SECTOR)


@cocotb.test()
async def test_read_waits_for_an_operation_and_commands_wait_for_a_read(
    dut: Dut,
):
    """Check that a read during an erase is served after it."""
    await start(dut)
    chip = CHIP
    await command(dut, WREN)
    await command(dut, ERASE, 9 * SECTOR)
    chip.erase(9 * SECTOR)
    check_equal(int(dut.o_cmd_busy.value), 1, "erase is running")
    words, _ = await read(dut, 9 * SECTOR + 0x100, 1, timeout=100000)
    check_equal(words, chip.line(9 * SECTOR + 0x100), "read after the erase")
    check_equal(int(dut.o_cmd_busy.value), 0, "idle")


@cocotb.test()
async def test_random_operations_match_the_reference(dut: Dut):
    """Check a random mix of operations against the reference."""
    await start(dut)
    chip = CHIP
    prng = Prng(0x4B34)
    sectors = SIZE // SECTOR
    for _ in range(14):
        kind = prng.randrange(3)
        sector = prng.randrange(sectors)
        if kind == 0:
            await erase(dut, chip, sector * SECTOR)
        elif kind == 1:
            page = prng.randrange(SECTOR // PAGE) * PAGE
            words = [
                prng.getrandbits(32)
                | (0xFF000000 if prng.randrange(4) == 0 else 0)
                for _ in range(PAGE // 4)
            ]
            await program(dut, chip, sector * SECTOR + page, words)
        addr = sector * SECTOR + prng.randrange(SECTOR)
        await check_line(dut, chip, addr)
        await check_line(dut, chip, (addr + 16) % SIZE)
