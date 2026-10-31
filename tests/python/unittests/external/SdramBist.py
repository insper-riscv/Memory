"""The SDRAM self test on the controller and the chip model.

The chip model fails the simulation on any broken chip rule, so a passing run also
proves the controller obeys the chip. The control test flips a stored bit and the
self test has to find it.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

WINDOW = 1 << 8
SWEEP = 1 << 10
RANDOM = 1 << 8


async def start(dut):
    dut.rst.value = 1
    dut.start.value = 0
    dut.mode.value = 0
    dut.dbg_word_addr.value = 0
    dut.dbg_flip.value = 0
    dut.dbg_flip_addr.value = 0
    dut.dbg_flip_bit.value = 0
    cocotb.start_soon(Clock(dut.clk, 7, unit="ns").start())
    for _ in range(6):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    for _ in range(40_000):                        # 200 us of power-up wait
        await RisingEdge(dut.clk)
        if int(dut.init_done.value):
            break
    else:
        raise AssertionError("the controller never finished its power-up sequence")
    for _ in range(4):
        await RisingEdge(dut.clk)


async def run(dut, mode, on_phase=None, limit=2_000_000):
    """Start a run and wait for it to finish; on_phase(phase) is called at each clock."""
    dut.mode.value = mode
    dut.start.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.start.value = 0
    for _ in range(limit):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        if on_phase:
            await on_phase(int(dut.phase.value))
        if int(dut.done.value) and not int(dut.busy.value):
            return
    raise AssertionError("the run never finished")


def result(dut):
    return {
        "fail": int(dut.fail.value),
        "timeout": int(dut.timeout.value),
        "errors": int(dut.err_count.value),
        "ops": int(dut.ops_done.value),
    }


async def _passes(dut, mode, ops):
    await start(dut)
    await run(dut, mode)
    r = result(dut)
    assert r["fail"] == 0 and r["errors"] == 0 and r["timeout"] == 0, r
    assert r["ops"] == ops, f"{r['ops']} words moved, expected {ops}"


@cocotb.test()
async def test_quick_with_byte_masks(dut):
    """Mode 0: 7 phases of one window."""
    await _passes(dut, 0, 7 * WINDOW)


@cocotb.test()
async def test_patterns(dut):
    """Mode 1: eight patterns, each written and read back."""
    await _passes(dut, 1, 16 * WINDOW)


@cocotb.test()
async def test_sweep(dut):
    """Mode 2: address data and its complement over the swept range."""
    await _passes(dut, 2, 4 * SWEEP)


@cocotb.test()
async def test_random_addresses(dut):
    """Mode 3: pseudo-random addresses, written and read back."""
    await _passes(dut, 3, 2 * RANDOM)


@cocotb.test()
async def test_a_flipped_bit_is_found(dut):
    """Control: a bit flipped in the chip between the write and the read is reported
    with its address and the exact bit."""
    await start(dut)
    flipped = False

    async def on_phase(phase):
        nonlocal flipped
        if phase == 2 and not flipped:             # the first read pass, right at its start
            flipped = True
            dut.dbg_flip_addr.value = 0x23
            dut.dbg_flip_bit.value = 5
            dut.dbg_flip.value = 1
            await Timer(5, unit="ns")
            dut.dbg_flip.value = 0

    await run(dut, 0, on_phase)
    r = result(dut)
    assert flipped and r["fail"] == 1, r
    assert r["errors"] >= 1, r
    assert int(dut.first_addr.value) == 0x23, hex(int(dut.first_addr.value))
    assert int(dut.first_exp.value) ^ int(dut.first_got.value) == 1 << 5
