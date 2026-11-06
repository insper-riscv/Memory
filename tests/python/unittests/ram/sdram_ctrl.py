"""The SDRAM controller against the chip model.

The testbench plays the requester: it fills the request bus, flips the
request toggle and waits for the acknowledge toggle. The chip model
fails the simulation on any broken chip rule (timings, command order,
power-up sequence, refresh interval), so a passing run also proves the
controller obeys the chip. The tests compare what the controller reads
with a Python copy of the memory and with the content stored in the
model.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import Prng, check_equal, check_true
from tests.python.unittests.dut import Dut
from tests.python.unittests.ram.sdram_helpers import mem_ns, merge

TIMEOUT = 200  # clock cycles an acknowledge may take
INIT_TIMEOUT = 40_000  # clock cycles of the power-up wait, with a margin
LINE = 4  # words in a line
ALL = 0xF
LAST_WORD = (1 << 24) - 1
MIN_REFRESHES = 8  # the power-up sequence alone issues eight
REFRESHES_IN_TRAFFIC = 2  # refreshes during the sustained traffic
LINE_WRITE = 2  # the choice of a line write in the random traffic
SEED = 7
RANDOM_ACCESSES = 60


def _set(dut: Dut, **values: int) -> None:
    """Drive the named inputs of the design."""
    for name, value in values.items():
        getattr(dut, name).value = value


async def start(dut: Dut) -> None:
    """Start the clock, reset and wait for the power-up sequence."""
    cocotb.start_soon(Clock(dut.i_clk, mem_ns(dut), unit="ns").start())
    _set(dut, i_req_tog=0, i_we=0, i_addr=0, i_wdata=0, i_be=0, i_line=0)
    _set(dut, i_wdata_x=0, i_be_x=0, i_dbg_word_addr=0, i_rst=1)
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    for _ in range(INIT_TIMEOUT):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_init_done.value) and int(dut.o_dbg_init_ok.value):
            return
    raise AssertionError("the controller never finished its power-up")


async def request(dut: Dut, tog: int) -> int:
    """Flip the request toggle and wait for the acknowledge.

    Returns the clock cycles the controller took.
    """
    dut.i_req_tog.value = tog
    for cycles in range(1, TIMEOUT):
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if int(dut.o_ack_tog.value) == tog:
            return cycles
    raise AssertionError("the acknowledge never came")


class Requester:
    """The request side of the controller, with a copy of the memory."""

    def __init__(self, dut: Dut) -> None:
        """Keep the design and the request toggle."""
        self.dut = dut
        self.tog = 0
        self.memory: dict[int, int] = {}

    async def word(
        self, we: bool, addr: int, wdata: int = 0, be: int = ALL
    ) -> int:
        """Move one word. Returns the word read."""
        dut = self.dut
        dut.i_we.value = int(we)
        dut.i_addr.value = addr
        dut.i_wdata.value = wdata
        dut.i_be.value = be
        dut.i_line.value = 0
        self.tog ^= 1
        await request(dut, self.tog)
        if we:
            old = self.memory.get(addr, 0)
            self.memory[addr] = merge(old, wdata, be)
        return int(dut.o_rdata.value)

    async def line(
        self, we: bool, addr: int, words: list[int] | None = None
    ) -> list[int]:
        """Move a line of four words. Returns the words read."""
        dut = self.dut
        words = words or [0] * LINE
        dut.i_we.value = int(we)
        dut.i_addr.value = addr
        dut.i_wdata.value = words[0]
        dut.i_be.value = ALL
        dut.i_wdata_x.value = words[1] | (words[2] << 32) | (words[3] << 64)
        dut.i_be_x.value = 0xFFF
        dut.i_line.value = 1
        self.tog ^= 1
        await request(dut, self.tog)
        dut.i_line.value = 0
        if we:
            base = addr & ~3
            for i, value in enumerate(words):
                self.memory[base + i] = value
        extra = int(dut.o_rdata_x.value)
        return [int(dut.o_rdata.value), *_split(extra)]


def _split(value: int) -> list[int]:
    """Split the three extra words of a line, lowest first."""
    return [(value >> (32 * i)) & 0xFFFFFFFF for i in range(3)]


async def model_word(dut: Dut, word: int) -> int:
    """Return the word as stored in the chip model."""
    dut.i_dbg_word_addr.value = word
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    return int(dut.o_dbg_word_data.value)


@cocotb.test()
async def test_power_up(dut: Dut):
    """The chip accepts the power-up sequence and gets its refreshes."""
    await start(dut)
    check_equal(int(dut.o_dbg_init_ok.value), 1)
    check_true(int(dut.o_dbg_refreshes.value) >= MIN_REFRESHES)


@cocotb.test()
async def test_word_write_then_read(dut: Dut):
    """A written word reads back and sits in the chip."""
    await start(dut)
    req = Requester(dut)
    await req.word(True, 0x123456, 0xCAFEBABE)
    check_equal(await req.word(False, 0x123456), 0xCAFEBABE)
    check_equal(await model_word(dut, 0x123456), 0xCAFEBABE)


@cocotb.test()
async def test_byte_enables(dut: Dut):
    """Every byte-enable mask writes exactly the enabled bytes."""
    await start(dut)
    req = Requester(dut)
    for be in range(16):
        word = 0x000100 + be
        await req.word(True, word, 0x11223344)
        await req.word(True, word, 0xA5B6C7D8, be)
        got = await req.word(False, word)
        want = merge(0x11223344, 0xA5B6C7D8, be)
        check_equal(got, want, f"be={be:04b}: 0x{got:08X} != 0x{want:08X}")


@cocotb.test()
async def test_address_decode(dut: Dut):
    """Words in different banks, rows and columns stay apart."""
    await start(dut)
    req = Requester(dut)
    words = [0, 1, 0x1FF, 0x200, 0x400, 0x600, 0x800, 0x7FFFF, LAST_WORD]
    for i, word in enumerate(words):
        await req.word(True, word, (0x9E3779B1 * (i + 1)) & 0xFFFFFFFF)
    for word in words:
        got = await req.word(False, word)
        check_equal(got, req.memory[word], f"word 0x{word:06X}")
        check_equal(await model_word(dut, word), req.memory[word])


@cocotb.test()
async def test_line_write_then_read(dut: Dut):
    """A line moves four words at once, from the aligned address."""
    await start(dut)
    req = Requester(dut)
    words = [0x01020304, 0x05060708, 0x090A0B0C, 0x0D0E0F10]
    await req.line(True, 0x002000, words)
    check_equal(await req.line(False, 0x002000), words)
    check_equal(await req.line(False, 0x002002), words, "low bits ignored")
    for i, word in enumerate(words):
        check_equal(await model_word(dut, 0x002000 + i), word)


@cocotb.test()
async def test_line_and_word_accesses_agree(dut: Dut):
    """Words written one by one read as a line, and the other way."""
    await start(dut)
    req = Requester(dut)
    for i in range(LINE):
        await req.word(True, 0x003000 + i, 0xA0000000 + i)
    check_equal(
        await req.line(False, 0x003000), [0xA0000000 + i for i in range(LINE)]
    )
    await req.line(True, 0x003100, [0xB0000000 + i for i in range(LINE)])
    for i in range(LINE):
        check_equal(await req.word(False, 0x003100 + i), 0xB0000000 + i)


@cocotb.test()
async def test_refresh_runs_between_accesses(dut: Dut):
    """Refreshes keep coming during sustained line traffic."""
    await start(dut)
    req = Requester(dut)
    before = int(dut.o_dbg_refreshes.value)
    words = [0xC0DE0000 + i for i in range(LINE)]
    for n in range(400):
        base = 0x004000 + 4 * (n % 8)
        await req.line(True, base, words)
        check_equal(await req.line(False, base), words, f"line {n}")
    after = int(dut.o_dbg_refreshes.value)
    check_true(
        after - before >= REFRESHES_IN_TRAFFIC,
        f"refreshes {before} -> {after}",
    )


async def random_access(req: Requester, rng: Prng) -> None:
    """Make one random access and check what a read returns."""
    word = 0x005000 + rng.randrange(64)
    choice = rng.randrange(4)
    if choice == 0:
        await req.word(True, word, rng.getrandbits(32), rng.randrange(16))
    elif choice == 1:
        got = await req.word(False, word)
        check_equal(got, req.memory.get(word, 0), f"word 0x{word:06X}")
    elif choice == LINE_WRITE:
        await req.line(True, word, [rng.getrandbits(32) for _ in range(LINE)])
    else:
        base = word & ~3
        want = [req.memory.get(base + i, 0) for i in range(LINE)]
        check_equal(await req.line(False, base), want, f"0x{base:06X}")


@cocotb.test()
async def test_random_traffic(dut: Dut):
    """Mixed word and line traffic matches a copy of the memory."""
    await start(dut)
    req = Requester(dut)
    rng = Prng(SEED)
    for _ in range(RANDOM_ACCESSES):
        await random_access(req, rng)
    for word, value in req.memory.items():
        check_equal(await model_word(dut, word), value, f"0x{word:06X}")
