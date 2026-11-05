"""The FLASH loader.

A host rewrites the single copy of the FLASH through the JTAG data
registers, only while the core is halted, and the instruction fetch and
the data port of the MEM stage read that same copy.

The testbench plays the Virtual JTAG instance: it drives the JTAG clock,
the data in, and the state flags (capture, shift, update) the way the
instance does, with a 64-bit CMD register selected by instruction 1 and
a STREAM register selected by instruction 2 (see flash_jtag_core).

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut
from tests.python.unittests.jtag import load_ir, shift_dr, tck

IF_NS = 10  # clock of the instruction fetch port
MEM_NS = 10  # clock of the MEM port and of the loader
SLOW_MEM_NS = 4000  # a loader clock slower than the stream of words
IR_CMD, IR_STREAM = 1, 2
OP_NOP, OP_HALT, OP_RUN, OP_WRITE, OP_READ, OP_SUMMARY, OP_CURSOR = range(7)
BUSY, HALTED, REFUSED, OVERRUN = 1, 2, 4, 8
INIT_WORDS = 10  # words of the file the memory starts from
WORD_MASK = 0xFFFFFFFF
PATTERN = 0x9E3779B1  # multiplier that spreads the test words


def word_at(index: int) -> int:
    """Return the test word stored at an index."""
    return (index * PATTERN + 0x1234) & WORD_MASK


async def command(dut: Dut, op: int, addr: int = 0, data: int = 0):
    """Shift one command into the CMD register.

    Returns (status, word address, data) of the previous command.

    """
    value = (op << 60) | ((addr & 0xFFFFFF) << 32) | (data & WORD_MASK)
    out = await shift_dr(dut, 64, value)
    return out >> 56, (out >> 32) & 0xFFFFFF, out & WORD_MASK


async def settle(dut: Dut):
    """Shift NOP commands until the previous command has finished.

    Returns its (status, word address, data).

    """
    status = 0
    for _ in range(200):
        status, word, data = await command(dut, OP_NOP)
        if not status & BUSY:
            return status, word, data
    raise AssertionError(f"the command never finished (status {status:#x})")


async def start(dut: Dut, mem_ns: int = MEM_NS):
    """Start the clocks and reset the loader, then select CMD."""
    dut.i_rst.value = 1
    dut.i_if_address.value = 0
    dut.i_if_rden.value = 1
    dut.i_mem_address.value = 0
    dut.i_mem_rden.value = 1
    dut.i_jtag_tdi.value = 0
    cocotb.start_soon(Clock(dut.i_clk_if, IF_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.i_clk_mem, mem_ns, unit="ns").start())
    for _ in range(4):
        await RisingEdge(dut.i_clk_mem)
    dut.i_rst.value = 0
    await load_ir(dut, IR_CMD)
    await settle(dut)


async def stored(dut: Dut, index: int) -> int:
    """Return the word of the memory model."""
    return int(dut.u_flash.mem[index].value)


async def read_if(dut: Dut, index: int) -> int:
    """Read a word by the instruction fetch port (port A)."""
    dut.i_if_address.value = index
    await RisingEdge(dut.i_clk_if)
    await Timer(1, unit="ns")
    await RisingEdge(dut.i_clk_if)
    await Timer(1, unit="ns")
    return int(dut.o_if_q.value)


async def read_mem(dut: Dut, index: int) -> int:
    """Read a word by the data port of the MEM stage (port B)."""
    dut.i_mem_address.value = index
    await RisingEdge(dut.i_clk_mem)
    await Timer(1, unit="ns")
    await RisingEdge(dut.i_clk_mem)
    await Timer(1, unit="ns")
    return int(dut.o_mem_q.value)


async def stream(dut: Dut, words: list[int], delay: int = 0) -> None:
    """Shift the words into the STREAM register in a single scan.

    The scan starts with the start bit. A delay models the hub of the
    Virtual JTAG, which shifts the data that many clocks after the
    state flags rise.

    """
    await load_ir(dut, IR_STREAM)
    value = 0
    for i, word in enumerate(words):
        value |= word << (32 * i)
    value = ((value << 1) | 1) << delay
    await shift_dr(dut, 32 * len(words) + 1 + delay, value)
    await load_ir(dut, IR_CMD)
    await settle(dut)


@cocotb.test()
async def test_both_ports_read_the_same_copy(dut: Dut):
    """The fetch port and the MEM port see the file the memory holds."""
    await start(dut)
    for index in range(INIT_WORDS):
        want = await stored(dut, index)
        check_equal(await read_if(dut, index), want, "port A")
        check_equal(await read_mem(dut, index), want, "port B")
    check_equal(int(dut.o_halt.value), 0, "the core must start running")


@cocotb.test()
async def test_write_and_read_back_with_the_core_halted(dut: Dut):
    """Words written by the host are in the memory and read back."""
    await start(dut)
    await command(dut, OP_HALT)
    status, _, _ = await settle(dut)
    check_true(status & HALTED, f"not halted (status {status:#x})")
    check_equal(int(dut.o_halt.value), 1)
    words = {0: 0x11111111, 1: 0x22222222, 0x2A5: 0xCAFEBABE, 1023: 0xDEADBEEF}
    for index, value in words.items():
        await command(dut, OP_WRITE, index, value)
        await settle(dut)
    for index, value in words.items():
        check_equal(await stored(dut, index), value, f"word {index}")
        await command(dut, OP_READ, index)
        _, word, data = await settle(dut)
        check_equal(word, index)
        check_equal(data, value, f"read back of word {index}")
    await command(dut, OP_RUN)
    status, _, _ = await settle(dut)
    check_true(not status & HALTED)
    check_equal(int(dut.o_halt.value), 0)
    for index, value in words.items():
        check_equal(await read_if(dut, index), value, "port A")
        check_equal(await read_mem(dut, index), value, "port B")


@cocotb.test()
async def test_nothing_is_written_with_the_core_running(dut: Dut):
    """A write with the core running changes nothing and is reported."""
    await start(dut)
    before = [await stored(dut, i) for i in range(INIT_WORDS)]
    status = 0
    for index in range(INIT_WORDS):
        await command(dut, OP_WRITE, index, 0xA5A5A5A5)
        status, _, _ = await settle(dut)
    check_true(status & REFUSED, f"not reported (status {status:#x})")
    check_equal([await stored(dut, i) for i in range(INIT_WORDS)], before)
    await stream(dut, [0xFFFFFFFF] * 4)
    check_equal([await stored(dut, i) for i in range(INIT_WORDS)], before)
    await command(dut, OP_READ, 3)
    status, _, _ = await settle(dut)
    check_true(status & REFUSED)
    await command(dut, OP_HALT)
    status, _, _ = await settle(dut)
    check_true(not status & REFUSED, "a halt clears the refusals")


@cocotb.test()
async def test_the_stream_writes_from_the_cursor(dut: Dut):
    """A single scan of N words lands in N consecutive words."""
    await start(dut)
    await command(dut, OP_HALT)
    await settle(dut)
    count = 200
    words = [word_at(i) for i in range(count)]
    await command(dut, OP_CURSOR, 0x40)
    await settle(dut)
    await stream(dut, words)
    for i in (0, 1, 31, 32, 33, 100, count - 1):
        check_equal(await stored(dut, 0x40 + i), words[i], f"word {i}")
    check_equal(await stored(dut, 0x40 + count), 0, "word after the image")
    check_equal(await stored(dut, 0x40 - 1), 0, "word before the image")
    # a second scan continues where the first one stopped
    await stream(dut, [0x600DF00D])
    check_equal(await stored(dut, 0x40 + count), 0x600DF00D)
    # an explicit write moves the cursor after itself
    await command(dut, OP_WRITE, 0x300, 0x0BADCAFE)
    await settle(dut)
    await stream(dut, [0xFEEDFACE])
    check_equal(await stored(dut, 0x301), 0xFEEDFACE)


@cocotb.test()
async def test_the_stream_does_not_depend_on_the_hub_delay(dut: Dut):
    """Clocks before the start bit do not move the words."""
    await start(dut)
    await command(dut, OP_HALT)
    await settle(dut)
    words = [word_at(i) for i in range(40)]
    for delay in (0, 1, 7, 31, 33):
        await command(dut, OP_CURSOR, 0x80)
        await settle(dut)
        await stream(dut, words, delay)
        for i in (0, 1, 31, 32, 39):
            check_equal(
                await stored(dut, 0x80 + i), words[i], f"{delay}: word {i}"
            )
        await command(dut, OP_WRITE, 0x80, 0)
        await settle(dut)


@cocotb.test()
async def test_the_summary_tells_a_lost_or_misplaced_word(dut: Dut):
    """The checksum and the count follow the words written."""
    await start(dut)
    await command(dut, OP_HALT)
    await settle(dut)
    count = 64
    words = [word_at(i) for i in range(count)]
    await command(dut, OP_CURSOR, 7)
    await settle(dut)
    await stream(dut, words)
    await command(dut, OP_SUMMARY)
    _, written, total = await settle(dut)
    check_equal(written, count)
    want = sum(w + 7 + i for i, w in enumerate(words)) & WORD_MASK
    check_equal(total, want, "checksum")
    await command(dut, OP_HALT)
    await command(dut, OP_SUMMARY)
    _, written, total = await settle(dut)
    check_equal((written, total), (0, 0), "a halt clears the summary")


@cocotb.test()
async def test_a_word_faster_than_the_loader_is_reported(dut: Dut):
    """A stream faster than the loader clock drops words and says so."""
    await start(dut, mem_ns=SLOW_MEM_NS)
    await command(dut, OP_HALT)
    for _ in range(20):
        await settle(dut)
    await stream(dut, [word_at(i) for i in range(8)])
    status, _, _ = await command(dut, OP_NOP)
    status, _, _ = await settle(dut)
    check_true(status & OVERRUN, f"not reported (status {status:#x})")


@cocotb.test()
async def test_the_mem_port_is_the_cores_until_the_halt(dut: Dut):
    """The MEM address reaches the memory until the core is halted."""
    await start(dut)
    for index in (1, 2, 3):
        check_equal(await read_mem(dut, index), await stored(dut, index))
    before = await stored(dut, 2)
    await command(dut, OP_HALT)
    await settle(dut)
    await command(dut, OP_WRITE, 5, 0x55555555)
    await settle(dut)
    # while halted the MEM port address is ignored, the loader's wins
    dut.i_mem_address.value = 2
    await tck(dut)
    check_equal(await stored(dut, 2), before, "the MEM address wrote")
    check_equal(await stored(dut, 5), 0x55555555)
