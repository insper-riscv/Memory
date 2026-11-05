"""The JTAG port of the SDRAM debug.

The testbench plays the Virtual JTAG instance (it drives the scan
states) and the debug master (it answers a command toggle with a done
toggle and a response after a few clocks). The 64-bit DEBUG register is
selected by instruction 1: a command goes in, the status, the last word
and the data read of the previous command come out.

"""

import cocotb
from cocotb.triggers import Timer

from tests.python.unittests import jtag
from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

MASTER_CLK_NS = 10
MASTER_DELAY = 6  # clocks the master takes to finish a command
SLOW_DELAY = 4000  # clocks of a master that is busy across a few scans
REGISTER_BITS = 64
BUSY, ERROR, INIT, OVERRUN = 1, 2, 4, 8
OP_NOP, OP_READ, OP_WRITE = 0, 1, 2
RESPONSE_ADDR = 0xABCDEF
RESPONSE_DATA = 0x600DF00D
RESPONSE_STATUS = 0b110  # error and initialized, as the master reports


class Master:
    """The debug master side: finishes every command it is sent."""

    def __init__(self, dut: Dut, delay: int = MASTER_DELAY) -> None:
        """Keep the design, the delay and the log of commands."""
        self.dut = dut
        self.delay = delay
        self.commands: list[tuple[int, int, int, int]] = []

    async def run(self) -> None:
        """Answer every command, one master clock a step."""
        dut = self.dut
        last = int(dut.o_cmd_tog.value)
        while True:
            await Timer(MASTER_CLK_NS, unit="ns")
            tog = int(dut.o_cmd_tog.value)
            if tog == last:
                continue
            last = tog
            self.commands.append(
                (
                    int(dut.o_op.value),
                    int(dut.o_be.value),
                    int(dut.o_addr.value),
                    int(dut.o_data.value),
                )
            )
            for _ in range(self.delay):
                await Timer(MASTER_CLK_NS, unit="ns")
            dut.i_rsp_addr.value = RESPONSE_ADDR
            dut.i_rsp_data.value = RESPONSE_DATA
            dut.i_rsp_status.value = RESPONSE_STATUS
            dut.i_done_tog.value = tog


async def tck(dut: Dut) -> None:
    """Give one idle TCK pulse."""
    await jtag.tck(dut, "")


async def load_ir(dut: Dut, value: int) -> None:
    """Load a value into the instruction register."""
    await jtag.load_ir(dut, value, "")


async def scan(dut: Dut, length: int, value: int) -> int:
    """Capture, shift `length` bits and update; returns the bits out."""
    return await jtag.shift_dr(dut, length, value, "")


def command_word(op: int, addr: int = 0, data: int = 0, be: int = 0xF) -> int:
    """Pack a command into the DEBUG register."""
    return (op << 60) | (be << 56) | (addr << 32) | data


async def debug(dut: Dut, word: int) -> tuple[int, int, int]:
    """Shift a command in. Returns (status, word, data) of the last."""
    out = await scan(dut, REGISTER_BITS, word)
    return out >> 56, (out >> 32) & 0xFFFFFF, out & 0xFFFFFFFF


async def settle(dut: Dut) -> tuple[int, int, int]:
    """Shift NOPs until the previous command is not busy any more."""
    for _ in range(50):
        status, addr, data = await debug(dut, command_word(OP_NOP))
        if not status & BUSY:
            return status, addr, data
    raise AssertionError("the command never finished")


async def start(dut: Dut, delay: int = MASTER_DELAY) -> Master:
    """Start the master side and select the register.

    The design has no reset, so the master first reports done for the
    commands an earlier test left pending.
    """
    for name in ("cdr", "sdr", "udr", "uir"):
        getattr(dut, f"i_state_{name}").value = 0
    dut.i_tck.value = 0
    dut.i_tdi.value = 0
    await Timer(1, unit="ns")
    dut.i_ir_in.value = 0
    dut.i_done_tog.value = int(dut.o_cmd_tog.value)
    dut.i_rsp_addr.value = 0
    dut.i_rsp_data.value = 0
    dut.i_rsp_status.value = 0
    master = Master(dut, delay)
    cocotb.start_soon(master.run())
    for _ in range(4):
        await tck(dut)
    await load_ir(dut, 1)
    return master


@cocotb.test()
async def test_a_command_reaches_the_master(dut: Dut):
    """The fields of the DEBUG register come out on the command bus."""
    master = await start(dut)
    await debug(dut, command_word(OP_WRITE, 0x123456, 0xCAFEBABE, 0x9))
    await settle(dut)
    check_equal(master.commands, [(OP_WRITE, 0x9, 0x123456, 0xCAFEBABE)])


@cocotb.test()
async def test_the_response_comes_out_of_the_next_scan(dut: Dut):
    """The scan after a command shows the status, word and data."""
    await start(dut)
    await debug(dut, command_word(OP_READ, 0x42))
    status, addr, data = await settle(dut)
    check_equal((addr, data), (RESPONSE_ADDR, RESPONSE_DATA))
    check_equal(status & (ERROR | INIT), RESPONSE_STATUS)
    check_equal(status & BUSY, 0)


@cocotb.test()
async def test_a_nop_only_reads_the_status(dut: Dut):
    """A scan with op 0 sends nothing to the master."""
    master = await start(dut)
    for _ in range(3):
        await debug(dut, command_word(OP_NOP, 0x77, 0x88))
    check_equal(len(master.commands), 0)


@cocotb.test()
async def test_a_command_during_a_busy_master_is_dropped(dut: Dut):
    """A command that finds the master busy sets overrun and is lost."""
    master = await start(dut, SLOW_DELAY)
    await debug(dut, command_word(OP_WRITE, 0x1, 0x11))
    status, _, _ = await debug(dut, command_word(OP_WRITE, 0x2, 0x22))
    check_equal(status & BUSY, BUSY, "busy right after a command")
    await settle(dut)
    check_equal(len(master.commands), 1, "second command dropped")
    status, _, _ = await debug(dut, command_word(OP_NOP))
    check_equal(status & OVERRUN, OVERRUN, "overrun reported")


@cocotb.test()
async def test_the_overrun_clears_with_an_accepted_command(dut: Dut):
    """The next accepted command takes the overrun flag away."""
    master = await start(dut, SLOW_DELAY)
    await debug(dut, command_word(OP_WRITE, 0x1, 0x11))
    await debug(dut, command_word(OP_WRITE, 0x2, 0x22))
    await settle(dut)
    await debug(dut, command_word(OP_WRITE, 0x3, 0x33))
    await settle(dut)
    status, _, _ = await debug(dut, command_word(OP_NOP))
    check_equal(status & OVERRUN, 0, "overrun cleared")
    check_equal([c[2] for c in master.commands], [0x1, 0x3])


@cocotb.test()
async def test_other_instructions_select_the_bypass(dut: Dut):
    """With another instruction the data register is a single bit."""
    master = await start(dut)
    await load_ir(dut, 0)
    out = await scan(dut, 8, 0b10110010)
    check_equal(out & 0xFE, 0b01100100 & 0xFE, "bypass delays by one bit")
    check_equal(len(master.commands), 0, "nothing sent")
    await load_ir(dut, 1)
    await debug(dut, command_word(OP_READ, 0x9))
    await settle(dut)
    check_true(len(master.commands) == 1, "the register is back")
