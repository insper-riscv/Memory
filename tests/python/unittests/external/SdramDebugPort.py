"""The SDRAM debug port: a host reads and writes the SDRAM through the JTAG data register
while a core uses it, and what it does agrees with what the chip model stores.

The testbench plays the Virtual JTAG instance: it drives the JTAG clock, the data in, and
the state flags (capture, shift, update) the way the instance does, with a 64-bit DEBUG
register selected by instruction 1 (see sdram_jtag_core).
"""

import random

import cocotb
from cocotb.triggers import Timer

from tests.python.unittests.external.sdram_helpers import (
    CPU_NS, _post_edge, access, merge, model_word, start,
)

OP_NOP, OP_READ, OP_WRITE, OP_FILL, OP_COUNT, OP_READ_NEXT, OP_WRITE_NEXT = range(7)
BUSY, ERROR, INIT, OVERRUN = 1, 2, 4, 8
HALF_TCK_NS = 40


async def tck(dut, **states):
    """One JTAG clock with the given state flags (cdr, sdr, udr, uir) high."""
    for name in ("cdr", "sdr", "udr", "uir"):
        getattr(dut, f"jtag_state_{name}").value = 1 if states.get(name) else 0
    dut.jtag_tck.value = 0
    await Timer(HALF_TCK_NS, unit="ns")
    dut.jtag_tck.value = 1
    await Timer(HALF_TCK_NS, unit="ns")
    dut.jtag_tck.value = 0
    for name in ("cdr", "sdr", "udr", "uir"):
        getattr(dut, f"jtag_state_{name}").value = 0


async def load_ir(dut, value):
    dut.jtag_ir_in.value = value
    await tck(dut, uir=True)


async def shift_dr(dut, length, value):
    """Capture, shift `length` bits (LSB first) and update; returns the bits shifted out."""
    await tck(dut, cdr=True)
    out = 0
    for i in range(length):
        dut.jtag_tdi.value = (value >> i) & 1
        await Timer(1, unit="ns")
        out |= int(dut.jtag_tdo.value) << i
        await tck(dut, sdr=True)
    await tck(dut, udr=True)
    return out


async def debug(dut, op, addr=0, data=0, be=0xF):
    """Shift one command into the DEBUG register; returns (status, word accessed last, data read)
    of the previous command."""
    value = (op << 60) | (be << 56) | ((addr & 0xFFFFFF) << 32) | (data & 0xFFFFFFFF)
    out = await shift_dr(dut, 64, value)
    return out >> 56, (out >> 32) & 0xFFFFFF, out & 0xFFFFFFFF


async def settle(dut):
    """Shift NOP commands until the previous command has finished; returns its (status, word, data)."""
    for _ in range(200):
        status, word, data = await debug(dut, OP_NOP)
        if not status & BUSY:
            return status, word, data
    d = dut.u_dbg
    raise AssertionError(
        f"the debug command never finished (status {status:#x}): cmd_s={d.cmd_s.value} done_i={d.done_i.value} "
        f"st={d.st.value} done_s={dut.u_jtag.done_s.value} ir={dut.u_jtag.ir.value} sr={dut.u_jtag.sr.value} cmd_tog={dut.u_jtag.cmd_i.value} cmd_tog_in={d.cmd_tog.value} rst={d.rst.value}"
    )


async def read(dut, addr):
    await debug(dut, OP_READ, addr)
    status, word, data = await settle(dut)
    assert word == addr, f"the word accessed last is 0x{word:06X}, expected 0x{addr:06X}"
    return data


async def write(dut, addr, value, be=0xF):
    await debug(dut, OP_WRITE, addr, value, be)
    await settle(dut)


async def start_debug(dut):
    await start(dut)
    await load_ir(dut, 1)
    status, _, _ = await settle(dut)
    assert status & INIT, f"the SDRAM is not reported initialized (status {status:#x})"


@cocotb.test()
async def test_write_and_read_back(dut):
    """Words written through the debug port are in the chip and read back, byte masks included."""
    await start_debug(dut)
    words = {0x000000: 0x11111111, 0x000001: 0x22222222, 0x123456: 0xCAFEBABE, 0xFFFFFF: 0xDEADBEEF}
    for addr, value in words.items():
        await write(dut, addr, value)
    for addr, value in words.items():
        assert await read(dut, addr) == value
        assert await model_word(dut, addr) == value, "the chip holds something else"
    await write(dut, 0x123456, 0x12345678, be=0b0101)
    want = merge(0xCAFEBABE, 0x12345678, 0b0101)
    assert await read(dut, 0x123456) == want, "byte enables"
    assert await model_word(dut, 0x123456) == want


@cocotb.test()
async def test_the_core_and_the_host_see_the_same_memory(dut):
    """What the core writes the host reads, and the other way around."""
    await start_debug(dut)
    await access(dut, True, 0x4321, 0xA5A5A5A5)
    assert await read(dut, 0x4321) == 0xA5A5A5A5
    await write(dut, 0x8765, 0x0F0F0F0F)
    got, _ = await access(dut, False, 0x8765)
    assert got == 0x0F0F0F0F


@cocotb.test()
async def test_fill(dut):
    """A fill writes exactly `count` words from the address, and nothing else."""
    await start_debug(dut)
    await write(dut, 0x000100 - 1, 0x01010101)
    await write(dut, 0x000100 + 64, 0x02020202)
    await debug(dut, OP_COUNT, data=64)
    await debug(dut, OP_FILL, 0x000100, 0)
    await settle(dut)
    for addr in (0x100, 0x101, 0x120, 0x13F):
        assert await read(dut, addr) == 0, f"word 0x{addr:X} was not filled"
    assert await read(dut, 0x100 - 1) == 0x01010101, "the word before the range changed"
    assert await read(dut, 0x100 + 64) == 0x02020202, "the word after the range changed"
    await debug(dut, OP_FILL, 0x000200, 0xFFFFFFFF)
    await settle(dut)
    assert await read(dut, 0x200) == 0xFFFFFFFF and await read(dut, 0x23F) == 0xFFFFFFFF
    assert await model_word(dut, 0x220) == 0xFFFFFFFF


@cocotb.test()
async def test_next_word_commands(dut):
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
        assert word == 0x3000 + i and data == 0x1000 + i, (word, data)


@cocotb.test()
async def test_traffic_from_the_core_and_the_host_together(dut):
    """The core and the host use the memory at the same time; both get the right words."""
    await start_debug(dut)
    rng = random.Random(3)
    core_words = {0x500000 + i * 7: rng.getrandbits(32) for i in range(40)}
    host_words = {0x600000 + i * 5: rng.getrandbits(32) for i in range(40)}

    async def host():
        for addr, value in host_words.items():
            await write(dut, addr, value)
        for addr, value in host_words.items():
            assert await read(dut, addr) == value, f"host word 0x{addr:06X}"

    task = cocotb.start_soon(host())
    stalls = []
    for addr, value in core_words.items():
        _, cycles = await access(dut, True, addr, value)
        stalls.append(cycles)
    for addr, value in core_words.items():
        got, cycles = await access(dut, False, addr)
        stalls.append(cycles)
        assert got == value, f"core word 0x{addr:06X}"
    await task
    # the core never waits for more than one debug access on top of its own
    assert max(stalls) <= 14, f"a core access took {max(stalls)} core cycles"
    dut._log.info(f"core stall with the host active: max {max(stalls)} core cycles")


@cocotb.test()
async def test_a_command_while_busy_is_dropped(dut):
    """A command that arrives while the previous one runs is dropped and flagged, not run."""
    await start_debug(dut)
    await write(dut, 0x700000, 0x13579BDF)
    await debug(dut, OP_COUNT, data=1500)
    await debug(dut, OP_FILL, 0x710000, 0xABABABAB)       # about 1500 words: busy for a while
    status, _, _ = await debug(dut, OP_WRITE, 0x700000, 0xFFFFFFFF)  # arrives while busy
    assert status & BUSY, "the fill should still be running"
    status, _, _ = await debug(dut, OP_NOP)
    assert status & OVERRUN, f"overrun not flagged (status {status:#x})"
    await settle(dut)
    assert await read(dut, 0x700000) == 0x13579BDF, "the dropped command ran"
    assert await read(dut, 0x710000 + 1499) == 0xABABABAB, "the fill did not finish"


@cocotb.test()
async def test_other_instructions_are_a_bypass(dut):
    """With another instruction loaded the register is a single bit: nothing is sent to the memory."""
    await start_debug(dut)
    await write(dut, 0x800000, 0x5A5A5A5A)
    await load_ir(dut, 0)
    out = await shift_dr(dut, 8, 0b10110011)
    assert out == (0b10110011 << 1) & 0xFF, f"{out:#x}"
    await load_ir(dut, 1)
    assert await read(dut, 0x800000) == 0x5A5A5A5A


@cocotb.test()
async def test_the_core_is_not_starved_by_a_long_fill(dut):
    """While the host's fill keeps the debug master requesting back to back, the core's accesses
    are served between its requests: correct data and a bounded stall."""
    await start_debug(dut)
    await debug(dut, OP_COUNT, data=3000)
    await debug(dut, OP_FILL, 0x900000, 0x77777777)        # about 3000 words, back to back
    rng = random.Random(11)
    ref, stalls = {}, []
    for _ in range(60):
        addr = 0xA00000 + rng.randrange(256)
        if addr not in ref or rng.random() < 0.5:
            value = rng.getrandbits(32)
            _, cycles = await access(dut, True, addr, value)
            ref[addr] = value
        else:
            got, cycles = await access(dut, False, addr)
            assert got == ref[addr], f"core word 0x{addr:06X}"
        stalls.append(cycles)
    status, _, _ = await debug(dut, OP_NOP)
    assert status & BUSY, "the fill ended before the core accesses were done: lengthen it"
    await settle(dut)
    assert await read(dut, 0x900000 + 2999) == 0x77777777
    # one debug access in flight and then the core's own: bounded, not starved
    assert max(stalls) <= 12, f"a core access took {max(stalls)} core cycles during the fill"
    dut._log.info(f"core stall during a long fill: max {max(stalls)}, mean {sum(stalls) / len(stalls):.1f} core cycles")
