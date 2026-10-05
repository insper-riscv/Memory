"""The SDRAM bridge, controller and chip model together, as a core would use them.

The chip model fails the simulation on any broken chip rule (timings, command
order, power-up sequence, refresh interval), so a passing run also proves the
controller obeys the chip. The tests compare what a core reads with a Python
copy of the memory and, independently, with the content stored in the model.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

MEM_NS = 7                 # 142.857 MHz
CPU_NS = 56                # the core clock: the memory clock divided by 8
LAST_WORD = (1 << 24) - 1  # 64 MB of 32-bit words


async def _post_edge(dut):
    await RisingEdge(dut.clk_cpu)
    await Timer(1, unit="ns")


async def start(dut, cpu_ns=CPU_NS, cpu_offset_ns=0):
    """Clocks, reset, and wait for the controller to finish its power-up sequence."""
    for sig in (dut.rden, dut.wren, dut.mem_advance, dut.dbg_flip):
        sig.value = 0
    dut.addr.value = 0
    dut.wdata.value = 0
    dut.byteena.value = 0
    dut.dbg_word_addr.value = 0
    dut.dbg_flip_addr.value = 0
    dut.dbg_flip_bit.value = 0
    dut.rst_mem.value = 1
    dut.rst_cpu.value = 1
    cocotb.start_soon(Clock(dut.clk_mem, MEM_NS, unit="ns").start())
    if cpu_offset_ns:
        await Timer(cpu_offset_ns, unit="ns")
    cocotb.start_soon(Clock(dut.clk_cpu, cpu_ns, unit="ns").start())
    for _ in range(6):
        await RisingEdge(dut.clk_cpu)
    dut.rst_mem.value = 0
    dut.rst_cpu.value = 0
    # 200 us of power-up wait, with a margin
    for _ in range(int(2 * 200_000 / cpu_ns)):
        await _post_edge(dut)
        if int(dut.init_done.value) and int(dut.dbg_init_ok.value):
            return
    raise AssertionError("the controller never finished its power-up sequence")


async def access(dut, we, word, wdata=0, be=0xF, hold=0):
    """One core access. Returns (read data, cpu cycles until ready).

    hold: extra cpu cycles the pipeline stays stopped after ready (e.g. a muldiv),
    during which ready must stay high and the read data must not change.
    """
    dut.addr.value = 0x40000000 | (word << 2)
    dut.wdata.value = wdata
    dut.byteena.value = be
    dut.wren.value = 1 if we else 0
    dut.rden.value = 0 if we else 1
    before = int(dut.rdata.value)
    cycles = 0
    while True:
        await _post_edge(dut)
        cycles += 1
        if int(dut.ready.value):
            break
        assert cycles < 400, "ready never came"
    for _ in range(hold):
        assert int(dut.ready.value) == 1, "ready dropped before the pipeline advanced"
        assert int(dut.rdata.value) == before, "read data changed before the pipeline advanced"
        await _post_edge(dut)
    assert int(dut.ready.value) == 1
    dut.mem_advance.value = 1          # the pipeline advances on the next edge
    await _post_edge(dut)
    dut.mem_advance.value = 0
    dut.rden.value = 0
    dut.wren.value = 0
    return int(dut.rdata.value), cycles


def merge(old, new, be):
    out = old
    for i in range(4):
        if (be >> i) & 1:
            out = (out & ~(0xFF << (8 * i))) | (new & (0xFF << (8 * i)))
    return out


async def model_word(dut, word):
    """The word as stored in the chip model."""
    dut.dbg_word_addr.value = word
    for _ in range(3):
        await RisingEdge(dut.clk_mem)
    await Timer(1, unit="ns")
    return int(dut.dbg_word_data.value)


@cocotb.test()
async def test_power_up_and_first_access(dut):
    """The power-up sequence completes, and a write followed by a read returns the word."""
    await start(dut)
    assert int(dut.dbg_init_ok.value) == 1
    assert int(dut.dbg_refreshes.value) >= 8
    _, _ = await access(dut, True, 0x123456, 0xCAFEBABE)
    got, _ = await access(dut, False, 0x123456)
    assert got == 0xCAFEBABE, f"read 0x{got:08X}"
    assert await model_word(dut, 0x123456) == 0xCAFEBABE


@cocotb.test()
async def test_byte_enables(dut):
    """Every byte-enable mask writes exactly the enabled bytes."""
    await start(dut)
    base = 0x11223344
    for be in range(16):
        word = 0x000100 + be
        await access(dut, True, word, base)
        await access(dut, True, word, 0xA5B6C7D8, be)
        got, _ = await access(dut, False, word)
        want = merge(base, 0xA5B6C7D8, be)
        assert got == want, f"be={be:04b}: read 0x{got:08X}, expected 0x{want:08X}"


@cocotb.test()
async def test_address_decode(dut):
    """Distinct word addresses keep distinct values: banks, rows, columns, the first and last word."""
    await start(dut)
    rng = random.Random(1)
    words = [0, 1, 0x0FF, 0x1FF, 0x200, 0x400, 0x600, 0x7FF, 0x800, 0x1000, 0x7FFFF,
             0x800000, 0xFFFFFE, LAST_WORD]
    words += [rng.randrange(1 << 24) for _ in range(40)]
    words = sorted(set(words))
    want = {w: (0x9E3779B1 * (i + 1)) & 0xFFFFFFFF for i, w in enumerate(words)}
    for w, v in want.items():
        await access(dut, True, w, v)
    for w, v in want.items():
        got, _ = await access(dut, False, w)
        assert got == v, f"word 0x{w:06X}: read 0x{got:08X}, expected 0x{v:08X}"
        assert await model_word(dut, w) == v, f"word 0x{w:06X}: the chip holds something else"


@cocotb.test()
async def test_random_traffic(dut):
    """Random reads and writes, random byte masks, random gaps and random pipeline holds."""
    await start(dut)
    rng = random.Random(7)
    pool = [rng.randrange(1 << 24) for _ in range(48)]
    ref = {}
    for _ in range(500):
        w = rng.choice(pool)
        hold = rng.choice([0, 0, 0, 1, 3])
        if w not in ref:                       # the first write of a word is a full word
            v = rng.getrandbits(32)
            await access(dut, True, w, v, 0xF, hold)
            ref[w] = v
        elif rng.random() < 0.5:
            v, be = rng.getrandbits(32), rng.choice([0xF, 0xF, 0x3, 0xC, 0x1, 0x8, 0x6])
            await access(dut, True, w, v, be, hold)
            ref[w] = merge(ref[w], v, be)
        else:
            got, _ = await access(dut, False, w, hold=hold)
            assert got == ref[w], f"word 0x{w:06X}: read 0x{got:08X}, expected 0x{ref[w]:08X}"
        for _ in range(rng.choice([0, 0, 1, 5, 20])):
            await _post_edge(dut)
    for w, v in ref.items():
        got, _ = await access(dut, False, w)
        assert got == v


@cocotb.test()
async def test_refresh_keeps_running(dut):
    """With the bus idle for several refresh periods the controller keeps refreshing
    (the chip model fails the simulation if two refreshes are more than 7.8 us apart)."""
    await start(dut)
    before = int(dut.dbg_refreshes.value)
    for _ in range(int(60_000 / CPU_NS)):        # 60 us
        await _post_edge(dut)
    after = int(dut.dbg_refreshes.value)
    assert after - before >= 7, f"only {after - before} refreshes in 60 us"
    await access(dut, True, 0x42, 0x0BADF00D)
    got, _ = await access(dut, False, 0x42)
    assert got == 0x0BADF00D


@cocotb.test()
async def test_read_data_changes_only_when_the_pipeline_advances(dut):
    """A second read held in the stopped pipeline keeps the first read data visible."""
    await start(dut)
    await access(dut, True, 0x10, 0x11111111)
    await access(dut, True, 0x20, 0x22222222)
    first, _ = await access(dut, False, 0x10)
    assert first == 0x11111111
    second, _ = await access(dut, False, 0x20, hold=6)   # asserts rdata == first while holding
    assert second == 0x22222222


async def _ratio(dut, cpu_ns, offset):
    await start(dut, cpu_ns, offset)
    rng = random.Random(cpu_ns)
    ref = {}
    for _ in range(60):
        w = rng.randrange(1 << 24)
        v = rng.getrandbits(32)
        await access(dut, True, w, v)
        ref[w] = v
    for w, v in ref.items():
        got, _ = await access(dut, False, w)
        assert got == v, f"{cpu_ns} ns: word 0x{w:06X} read 0x{got:08X}, expected 0x{v:08X}"


@cocotb.test()
async def test_core_clock_twice_the_memory_clock_period(dut):
    """Core clock at 14 ns (the memory clock divided by 2), in phase."""
    await _ratio(dut, 14, 0)


@cocotb.test()
async def test_core_clock_unrelated_and_shifted(dut):
    """Core clock at 53 ns, shifted by 3 ns: no fixed relation to the memory clock."""
    await _ratio(dut, 53, 3)


@cocotb.test()
async def test_core_clock_slow_and_shifted(dut):
    """Core clock at 100 ns, shifted by 13 ns."""
    await _ratio(dut, 100, 13)


@cocotb.test()
async def test_a_corrupted_chip_is_noticed(dut):
    """Control for the checks above: flipping one stored bit changes exactly that bit of the read."""
    await start(dut)
    await access(dut, True, 0x777, 0x00FF00FF)
    for bit in (0, 7, 16, 31):
        dut.dbg_flip_addr.value = 0x777
        dut.dbg_flip_bit.value = bit
        dut.dbg_flip.value = 1
        await Timer(5, unit="ns")
        dut.dbg_flip.value = 0
        await Timer(5, unit="ns")
        got, _ = await access(dut, False, 0x777)
        assert got == 0x00FF00FF ^ (1 << bit), f"bit {bit}: read 0x{got:08X}"
        dut.dbg_flip.value = 1                      # put it back
        await Timer(5, unit="ns")
        dut.dbg_flip.value = 0
        await Timer(5, unit="ns")


@cocotb.test()
async def test_latency(dut):
    """The stall a core sees, in core cycles (logged, and bounded to catch a regression)."""
    await start(dut)
    _, w = await access(dut, True, 0x5, 1)
    _, r = await access(dut, False, 0x5)
    dut._log.info(f"stall: write {w} core cycles, read {r} core cycles (core clock {CPU_NS} ns)")
    assert w <= 8 and r <= 10, f"write {w}, read {r}"
