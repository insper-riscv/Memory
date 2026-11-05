"""The SDRAM debug master.

The testbench plays the host (a command toggle with the command bus held
until the done toggle flips) and the arbiter (it answers the master B
request toggle from a dictionary that stands for the memory). The
timeout of the master is a generic, set small by tests.json.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

CLK_NS = 10
TIMEOUT = 300  # clock cycles a command may take
ARBITER_DELAY = 3  # clock cycles the arbiter takes per request
OP_NOP, OP_READ, OP_WRITE, OP_FILL, OP_COUNT, OP_READ_NEXT, OP_WRITE_NEXT = (
    range(7)
)
ERROR = 0b010
INIT = 0b100
ALL = 0xF
FILL_VALUE = 0xFEEDF00D
FILL_COUNT = 5


def merge(old: int, new: int, be: int) -> int:
    """Merge new bytes into an old word by byte enable."""
    out = old
    for i in range(4):
        if (be >> i) & 1:
            out = (out & ~(0xFF << (8 * i))) | (new & (0xFF << (8 * i)))
    return out


class Arbiter:
    """The arbiter side: serves master B from a dictionary."""

    def __init__(self, dut: Dut, answer: bool = True) -> None:
        """Keep the design, an empty memory and the log of requests."""
        self.dut = dut
        self.answer = answer
        self.memory: dict[int, int] = {}
        self.log: list[tuple[int, int, int, int]] = []

    async def run(self) -> None:
        """Answer every request of master B, forever."""
        dut = self.dut
        last = 0
        while True:
            await RisingEdge(dut.i_clk)
            req = int(dut.o_b_req_tog.value)
            if req == last or not self.answer:
                continue
            last = req
            we = int(dut.o_b_we.value)
            addr = int(dut.o_b_addr.value)
            wdata = int(dut.o_b_wdata.value)
            be = int(dut.o_b_be.value)
            self.log.append((we, addr, wdata, be))
            for _ in range(ARBITER_DELAY):
                await RisingEdge(dut.i_clk)
            if we:
                self.memory[addr] = merge(self.memory.get(addr, 0), wdata, be)
            dut.i_b_rdata.value = self.memory.get(addr, 0)
            dut.i_b_ack_tog.value = req


class Host:
    """The host side: sends commands and reads the response."""

    def __init__(self, dut: Dut) -> None:
        """Keep the design and the command toggle."""
        self.dut = dut
        self.tog = 0

    async def command(
        self, op: int, addr: int = 0, data: int = 0, be: int = ALL
    ) -> tuple[int, int, int]:
        """Send one command. Returns (status, last word, read data)."""
        dut = self.dut
        dut.i_op.value = op
        dut.i_be.value = be
        dut.i_addr.value = addr
        dut.i_data.value = data
        self.tog ^= 1
        dut.i_cmd_tog.value = self.tog
        for _ in range(TIMEOUT * 4):
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            if int(dut.o_done_tog.value) == self.tog:
                return (
                    int(dut.o_rsp_status.value),
                    int(dut.o_rsp_addr.value),
                    int(dut.o_rsp_data.value),
                )
        raise AssertionError(f"command {op} never finished")


async def start(
    dut: Dut, init_done: bool = True, answer: bool = True
) -> tuple[Host, Arbiter]:
    """Start the clock, reset and start the arbiter side."""
    for signal in (
        dut.i_cmd_tog,
        dut.i_op,
        dut.i_be,
        dut.i_addr,
        dut.i_data,
        dut.i_b_ack_tog,
        dut.i_b_rdata,
    ):
        signal.value = 0
    dut.i_init_done.value = int(init_done)
    dut.i_rst.value = 1
    cocotb.start_soon(Clock(dut.i_clk, CLK_NS, unit="ns").start())
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    arbiter = Arbiter(dut, answer)
    cocotb.start_soon(arbiter.run())
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    return Host(dut), arbiter


@cocotb.test()
async def test_write_then_read(dut: Dut):
    """A write reaches the arbiter and a read returns it."""
    host, arbiter = await start(dut)
    await host.command(OP_WRITE, 0x1234, 0xCAFEBABE)
    check_equal(arbiter.log[-1], (1, 0x1234, 0xCAFEBABE, ALL))
    status, word, data = await host.command(OP_READ, 0x1234)
    check_equal((word, data), (0x1234, 0xCAFEBABE))
    check_equal(status & ERROR, 0, "no error")
    check_equal(arbiter.log[-1][0], 0, "a read is not a write")


@cocotb.test()
async def test_byte_enables_reach_the_arbiter(dut: Dut):
    """The byte enables of a write are forwarded as they came."""
    host, arbiter = await start(dut)
    for be in range(1, 16):
        await host.command(OP_WRITE, 0x40, 0x11223344)
        await host.command(OP_WRITE, 0x40, 0xA5B6C7D8, be)
        check_equal(arbiter.log[-1][3], be)
        check_equal(
            arbiter.memory[0x40],
            merge(0x11223344, 0xA5B6C7D8, be),
            f"{be:04b}",
        )


@cocotb.test()
async def test_nop_and_unknown_ops_finish_without_a_request(dut: Dut):
    """Op 0 and the undefined ops are acknowledged and do nothing."""
    host, arbiter = await start(dut)
    for op in (OP_NOP, 7, 12, 15):
        await host.command(op, 0x99, 0x1)
    check_equal(len(arbiter.log), 0, "no request for a nop")


@cocotb.test()
async def test_fill_writes_count_words(dut: Dut):
    """Op 4 sets the count and op 3 fills that many words from addr."""
    host, arbiter = await start(dut)
    await host.command(OP_COUNT, 0, FILL_COUNT)
    await host.command(OP_FILL, 0x100, FILL_VALUE)
    for i in range(FILL_COUNT):
        check_equal(arbiter.memory[0x100 + i], FILL_VALUE, f"word {i}")
    check_true(0x100 + FILL_COUNT not in arbiter.memory, "filled too much")
    _, word, _ = await host.command(OP_NOP)
    check_equal(word, 0x100 + FILL_COUNT - 1, "last word accessed")


@cocotb.test()
async def test_a_zero_count_fills_nothing(dut: Dut):
    """A fill with a count of zero sends no request."""
    host, arbiter = await start(dut)
    await host.command(OP_COUNT, 0, 0)
    await host.command(OP_FILL, 0x200, FILL_VALUE)
    check_equal(len(arbiter.log), 0)


@cocotb.test()
async def test_next_word_commands_follow_the_last_access(dut: Dut):
    """Ops 5 and 6 act on the word after the one accessed last."""
    host, arbiter = await start(dut)
    await host.command(OP_WRITE, 0x300, 0x01010101)
    await host.command(OP_WRITE_NEXT, 0, 0x02020202)
    await host.command(OP_WRITE_NEXT, 0, 0x03030303)
    check_equal(arbiter.memory[0x301], 0x02020202)
    check_equal(arbiter.memory[0x302], 0x03030303)
    await host.command(OP_READ, 0x300)
    _, word, data = await host.command(OP_READ_NEXT)
    check_equal((word, data), (0x301, 0x02020202))
    _, word, data = await host.command(OP_READ_NEXT)
    check_equal((word, data), (0x302, 0x03030303))


@cocotb.test()
async def test_status_reports_the_initialization(dut: Dut):
    """Bit 2 of the status follows the SDRAM initialization flag."""
    host, _ = await start(dut, init_done=False)
    status, _, _ = await host.command(OP_NOP)
    check_equal(status & INIT, 0, "not initialized")
    dut.i_init_done.value = 1
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    status, _, _ = await host.command(OP_NOP)
    check_equal(status & INIT, INIT, "initialized")


@cocotb.test()
async def test_a_silent_arbiter_times_out_with_an_error(dut: Dut):
    """Without an answer the command is dropped and flagged."""
    host, _ = await start(dut, answer=False)
    status, _, _ = await host.command(OP_READ, 0x10)
    check_equal(status & ERROR, ERROR, "error flag")


@cocotb.test()
async def test_the_error_clears_with_the_next_command(dut: Dut):
    """A good command after a timeout reports no error."""
    host, arbiter = await start(dut, answer=False)
    await host.command(OP_READ, 0x10)
    arbiter.answer = True
    await host.command(OP_WRITE, 0x20, 0x5)
    status, _, _ = await host.command(OP_NOP)
    check_equal(status & ERROR, 0, "error cleared")
