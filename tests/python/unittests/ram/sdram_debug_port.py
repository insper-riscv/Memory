"""The SDRAM debug port.

A host reads and writes the SDRAM through the JTAG data register while a
core uses it, and what it does agrees with what the chip model stores.

The testbench plays the Virtual JTAG instance: it drives the JTAG clock,
the data in, and the state flags (capture, shift, update) the way the
instance does, with a 64-bit DEBUG register selected by instruction 1
(see sdram_jtag_core).

"""

import zlib

import cocotb
from cocotb.triggers import RisingEdge

from tests.python.unittests import jtag
from tests.python.unittests.checks import (
    Prng,
    check_equal,
    check_true,
    log_info,
)
from tests.python.unittests.dut import Dut
from tests.python.unittests.jtag import load_ir, shift_dr
from tests.python.unittests.ram.sdram_helpers import (
    access,
    addr_bits,
    merge,
    model_word,
    start,
)

ALL_ONES = 0xFFFFFFFF  # word the fill writes
SHORT_STALL = 14  # core cycles a stall may take, at most
FILL_STALL = 12  # core cycles of the stall during a fill, at most
HALF = 0.5  # probability of the random choices

OP_NOP, OP_READ, OP_WRITE, OP_FILL, OP_COUNT, OP_READ_NEXT, OP_WRITE_NEXT = (
    range(7)
)
BUSY, ERROR, INIT, OVERRUN = 1, 2, 4, 8
STREAM_ERROR, HOLD = 0x10, 0x20  # status bits above the overrun
OP_CONTROL = 7
CTRL_HOLD, CTRL_CRC, CTRL_SEEK = 0, 1, 2  # subcommands of op 7, in be
IR_DEBUG, IR_STREAM_WRITE, IR_STREAM_READ = 1, 2, 3
STREAM_WORDS = 128  # words of the largest burst
FRAME_BITS = 64  # bits of the status frame that open a stream shift
CRC_WORDS = 24  # words the CRC test covers
MAX_STALE_CYCLES = 200_000  # memory clocks a command left over may take
FAST_HALF_TCK_NS = 20  # half a period of a 24 MHz TCK
ADDR_BITS_128_MB = (
    25  # word address bits of the 32-bit chip pair of the DE2-115
)


async def debug(
    dut: Dut, op: int, addr: int = 0, data: int = 0, be: int = 0xF
):
    """Shift one command into the DEBUG register.

    Returns (status, word accessed last, data read) of the previous
    command.

    """
    value = (
        ((op | (addr >> 24 & 1) << 3) << 60)
        | (be << 56)
        | ((addr & 0xFFFFFF) << 32)
        | (data & 0xFFFFFFFF)
    )
    out = await shift_dr(dut, 64, value)
    return out >> 56, (out >> 32) & 0xFFFFFF, out & 0xFFFFFFFF


async def settle(dut: Dut):
    """Shift NOP commands until the previous command has finished.

    Returns its (status, word, data).

    """
    status = 0
    for _ in range(200):
        status, word, data = await debug(dut, OP_NOP)
        if not status & BUSY:
            return status, word, data
    d = dut.u_dbg
    raise AssertionError(
        f"the debug command never finished (status {status:#x}): "
        f"cmd_s={d.cmd_s.value} done_i={d.done_i.value} "
        f"st={d.st.value} done_s={dut.u_jtag.done_sync.value} "
        f"ir={dut.u_jtag.ir.value} sr={dut.u_jtag.sr.value} "
        f"cmd_tog={dut.u_jtag.cmd_i.value} "
        f"cmd_tog_in={d.cmd_tog.value} rst={d.rst.value}"
    )


async def read(dut: Dut, addr: int):
    """Read one word and return it."""
    await debug(dut, OP_READ, addr)
    _status, word, data = await settle(dut)
    check_equal(
        word,
        addr & 0xFFFFFF,
        f"the word accessed last is 0x{word:06X}, expected 0x{addr:06X}",
    )
    return data


async def write(dut: Dut, addr: int, value: int, be: int = 0xF):
    """Write one word."""
    await debug(dut, OP_WRITE, addr, value, be)
    await settle(dut)


async def start_debug(dut: Dut):
    """Start the clock and the debug port."""
    await start(dut)
    # The JTAG side has no reset, so the reset master runs again a
    # command the previous test left; wait for it.
    for _ in range(MAX_STALE_CYCLES):
        if int(dut.u_jtag.cmd_i.value) == int(dut.u_dbg.done_i.value):
            break
        await RisingEdge(dut.i_clk_mem)
    await load_ir(dut, 1)
    status, _, _ = await settle(dut)
    check_true(
        status & INIT,
        f"the SDRAM is not reported initialized (status {status:#x})",
    )


@cocotb.test()
async def test_write_and_read_back(dut: Dut):
    """Check words written through the debug port.

    They are in the chip and read back, byte masks included.

    """
    await start_debug(dut)
    words = {
        0x000000: 0x11111111,
        0x000001: 0x22222222,
        0x123456: 0xCAFEBABE,
        0xFFFFFF: 0xDEADBEEF,
    }
    for addr, value in words.items():
        await write(dut, addr, value)
    for addr, value in words.items():
        check_equal(await read(dut, addr), value)
        check_equal(
            await model_word(dut, addr), value, "the chip holds something else"
        )
    await write(dut, 0x123456, 0x12345678, be=0b0101)
    want = merge(0xCAFEBABE, 0x12345678, 0b0101)
    check_equal(await read(dut, 0x123456), want, "byte enables")
    check_equal(await model_word(dut, 0x123456), want)


@cocotb.test()
async def test_the_core_and_the_host_see_the_same_memory(dut: Dut):
    """What the core writes the host reads, and the other way around."""
    await start_debug(dut)
    await access(dut, True, 0x4321, 0xA5A5A5A5)
    check_equal(await read(dut, 0x4321), 0xA5A5A5A5)
    await write(dut, 0x8765, 0x0F0F0F0F)
    got, _ = await access(dut, False, 0x8765)
    check_equal(got, 0x0F0F0F0F)


@cocotb.test()
async def test_fill(dut: Dut):
    """A fill writes exactly `count` words from the address.

    Nothing else is written.

    """
    await start_debug(dut)
    await write(dut, 0x000100 - 1, 0x01010101)
    await write(dut, 0x000100 + 64, 0x02020202)
    await debug(dut, OP_COUNT, data=64)
    await debug(dut, OP_FILL, 0x000100, 0)
    await settle(dut)
    for addr in (0x100, 0x101, 0x120, 0x13F):
        check_equal(
            await read(dut, addr), 0, f"word 0x{addr:X} was not filled"
        )
    check_equal(
        await read(dut, 0x100 - 1),
        0x01010101,
        "the word before the range changed",
    )
    check_equal(
        await read(dut, 0x100 + 64),
        0x02020202,
        "the word after the range changed",
    )
    await debug(dut, OP_FILL, 0x000200, 0xFFFFFFFF)
    await settle(dut)
    check_true(
        await read(dut, 0x200) == ALL_ONES
        and await read(dut, 0x23F) == ALL_ONES
    )
    check_equal(await model_word(dut, 0x220), 0xFFFFFFFF)


@cocotb.test()
async def test_the_fill_count_reaches_the_whole_sdram(dut: Dut):
    """The count of a fill holds 2**24 words, the whole SDRAM.

    A 24-bit count would read it as 0.

    """
    await start_debug(dut)
    await debug(dut, OP_COUNT, data=1 << 24)
    await settle(dut)
    check_equal(
        int(dut.u_dbg.count.value), 1 << 24, int(dut.u_dbg.count.value)
    )
    await debug(dut, OP_COUNT, data=(1 << 24) - 1)
    await settle(dut)
    check_equal(int(dut.u_dbg.count.value), (1 << 24) - 1)


@cocotb.test()
async def test_next_word_commands(dut: Dut):
    """Read-next and write-next continue from the word accessed last."""
    await start_debug(dut)
    await write(dut, 0x3000, 0xAAAAAAAA)
    for i in range(1, 6):
        await debug(dut, OP_WRITE_NEXT, 0, 0x1000 + i)
        await settle(dut)
    await read(dut, 0x3000)
    for i in range(1, 6):
        await debug(dut, OP_READ_NEXT)
        _, word, data = await settle(dut)
        check_true(word == 0x3000 + i and data == 0x1000 + i, (word, data))


@cocotb.test()
async def test_traffic_from_the_core_and_the_host_together(dut: Dut):
    """The core and the host use the memory at the same time.

    Both get the right words.

    """
    await start_debug(dut)
    rng = Prng(3)
    core_words = {0x500000 + i * 7: rng.getrandbits(32) for i in range(40)}
    host_words = {0x600000 + i * 5: rng.getrandbits(32) for i in range(40)}

    async def host():
        for addr, value in host_words.items():
            await write(dut, addr, value)
        for addr, value in host_words.items():
            check_equal(
                await read(dut, addr), value, f"host word 0x{addr:06X}"
            )

    task = cocotb.start_soon(host())
    stalls: list[int] = []
    for addr, value in core_words.items():
        _, cycles = await access(dut, True, addr, value)
        stalls.append(cycles)
    for addr, value in core_words.items():
        got, cycles = await access(dut, False, addr)
        stalls.append(cycles)
        check_equal(got, value, f"core word 0x{addr:06X}")
    await task
    # the core never waits for more than one debug access on top of its
    # own
    check_true(
        max(stalls) <= SHORT_STALL,
        f"a core access took {max(stalls)} core cycles",
    )
    log_info(f"core stall with the host active: max {max(stalls)} core cycles")


@cocotb.test()
async def test_a_command_while_busy_is_dropped(dut: Dut):
    """A command that arrives while the previous one runs is dropped.

    It is flagged and not run.

    """
    await start_debug(dut)
    await write(dut, 0x700000, 0x13579BDF)
    await debug(dut, OP_COUNT, data=1500)
    await debug(
        dut, OP_FILL, 0x710000, 0xABABABAB
    )  # about 1500 words: busy for a while
    status, _, _ = await debug(
        dut, OP_WRITE, 0x700000, 0xFFFFFFFF
    )  # arrives while busy
    check_true(status & BUSY, "the fill should still be running")
    status, _, _ = await debug(dut, OP_NOP)
    check_true(status & OVERRUN, f"overrun not flagged (status {status:#x})")
    await settle(dut)
    check_equal(
        await read(dut, 0x700000), 0x13579BDF, "the dropped command ran"
    )
    check_equal(
        await read(dut, 0x710000 + 1499), 0xABABABAB, "the fill did not finish"
    )


@cocotb.test()
async def test_other_instructions_are_a_bypass(dut: Dut):
    """With another instruction loaded the register is a single bit.

    Nothing is sent to the memory.

    """
    await start_debug(dut)
    await write(dut, 0x800000, 0x5A5A5A5A)
    await load_ir(dut, 0)
    out = await shift_dr(dut, 8, 0b10110011)
    check_equal(out, (0b10110011 << 1) & 0xFF, f"{out:#x}")
    await load_ir(dut, 1)
    check_equal(await read(dut, 0x800000), 0x5A5A5A5A)


@cocotb.test()
async def test_the_core_is_not_starved_by_a_long_fill(dut: Dut):
    """While the host's fill keeps the debug master requesting back.

    To back, the core's accesses are served between its requests:
    correct data and a bounded stall.

    """
    await start_debug(dut)
    await debug(dut, OP_COUNT, data=3000)
    await debug(
        dut, OP_FILL, 0x900000, 0x77777777
    )  # about 3000 words, back to back
    rng = Prng(11)
    ref: dict[int, int] = {}
    stalls: list[int] = []
    for _ in range(60):
        addr = 0xA00000 + rng.randrange(256)
        if addr not in ref or rng.random() < HALF:
            value = rng.getrandbits(32)
            _, cycles = await access(dut, True, addr, value)
            ref[addr] = value
        else:
            got, cycles = await access(dut, False, addr)
            check_equal(got, ref[addr], f"core word 0x{addr:06X}")
        stalls.append(cycles)
    status, _, _ = await debug(dut, OP_NOP)
    check_true(
        status & BUSY,
        "the fill ended before the core accesses were done: lengthen it",
    )
    await settle(dut)
    check_equal(await read(dut, 0x900000 + 2999), 0x77777777)
    # one debug access in flight and then the core's own: bounded, not
    # starved
    check_true(
        max(stalls) <= FILL_STALL,
        f"a core access took {max(stalls)} core cycles during the fill",
    )
    log_info(
        f"core stall during a long fill: max {max(stalls)}, "
        f"mean {sum(stalls) / len(stalls):.1f} core cycles"
    )


@cocotb.test()
async def test_the_host_reaches_the_upper_half_of_a_128_mb_sdram(dut: Dut):
    """Bit 3 of the op is bit 24 of the word address.

    Only the 32-bit chip has the upper half; with the 16-bit chip the
    test does nothing.

    """
    if addr_bits(dut) < ADDR_BITS_128_MB:
        log_info("the chip has 2**24 words: nothing above to reach")
        return
    await start_debug(dut)
    low, high = 0x000321, (1 << 24) | 0x000321
    await write(dut, low, 0x11111111)
    await write(dut, high, 0x22222222)
    check_equal(await read(dut, low), 0x11111111, "the low half changed")
    check_equal(await read(dut, high), 0x22222222, "the upper half")
    check_equal(await model_word(dut, high), 0x22222222, "the chip")
    check_equal(await model_word(dut, low), 0x11111111, "the chip, low")
    last = (1 << 25) - 1
    await write(dut, last, 0xA5A5A5A5)
    check_equal(await read(dut, last), 0xA5A5A5A5, "the last word")
    await debug(dut, OP_READ, high)
    await settle(dut)
    await debug(dut, OP_WRITE_NEXT, 0, 0x33333333)
    await settle(dut)
    check_equal(await read(dut, high + 1), 0x33333333, "write next")


def word_crc(words: list[int]) -> int:
    """Return the CRC-32 (zlib) of words stored little-endian."""
    return zlib.crc32(b"".join(w.to_bytes(4, "little") for w in words))


async def stream_write(dut: Dut, words: list[int]) -> None:
    """Shift words into the stream register, and back to DEBUG."""
    await load_ir(dut, IR_STREAM_WRITE)
    await shift_dr(
        dut,
        32 * len(words),
        sum(w << (32 * i) for i, w in enumerate(words)),
    )
    await load_ir(dut, IR_DEBUG)


async def stream_read(dut: Dut, count: int) -> list[int]:
    """Shift `count` words out of the stream register, and back."""
    await load_ir(dut, IR_STREAM_READ)
    out = await shift_dr(dut, FRAME_BITS + 32 * count, 0)
    await load_ir(dut, IR_DEBUG)
    return [(out >> (FRAME_BITS + 32 * i)) & 0xFFFFFFFF for i in range(count)]


async def seek(dut: Dut, addr: int) -> None:
    """Point the stream at a word."""
    await debug(dut, OP_CONTROL, addr, 0, CTRL_SEEK)


@cocotb.test()
async def test_the_hold_goes_out_to_the_soc(dut: Dut):
    """Op 7 with be 0 raises o_core_hold, and the status says so."""
    await start_debug(dut)
    check_equal(int(dut.o_core_hold.value), 0, "no hold at the start")
    await debug(dut, OP_CONTROL, 0, 1, CTRL_HOLD)
    status, _, _ = await settle(dut)
    check_equal(int(dut.o_core_hold.value), 1, "hold raised")
    check_equal(status & HOLD, HOLD, "the status reports it")
    await debug(dut, OP_CONTROL, 0, 0, CTRL_HOLD)
    status, _, _ = await settle(dut)
    check_equal(int(dut.o_core_hold.value), 0, "hold dropped")
    check_equal(status & HOLD, 0, "the status drops it")


@cocotb.test()
async def test_the_crc_is_the_one_of_the_stored_bytes(dut: Dut):
    """The CRC computed on the board matches zlib over the words."""
    await start_debug(dut)
    rng = Prng(21)
    words = [rng.getrandbits(32) for _ in range(CRC_WORDS)]
    half = CRC_WORDS // 2
    for i, word in enumerate(words[:half]):
        await write(dut, 0x2000 + i, word)
    for i, word in enumerate(words[half:], half):
        await access(dut, True, 0x2000 + i, word)  # written by the core
    await debug(dut, OP_CONTROL, 0x2000, CRC_WORDS, CTRL_CRC)
    status, word, crc = await settle(dut)
    check_equal(crc, word_crc(words), f"crc {crc:08X}")
    check_equal(word, 0x2000 + CRC_WORDS - 1, "last word read")
    check_equal(status & ERROR, 0, "no error")


@cocotb.test()
async def test_a_stream_write_lands_in_the_chip(dut: Dut):
    """A burst of 1, 32 and 128 words is stored word by word."""
    await start_debug(dut)
    rng = Prng(8)
    base = 0x30000
    sent: list[int] = []
    await seek(dut, base)
    for count in (1, 32, STREAM_WORDS, 7):
        words = [rng.getrandbits(32) for _ in range(count)]
        await stream_write(dut, words)
        await settle(dut)
        sent += words
    for i in (0, 1, 32, 33, 160, len(sent) - 1):
        check_equal(await model_word(dut, base + i), sent[i], f"chip word {i}")
    status, _, _ = await debug(dut, OP_NOP)
    check_equal(status & STREAM_ERROR, 0, "no stream error")
    await debug(dut, OP_CONTROL, base, len(sent), CTRL_CRC)
    _, _, crc = await settle(dut)
    check_equal(crc, word_crc(sent), "the CRC on the board matches")


@cocotb.test()
async def test_a_stream_read_gives_back_what_was_written(dut: Dut):
    """A written image reads back through the stream, burst by burst."""
    await start_debug(dut)
    rng = Prng(13)
    base = 0x48000
    image = [rng.getrandbits(32) for _ in range(STREAM_WORDS + 40)]
    await seek(dut, base)
    await stream_write(dut, image[:STREAM_WORDS])
    await settle(dut)
    await stream_write(dut, image[STREAM_WORDS:])
    await settle(dut)
    await seek(dut, base)
    got = await stream_read(dut, STREAM_WORDS)
    got += await stream_read(dut, 40)
    check_equal(got, image, "the stream read differs from the image")
    status, _, _ = await debug(dut, OP_NOP)
    check_equal(status & STREAM_ERROR, 0, "no stream error")


async def stream_under_traffic(dut: Dut, half_tck_ns: int, seed: int) -> None:
    """Stream 128 words out and back while the core hammers memory.

    The JTAG clock has the given half period, in ns.
    """
    await start_debug(dut)
    rng = Prng(seed)
    words = [rng.getrandbits(32) for _ in range(STREAM_WORDS)]
    core_words = {0x60000 + i * 3: rng.getrandbits(32) for i in range(60)}

    async def core():
        for addr, value in core_words.items():
            await access(dut, True, addr, value)
        for addr, value in core_words.items():
            got, _ = await access(dut, False, addr)
            check_equal(got, value, f"core word 0x{addr:06X}")

    saved = jtag.HALF_TCK_NS
    jtag.HALF_TCK_NS = half_tck_ns
    try:
        task = cocotb.start_soon(core())
        await seek(dut, 0x70000)
        await stream_write(dut, words)
        await settle(dut)
        await seek(dut, 0x70000)
        got = await stream_read(dut, STREAM_WORDS)
        await task
        status, _, _ = await debug(dut, OP_NOP)
    finally:
        jtag.HALF_TCK_NS = saved
    check_equal(got, words, "the stream corrupted under traffic")
    check_equal(status & STREAM_ERROR, 0, "a word was late")


@cocotb.test()
async def test_a_stream_keeps_up_while_the_core_uses_the_memory(dut: Dut):
    """The core hammers the memory: the words still arrive in time."""
    await stream_under_traffic(dut, jtag.HALF_TCK_NS, 34)


@cocotb.test()
async def test_a_stream_reaches_the_upper_half_of_a_128_mb_sdram(dut: Dut):
    """The pointer of the stream has 25 bits."""
    if addr_bits(dut) < ADDR_BITS_128_MB:
        log_info("the chip has 2**24 words: nothing above to reach")
        return
    await start_debug(dut)
    base = (1 << 24) - 2
    words = [0x11111111, 0x22222222, 0x33333333, 0x44444444]
    await seek(dut, base)
    await stream_write(dut, words)
    await settle(dut)
    check_equal(await model_word(dut, base + 2), 0x33333333, "above 2**24")
    await seek(dut, base)
    check_equal(await stream_read(dut, 4), words)


@cocotb.test()
async def test_a_stream_keeps_up_at_the_fastest_jtag_clock(dut: Dut):
    """A 24 MHz TCK, the fastest of the USB-Blaster, still keeps up."""
    await stream_under_traffic(dut, FAST_HALF_TCK_NS, 55)
