"""The data cache in front of the onchip_ram_port.

The same traffic runs in front of the adapter and in front of the
ram_chip (generic USE_CHIP), and every read is compared with a Python
copy of the memory, so the two memories are interchangeable behind the
cache. The window is 4 KB and the cache 4 kbit (512 bytes), so words
512 bytes apart conflict in the cache.

"""

import cocotb

from tests.python.unittests.checks import (
    Prng,
    check_equal,
    check_true,
)
from tests.python.unittests.dut import Dut
from tests.python.unittests.ram.onchip_ram_port import (
    advance,
    clock_edges,
    debug_word,
    drive,
    start,
)
from tests.python.unittests.ram.ram_chip import BASE
from tests.python.unittests.ram.sdram_helpers import merge

CAPACITY = 512  # bytes the 4 kbit cache holds
WORDS = 1024  # words of the 4 KB window
HALF = 0.5  # probability of the random choices
TIMEOUT = 100  # clocks ready may take
FLUSH_LIMIT = 2000  # clocks a flush may take


async def access(  # noqa: PLR0913, PLR0917
    dut: Dut, we: bool, w: int, data: int = 0, be: int = 0xF, hold: int = 0
):
    """One core access of word w; returns (read data, clocks)."""
    drive(
        dut,
        i_addr=BASE + 4 * w,
        i_wdata=data,
        i_byteena=be,
        i_wren=int(we),
        i_rden=int(not we),
    )
    clocks = 0
    while True:
        await clock_edges(dut)
        clocks += 1
        if int(dut.o_ready.value):
            break
        check_true(clocks < TIMEOUT, "ready never came")
    for _ in range(hold):
        check_equal(int(dut.o_ready.value), 1, "ready dropped")
        await clock_edges(dut)
    await advance(dut)
    drive(dut, i_wren=0)
    return int(dut.o_rdata.value), clocks


async def flush(dut: Dut):
    """Write back every dirty line."""
    drive(dut, i_flush=1)
    await clock_edges(dut)
    drive(dut, i_flush=0)
    for _ in range(FLUSH_LIMIT):
        if int(dut.o_flush_done.value):
            return
        await clock_edges(dut)
    raise AssertionError("flush never finished")


class Mirror:
    """The expected content of the memory, zero at the start."""

    def __init__(self, dut: Dut):
        """Bind the copy to the DUT."""
        self.dut = dut
        self.mem: dict[int, int] = {}

    async def write(self, w: int, data: int, be: int = 0xF):
        """Write one word through the cache."""
        self.mem[w] = merge(self.mem.get(w, 0), data, be)
        await access(self.dut, True, w, data, be)

    async def read(self, w: int, hold: int = 0):
        """Read one word through the cache and compare it."""
        got, _ = await access(self.dut, False, w, hold=hold)
        want = self.mem.get(w, 0)
        check_equal(got, want, f"word {w:#x}: {got:#010x} != {want:#010x}")

    async def check_memory(self):
        """Check the memory behind the cache against the copy."""
        for w, v in self.mem.items():
            got = await debug_word(self.dut, w)
            check_equal(got, v, f"word {w:#x} in the memory")


@cocotb.test()
async def test_write_then_read(dut: Dut):
    """Check a word through the cache, and in the memory after flush."""
    await start(dut)
    m = Mirror(dut)
    await m.write(0x123, 0xCAFEBABE)
    await m.read(0x123)
    await flush(dut)
    check_equal(await debug_word(dut, 0x123), 0xCAFEBABE)


@cocotb.test()
async def test_byte_enables(dut: Dut):
    """Check that every mask writes exactly the enabled bytes."""
    await start(dut)
    m = Mirror(dut)
    for be in range(16):
        w = 0x20 + be
        await m.write(w, 0x11223344)
        await m.write(w, 0xA5B6C7D8, be)
        await m.read(w)
    await flush(dut)
    await m.check_memory()


@cocotb.test()
async def test_eviction_writes_back(dut: Dut):
    """Check that words that share a line keep their own content."""
    await start(dut)
    m = Mirror(dut)
    stride = CAPACITY // 4
    ws = [0x10 + k * stride for k in range(WORDS // stride)]
    for i, w in enumerate(ws):
        await m.write(w, 0x1000 + i)
    for w in ws:
        await m.read(w, hold=3)
    await flush(dut)
    await m.check_memory()


@cocotb.test()
async def test_random_traffic(dut: Dut):
    """Check random reads and writes over conflicting lines."""
    await start(dut)
    m = Mirror(dut)
    rng = Prng(11)
    stride = CAPACITY // 4
    words = [b + k * stride for b in (0, 1, 2, 3, 4, 31) for k in range(8)]
    for _ in range(300):
        w = rng.choice(words)
        if rng.random() < HALF:
            await m.write(
                w,
                rng.getrandbits(32),
                rng.choice([0xF, 0xF, 0x3, 0xC, 0x1, 0x8, 0x5]),
            )
        else:
            await m.read(w, hold=rng.choice([0, 0, 0, 2]))
    await flush(dut)
    await m.check_memory()
    for w in words:
        await m.read(w)
