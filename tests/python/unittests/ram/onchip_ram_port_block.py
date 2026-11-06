"""onchip_ram_port, alone, with a Python model of the RAM block.

The adapter without the block RAM behind it: the testbench plays the
block (one word port with a registered read) and checks what the
adapter asks of it, the order of the words of a line, the byte enables,
the window and the debug port.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut
from tests.python.unittests.ram.ram_chip import BASE, load, store, word

WINDOW = 1 << 12  # 4 KB, the size_bytes of the entry
IDLE_DEBUG = WINDOW // 4 - 1  # index the debug port rests on
SETTLE_NS = 1  # time for the registered outputs to settle after an edge
DEBUG_CLOCKS = 6  # clocks the debug port may take to show a word


class Block:
    """The RAM block: byte enables and a registered read."""

    def __init__(self, words: int) -> None:
        """Start with a word per index that depends on the index."""
        self.mem = [word(4 * i) for i in range(words)]
        self.writes: list[tuple[int, int, int]] = []
        self.reads: list[int] = []
        self.all_reads: list[int] = []

    async def run(self, dut: Dut) -> None:
        """Sample the port at every edge, as the block does."""
        while True:
            await RisingEdge(dut.i_clk)
            addr = int(dut.o_mem_addr.value)
            if int(dut.o_mem_wren.value) == 1:
                self.write(
                    addr,
                    int(dut.o_mem_wdata.value),
                    int(dut.o_mem_byteena.value),
                )
            if int(dut.o_mem_rden.value) == 1:
                self.all_reads.append(addr)
                if addr != IDLE_DEBUG:
                    self.reads.append(addr)
                dut.i_mem_q.value = self.mem[addr]

    def write(self, addr: int, data: int, be: int) -> None:
        """Write the enabled bytes of a word and log the write."""
        self.writes.append((addr, data, be))
        for b in range(4):
            if (be >> b) & 1:
                mask = 0xFF << (8 * b)
                self.mem[addr] = (self.mem[addr] & ~mask) | (data & mask)


async def start(dut: Dut, words: int = WINDOW // 4) -> Block:
    """Start the clock and the block and reset the adapter."""
    block = Block(words)
    for name in ("i_rden", "i_wren", "i_mem_advance", "i_line"):
        getattr(dut, name).value = 0
    dut.i_rst.value = 1
    dut.i_addr.value = BASE
    dut.i_wdata.value = 0
    dut.i_byteena.value = 0xF
    dut.i_wdata_x.value = 0
    dut.i_byteena_x.value = 0xFFF
    dut.i_dbg_word_addr.value = IDLE_DEBUG
    dut.i_mem_q.value = 0
    await Timer(SETTLE_NS, unit="ns")
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    cocotb.start_soon(block.run(dut))
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    await Timer(SETTLE_NS, unit="ns")
    block.writes.clear()
    block.reads.clear()
    block.all_reads.clear()
    return block


async def debug_word(dut: Dut, index: int) -> int:
    """Read a word through the debug port and park the index again."""
    dut.i_dbg_word_addr.value = index
    for _ in range(DEBUG_CLOCKS):
        await RisingEdge(dut.i_clk)
    await Timer(SETTLE_NS, unit="ns")
    value = int(dut.o_dbg_word_data.value)
    dut.i_dbg_word_addr.value = IDLE_DEBUG
    return value


@cocotb.test()
async def test_a_word_goes_to_the_block_and_comes_back(dut: Dut):
    """Check the write and the read of one word, one access each."""
    block = await start(dut)
    await store(dut, BASE + 0x40, 0xDEADBEEF)
    check_equal(block.writes, [(0x10, 0xDEADBEEF, 0xF)])
    check_equal(block.reads, [], "a write does not read the block")
    block.writes.clear()
    value, _, _ = await load(dut, BASE + 0x40)
    check_equal(value, 0xDEADBEEF)
    check_equal(block.reads, [0x10], "a read asks for the word once")
    check_equal(block.writes, [], "a read does not write the block")


@cocotb.test()
async def test_the_byte_enables_reach_the_block(dut: Dut):
    """Check that the mask of the write is the mask of the block."""
    block = await start(dut)
    for be in range(16):
        block.writes.clear()
        await store(dut, BASE + 0x80, 0x11223344, be=be)
        check_equal(block.writes, [(0x20, 0x11223344, be)], f"{be:04b}")


@cocotb.test()
async def test_a_line_is_four_words_in_order(dut: Dut):
    """Check the four accesses of a line, with their data and masks."""
    block = await start(dut)
    words_x = 0xCCCC0003_BBBB0002_AAAA0001
    dut.i_byteena_x.value = 0x9A5
    await store(dut, BASE + 0x108, 0xDDDD0000, be=0xF, words_x=words_x)
    check_equal(
        block.writes,
        [
            (0x40, 0xDDDD0000, 0xF),
            (0x41, 0xAAAA0001, 0x5),
            (0x42, 0xBBBB0002, 0xA),
            (0x43, 0xCCCC0003, 0x9),
        ],
        "the line starts at the 16-byte boundary",
    )
    value, extra, _ = await load(dut, BASE + 0x10C, line=True)
    check_equal(block.reads, [0x40, 0x41, 0x42, 0x43])
    check_equal(value, 0xDDDD0000)
    expected = 0
    for k in range(3):
        expected |= block.mem[0x41 + k] << (32 * k)
    check_equal(extra, expected, "words 1 to 3 come from the block")
    check_equal(
        block.mem[0x41],
        (0xAAAA0001 & 0x00FF00FF) | (word(0x104) & 0xFF00FF00),
        "only the enabled bytes of word 1 changed",
    )


@cocotb.test()
async def test_the_read_data_changes_only_on_advance(dut: Dut):
    """Check that ready waits for the advance and the data with it."""
    await start(dut)
    first, _, _ = await load(dut, BASE + 0x10)
    check_equal(first, word(0x10))
    dut.i_addr.value = BASE + 0x14
    dut.i_rden.value = 1
    for _ in range(12):
        await RisingEdge(dut.i_clk)
    await Timer(SETTLE_NS, unit="ns")
    check_equal(int(dut.o_ready.value), 1)
    check_equal(int(dut.o_rdata.value), word(0x10), "the old word")
    dut.i_mem_advance.value = 1
    await RisingEdge(dut.i_clk)
    await Timer(SETTLE_NS, unit="ns")
    dut.i_mem_advance.value = 0
    dut.i_rden.value = 0
    check_equal(int(dut.o_rdata.value), word(0x14))
    check_equal(int(dut.o_ready.value), 0)


@cocotb.test()
async def test_outside_the_window_the_block_is_not_touched(dut: Dut):
    """Check that a far access reads zero and skips the block."""
    block = await start(dut)
    value, _, _ = await load(dut, BASE + WINDOW)
    check_equal(value, 0)
    await store(dut, BASE + WINDOW + 8, 0x12345678)
    value, _, _ = await load(dut, BASE + (1 << 25))
    check_equal(value, 0)
    check_equal(block.writes, [], "the store outside is dropped")
    check_equal(block.reads, [], "the read outside does not reach it")


@cocotb.test()
async def test_the_write_prevails_over_the_read(dut: Dut):
    """Check that both requests at once make a write."""
    block = await start(dut)
    dut.i_rden.value = 1
    await store(dut, BASE + 0x20, 0xA1B2C3D4)
    dut.i_rden.value = 0
    check_equal(block.writes, [(0x8, 0xA1B2C3D4, 0xF)])
    check_equal(block.reads, [])


@cocotb.test()
async def test_the_debug_port_reads_through_the_free_port(dut: Dut):
    """Check the debug port: a word, the last word and the end."""
    block = await start(dut)
    check_equal(await debug_word(dut, 5), word(20))
    check_equal(await debug_word(dut, WINDOW // 4 - 1), word(WINDOW - 4))
    check_equal(await debug_word(dut, WINDOW // 4), 0, "beyond the window")
    check_equal(await debug_word(dut, 1 << 20), 0)
    check_true(block.all_reads, "the debug read used the block")
    check_equal(block.writes, [])


@cocotb.test()
async def test_a_reset_abandons_the_access(dut: Dut):
    """Check that a reset in the middle of an access returns to idle."""
    block = await start(dut)
    dut.i_addr.value = BASE + 0x30
    dut.i_wdata.value = 0x55AA55AA
    dut.i_wren.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_rst.value = 1
    dut.i_wren.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await RisingEdge(dut.i_clk)
    await Timer(SETTLE_NS, unit="ns")
    check_equal(int(dut.o_ready.value), 0)
    block.writes.clear()
    await store(dut, BASE + 0x30, 0x01020304)
    value, _, _ = await load(dut, BASE + 0x30)
    check_equal(value, 0x01020304)
