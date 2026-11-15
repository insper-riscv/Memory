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
OP_CONTROL = 7
CTRL_SEEK = 2  # subcommand of op 7 (in be) that moves the stream pointer
STREAM_ERROR, HOLD = 0x10, 0x20  # status bits above the overrun
IR_DEBUG, IR_STREAM_WRITE, IR_STREAM_READ = 1, 2, 3
STREAM_WORDS = 128  # words a stream shift moves, at most
FRAME_BITS = 64  # bits of the status frame that open a stream shift
RESPONSE_ADDR = 0xABCDEF
RESPONSE_DATA = 0x600DF00D
RESPONSE_STATUS = 0b110  # error and initialized, as the master reports


class Master:
    """The debug master side: finishes every command it is sent."""

    def __init__(
        self,
        dut: Dut,
        delay: int = MASTER_DELAY,
        memory: dict[int, int] | None = None,
    ) -> None:
        """Keep the design, the delay, the log and an optional memory.

        With a memory the master reads and writes it like the real one
        and answers with the last word accessed; without it the answer
        is a fixed one.
        """
        self.dut = dut
        self.delay = delay
        self.memory = memory
        self.commands: list[tuple[int, int, int, int]] = []

    def _respond(self) -> None:
        """Set the response data for the command just received."""
        dut = self.dut
        op, _be, addr, data = self.commands[-1]
        if self.memory is None:
            dut.i_rsp_addr.value = RESPONSE_ADDR
            dut.i_rsp_data.value = RESPONSE_DATA
            return
        word = addr | (op >> 3 & 1) << 24
        if op & 7 == OP_WRITE:
            self.memory[word] = data
        if op & 7 in (OP_READ, OP_WRITE):
            dut.i_rsp_addr.value = word & 0xFFFFFF
            dut.i_rsp_data.value = self.memory.get(word, 0)

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
            self._respond()
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


async def start(
    dut: Dut,
    delay: int = MASTER_DELAY,
    memory: dict[int, int] | None = None,
) -> Master:
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
    master = Master(dut, delay, memory)
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


async def stream_write(dut: Dut, words: list[int]) -> int:
    """Shift the words into the stream register; return the frame."""
    await load_ir(dut, IR_STREAM_WRITE)
    value = sum(w << (32 * i) for i, w in enumerate(words))
    out = await scan(dut, 32 * len(words), value)
    await load_ir(dut, IR_DEBUG)
    return out & ((1 << FRAME_BITS) - 1)


async def stream_read(dut: Dut, count: int) -> tuple[int, list[int]]:
    """Shift `count` words out of the stream register.

    Returns the status frame and the words.
    """
    await load_ir(dut, IR_STREAM_READ)
    out = await scan(dut, FRAME_BITS + 32 * count, 0)
    await load_ir(dut, IR_DEBUG)
    frame = out & ((1 << FRAME_BITS) - 1)
    words = [(out >> (FRAME_BITS + 32 * i)) & 0xFFFFFFFF for i in range(count)]
    return frame, words


async def seek(dut: Dut, addr: int) -> None:
    """Point the stream at a word, 25 bits of address."""
    await debug(
        dut,
        command_word(
            OP_CONTROL | (addr >> 24 & 1) << 3, addr & 0xFFFFFF, 0, CTRL_SEEK
        ),
    )


async def read_status(dut: Dut) -> int:
    """Return the status byte of the DEBUG register."""
    return (await debug(dut, command_word(OP_NOP)))[0]


@cocotb.test()
async def test_seek_only_moves_the_pointer(dut: Dut):
    """A seek is not forwarded and the stream starts at its address."""
    master = await start(dut, memory={})
    await seek(dut, 0x123456)
    check_equal(len(master.commands), 0, "the master saw the seek")
    await stream_write(dut, [0xA0A0A0A0, 0x0B0B0B0B, 0xC0C0C0C0])
    await settle(dut)
    check_equal(
        [(c[0], c[1], c[2], c[3]) for c in master.commands],
        [
            (OP_WRITE, 0xF, 0x123456 + i, w)
            for i, w in enumerate([0xA0A0A0A0, 0x0B0B0B0B, 0xC0C0C0C0])
        ],
    )


@cocotb.test()
async def test_a_stream_write_moves_the_pointer_between_shifts(dut: Dut):
    """Two shifts in a row write consecutive words."""
    memory: dict[int, int] = {}
    await start(dut, memory=memory)
    await seek(dut, 0x40)
    first = [0x1000 + i for i in range(32)]
    second = [0x2000 + i for i in range(32)]
    await stream_write(dut, first)
    await settle(dut)
    await stream_write(dut, second)
    await settle(dut)
    check_equal(
        [memory[0x40 + i] for i in range(64)],
        first + second,
        "the words are consecutive",
    )
    check_equal(await read_status(dut) & STREAM_ERROR, 0, "no stream error")


@cocotb.test()
async def test_a_stream_write_of_the_largest_burst(dut: Dut):
    """4096 bits are 128 words, and what comes after is ignored."""
    memory: dict[int, int] = {}
    master = await start(dut, memory=memory)
    await seek(dut, 0)
    words = [0xFACE0000 + i for i in range(STREAM_WORDS + 3)]
    await stream_write(dut, words)
    await settle(dut)
    check_equal(len(master.commands), STREAM_WORDS, "only 128 words")
    check_equal([memory[i] for i in range(STREAM_WORDS)], words[:STREAM_WORDS])
    check_true(STREAM_WORDS not in memory, "a 129th word was written")


@cocotb.test()
async def test_a_partial_word_is_not_written(dut: Dut):
    """Bits that do not make a whole word send nothing."""
    master = await start(dut, memory={})
    await seek(dut, 8)
    await load_ir(dut, IR_STREAM_WRITE)
    await scan(dut, 31, 0x7FFFFFFF)
    await load_ir(dut, IR_DEBUG)
    await settle(dut)
    check_equal(len(master.commands), 0)


@cocotb.test()
async def test_a_stream_read_returns_the_words_in_order(dut: Dut):
    """Words come out after the status frame, from the pointer on."""
    memory = {0x80 + i: 0xBEEF0000 + i for i in range(3 * STREAM_WORDS)}
    await start(dut, memory=memory)
    await seek(dut, 0x80)
    frame, words = await stream_read(dut, 5)
    check_equal(words, [memory[0x80 + i] for i in range(5)])
    check_equal((frame >> 56) & (BUSY | STREAM_ERROR), 0, "clean frame")
    frame, words = await stream_read(dut, STREAM_WORDS)
    check_equal(
        words,
        [memory[0x85 + i] for i in range(STREAM_WORDS)],
        "the second shift continues the first",
    )
    check_equal(await read_status(dut) & STREAM_ERROR, 0, "no stream error")


@cocotb.test()
async def test_a_seek_reaches_the_upper_half_of_a_128_mb_sdram(dut: Dut):
    """Bit 24 of the pointer comes with the seek, goes to the read."""
    memory = {(1 << 24) + 7: 0x13572468, 7: 0x0}
    master = await start(dut, memory=memory)
    await seek(dut, (1 << 24) + 7)
    _, words = await stream_read(dut, 1)
    check_equal(words, [0x13572468])
    check_true(master.commands[0][0] & 8, "bit 24 of the address in op")


@cocotb.test()
async def test_a_slow_master_flags_the_stream_error(dut: Dut):
    """A word that finds the master busy is lost and flagged."""
    master = await start(dut, SLOW_DELAY, memory={})
    await seek(dut, 0)
    await stream_write(dut, [1, 2, 3])
    await settle(dut)
    check_equal(len(master.commands), 1, "the others were dropped")
    check_equal(
        await read_status(dut) & STREAM_ERROR, STREAM_ERROR, "error flag"
    )
    await debug(dut, command_word(OP_WRITE, 0x5, 0x5))
    await settle(dut)
    check_equal(
        await read_status(dut) & STREAM_ERROR,
        0,
        "an accepted command clears it",
    )


@cocotb.test()
async def test_a_late_read_word_is_flagged(dut: Dut):
    """A stream read whose first word is not there yet is flagged."""
    await start(dut, SLOW_DELAY, memory={0: 5})
    await seek(dut, 0)
    await stream_read(dut, 2)
    await settle(dut)
    check_equal(
        await read_status(dut) & STREAM_ERROR, STREAM_ERROR, "error flag"
    )


@cocotb.test()
async def test_a_wrong_word_in_a_stream_read_is_flagged(dut: Dut):
    """The master answers a word other than the one asked for."""
    await start(dut)  # the fixed answer is never the word at the pointer
    await seek(dut, 0x10)
    await stream_read(dut, 2)
    await settle(dut)
    check_equal(
        await read_status(dut) & STREAM_ERROR, STREAM_ERROR, "error flag"
    )


@cocotb.test()
async def test_the_stream_error_clears_when_a_stream_starts(dut: Dut):
    """The frame of a new stream shows the old error, then drops it."""
    master = await start(dut, SLOW_DELAY, memory={})
    await seek(dut, 0)
    await stream_write(dut, [1, 2])
    await settle(dut)
    master.delay = MASTER_DELAY
    frame = await stream_write(dut, [3, 4])
    check_equal(
        (frame >> 56) & STREAM_ERROR, STREAM_ERROR, "the old error shows"
    )
    await settle(dut)
    check_equal(await read_status(dut) & STREAM_ERROR, 0, "dropped after")


@cocotb.test()
async def test_the_status_reports_the_hold_of_the_master(dut: Dut):
    """Bit 4 of the master status is bit 5 of the frame."""
    await start(dut)
    dut.i_rsp_status.value = RESPONSE_STATUS | 0x10
    got = await read_status(dut)
    check_equal(got & HOLD, HOLD, f"{got:#x}")


@cocotb.test()
async def test_the_control_commands_other_than_seek_reach_the_master(
    dut: Dut,
):
    """Hold and CRC go to the master like any command."""
    master = await start(dut)
    await debug(dut, command_word(OP_CONTROL, 0, 1, 0))
    await settle(dut)
    await debug(dut, command_word(OP_CONTROL, 0x10, 5, 1))
    await settle(dut)
    check_equal(
        master.commands,
        [(OP_CONTROL, 0, 0, 1), (OP_CONTROL, 1, 0x10, 5)],
    )
