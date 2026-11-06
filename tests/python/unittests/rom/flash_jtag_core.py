"""flash_jtag_core.

The JTAG port of the FLASH loader, alone: the testbench plays the
Virtual JTAG instance (the clock, the data in and the scan states) and
the loader behind the port, which answers each command by echoing the
toggle and a configurable response.

"""

import cocotb
from cocotb.triggers import Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut
from tests.python.unittests.jtag import load_ir, shift_dr

IR_CMD, IR_STREAM = 1, 2
OP_NOP, OP_HALT, OP_WRITE, OP_READ, OP_SUMMARY, OP_CURSOR = 0, 1, 3, 4, 5, 6
BUSY, STOPPED, REFUSED, OVERRUN = 1, 2, 4, 8
WORD_MASK = 0xFFFFFFFF
PORT = ""  # the signals are i_tck, i_tdi and so on, with no prefix
SETTLE_NS = 1


class Loader:
    """The loader behind the port: it records and answers commands."""

    def __init__(self, dut: Dut, answers: bool = True) -> None:
        """Start the model; `answers` False leaves the port busy."""
        self.dut = dut
        self.answers = answers
        self.commands: list[tuple[int, int, int]] = []
        self.rsp: tuple[int, int, int] = (0, 0, 0)

    async def run(self) -> None:
        """Record every command and, if asked to, confirm it."""
        while True:
            await self.dut.o_cmd_tog.value_change
            await Timer(SETTLE_NS, unit="ns")
            self.commands.append(
                (
                    int(self.dut.o_op.value),
                    int(self.dut.o_addr.value),
                    int(self.dut.o_data.value),
                )
            )
            if self.answers:
                self.respond()

    def respond(self) -> None:
        """Answer the last command with the configured response."""
        addr, data, status = self.rsp
        self.dut.i_rsp_addr.value = addr
        self.dut.i_rsp_data.value = data
        self.dut.i_rsp_status.value = status
        self.dut.i_done_tog.value = int(self.dut.o_cmd_tog.value)


async def start(dut: Dut, answers: bool = True) -> Loader:
    """Park the inputs, start the loader model and select CMD."""
    started = dut.o_cmd_tog.value.is_resolvable
    dut.i_tck.value = 0
    dut.i_tdi.value = 0
    dut.i_ir_in.value = 0
    for name in ("cdr", "sdr", "udr", "uir"):
        getattr(dut, f"i_state_{name}").value = 0
    # The core keeps its state from the previous test: take the toggle
    # the loader would have answered to, so that the port is not busy.
    dut.i_done_tog.value = int(dut.o_cmd_tog.value) if started else 0
    dut.i_rsp_addr.value = 0
    dut.i_rsp_data.value = 0
    dut.i_rsp_status.value = 0
    await Timer(SETTLE_NS, unit="ns")
    loader = Loader(dut, answers)
    cocotb.start_soon(loader.run())
    for _ in range(3):
        await load_ir(dut, IR_CMD, PORT)
    return loader


async def command(dut: Dut, op: int, addr: int = 0, data: int = 0):
    """Shift a command into CMD; return (status, address, data) out."""
    value = (op << 60) | ((addr & 0xFFFFFF) << 32) | (data & WORD_MASK)
    out = await shift_dr(dut, 64, value, PORT)
    return out >> 56, (out >> 32) & 0xFFFFFF, out & WORD_MASK


async def settle(dut: Dut):
    """Read the status until the port is not busy any more."""
    for _ in range(10):
        status, addr, data = await command(dut, OP_NOP)
        if not status & BUSY:
            return status, addr, data
    raise AssertionError("the port stayed busy")


async def stream(dut: Dut, words: list[int], lead: int = 0):
    """Shift a frame of words after `lead` zero bits and a start bit."""
    await load_ir(dut, IR_STREAM, PORT)
    bits = 1 | sum(w << (1 + 32 * i) for i, w in enumerate(words))
    await shift_dr(dut, lead + 1 + 32 * len(words), bits << lead, PORT)
    await load_ir(dut, IR_CMD, PORT)


@cocotb.test()
async def test_a_command_reaches_the_loader(dut: Dut):
    """Check that the fields of a shifted command are delivered."""
    loader = await start(dut)
    await command(dut, OP_WRITE, 0x123456, 0xCAFEBABE)
    check_equal(loader.commands, [(OP_WRITE, 0x123456, 0xCAFEBABE)])
    await settle(dut)
    await command(dut, OP_HALT)
    check_equal(loader.commands[-1][0], OP_HALT)


@cocotb.test()
async def test_a_nop_only_reads_the_status(dut: Dut):
    """Check that op 0 sends nothing and shows the last response."""
    loader = await start(dut)
    loader.rsp = (0xABCDEF, 0x0BADF00D, 0x03)
    await command(dut, OP_SUMMARY)
    status, addr, data = await settle(dut)
    check_equal(loader.commands, [(OP_SUMMARY, 0, 0)])
    check_equal((addr, data), (0xABCDEF, 0x0BADF00D))
    check_equal(status & (STOPPED | REFUSED), STOPPED | REFUSED)


@cocotb.test()
async def test_the_port_is_busy_until_the_loader_answers(dut: Dut):
    """Check that busy rises with a command and falls with the reply."""
    loader = await start(dut, answers=False)
    await command(dut, OP_HALT)
    status, _, _ = await command(dut, OP_NOP)
    check_equal(status & BUSY, BUSY, "no answer yet")
    loader.respond()
    status, _, _ = await settle(dut)
    check_equal(status & BUSY, 0)


@cocotb.test()
async def test_a_command_while_busy_is_dropped_and_flagged(dut: Dut):
    """Check the overrun: the second command is lost and reported."""
    loader = await start(dut, answers=False)
    await command(dut, OP_WRITE, 1, 0x11)
    await command(dut, OP_WRITE, 2, 0x22)
    status, _, _ = await command(dut, OP_NOP)
    check_equal(status & OVERRUN, OVERRUN)
    check_equal(loader.commands, [(OP_WRITE, 1, 0x11)])
    loader.respond()
    loader.answers = True
    await settle(dut)
    await command(dut, OP_WRITE, 3, 0x33)
    status, _, _ = await settle(dut)
    check_equal(status & OVERRUN, 0, "the next command clears the flag")
    check_equal(loader.commands[-1], (OP_WRITE, 3, 0x33))


@cocotb.test()
async def test_the_stream_writes_from_the_cursor(dut: Dut):
    """Check that the cursor command places the words of the stream."""
    loader = await start(dut)
    await command(dut, OP_CURSOR, 0x000040)
    check_equal(loader.commands, [], "the cursor is resolved here")
    await stream(dut, [0xA0A0A0A0, 0x0000FFFF, 0x80000001])
    check_equal(
        loader.commands,
        [
            (OP_WRITE, 0x40, 0xA0A0A0A0),
            (OP_WRITE, 0x41, 0x0000FFFF),
            (OP_WRITE, 0x42, 0x80000001),
        ],
    )


@cocotb.test()
async def test_bits_before_the_start_and_a_short_word_are_dropped(dut: Dut):
    """Check the framing: leading zeros and an incomplete tail."""
    loader = await start(dut)
    await command(dut, OP_CURSOR, 7)
    await stream(dut, [0x600DF00D], lead=5)
    await load_ir(dut, IR_STREAM, PORT)
    await shift_dr(dut, 20, 0xFFFFF, PORT)
    check_equal(loader.commands, [(OP_WRITE, 7, 0x600DF00D)])


@cocotb.test()
async def test_a_write_or_read_command_moves_the_cursor(dut: Dut):
    """Check that CMD writes and reads move the cursor."""
    loader = await start(dut)
    await command(dut, OP_WRITE, 0x10, 0x1)
    await settle(dut)
    await stream(dut, [0x2])
    await command(dut, OP_READ, 0x30)
    await settle(dut)
    await stream(dut, [0x3])
    check_equal(
        loader.commands,
        [
            (OP_WRITE, 0x10, 0x1),
            (OP_WRITE, 0x11, 0x2),
            (OP_READ, 0x30, 0),
            (OP_WRITE, 0x31, 0x3),
        ],
    )


@cocotb.test()
async def test_other_instructions_are_a_one_bit_bypass(dut: Dut):
    """Check that an unused instruction delays the data by one bit."""
    await start(dut)
    await load_ir(dut, 3, PORT)
    pattern = 0b1011001110001
    out = await shift_dr(dut, 13, pattern, PORT)
    check_true(out & 1 == 0, "the bypass register starts at zero")
    check_equal(out >> 1, pattern & ((1 << 12) - 1))
