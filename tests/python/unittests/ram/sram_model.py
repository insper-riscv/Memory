"""sram_model.

The asynchronous SRAM chip model driven pin by pin: the valid cycles pass
without a violation, the byte lanes follow LB# and UB#, and each timing or
usage rule it checks pulses o_violation when it is broken (the model runs
with abort_on_violation false here, so the test can see the pulse).

"""

import cocotb
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

T_AA, T_RC, T_WC, T_SCE, T_AW, T_PWE, T_SD = 10, 10, 10, 8, 8, 8, 6


class Counter:
    """Count the pulses of o_violation."""

    def __init__(self, dut: Dut) -> None:
        """Start watching the pulses."""
        self.count = 0
        cocotb.start_soon(self._watch(dut))

    async def _watch(self, dut: Dut) -> None:
        """Count each rising edge."""
        while True:
            await RisingEdge(dut.o_violation)
            self.count += 1


async def idle(dut: Dut):
    """Drive the pins to the idle state."""
    dut.i_sram_ce_n.value = 1
    dut.i_sram_oe_n.value = 1
    dut.i_sram_we_n.value = 1
    dut.i_sram_lb_n.value = 1
    dut.i_sram_ub_n.value = 1
    dut.i_sram_addr.value = 0
    dut.i_sram_dq.value = 0
    await Timer(50, unit="ns")


async def write(dut: Dut, addr: int, data: int, lb: int = 0, ub: int = 0, pwe: int = T_PWE, setup: int = 10):
    """One write cycle: address, data and CE# first, WE# low for pwe, then a recovery."""
    dut.i_sram_addr.value = addr
    dut.i_sram_dq.value = data
    dut.i_sram_ce_n.value = 0
    dut.i_sram_oe_n.value = 1
    dut.i_sram_lb_n.value = lb
    dut.i_sram_ub_n.value = ub
    await Timer(setup, unit="ns")
    dut.i_sram_we_n.value = 0
    await Timer(pwe, unit="ns")
    dut.i_sram_we_n.value = 1
    await Timer(5, unit="ns")
    dut.i_sram_ce_n.value = 1
    await Timer(10, unit="ns")


async def read(dut: Dut, addr: int, hold: int = T_AA, lb: int = 0, ub: int = 0) -> str:
    """Read one word, holding CE# and OE# low for hold, then release; return the word as text."""
    dut.i_sram_dq.value = "Z" * 16
    dut.i_sram_addr.value = addr
    dut.i_sram_lb_n.value = lb
    dut.i_sram_ub_n.value = ub
    dut.i_sram_ce_n.value = 0
    dut.i_sram_oe_n.value = 0
    await Timer(hold + 1, unit="ns")
    value = str(dut.o_sram_dq.value)
    dut.i_sram_oe_n.value = 1
    dut.i_sram_ce_n.value = 1
    await Timer(10, unit="ns")
    return value


@cocotb.test()
async def test_valid_cycles_have_no_violation(dut: Dut):
    """Check a write and its read back with the datasheet times, and the byte lanes."""
    counter = Counter(dut)
    await idle(dut)
    await write(dut, 0x123, 0xBEEF)
    check_equal(await read(dut, 0x123), format(0xBEEF, "016b"), "word")
    await write(dut, 0x123, 0x0012, lb=0, ub=1)
    check_equal(await read(dut, 0x123), format(0xBE12, "016b"), "low byte only")
    check_equal(await read(dut, 0x123, ub=1), "ZZZZZZZZ" + format(0x12, "08b"), "the high lane released")
    check_equal(counter.count, 0, "no violation")


@cocotb.test()
async def test_timing_violations(dut: Dut):
    """Check the access time, the write pulse, the address and data setup and the usage rules."""
    counter = Counter(dut)
    await idle(dut)
    await read(dut, 0x40, hold=T_AA - 4)
    check_equal(counter.count, 1, "read cut short")
    await write(dut, 0x41, 0x1234, pwe=T_PWE - 3)
    await Timer(2, unit="ns")
    check_equal(counter.count, 2, "short WE# pulse")
    dut.i_sram_addr.value = 0x42
    dut.i_sram_dq.value = 0x1111
    dut.i_sram_ce_n.value = 0
    dut.i_sram_oe_n.value = 1
    dut.i_sram_lb_n.value = 0
    dut.i_sram_ub_n.value = 0
    await Timer(10, unit="ns")
    dut.i_sram_we_n.value = 0
    await Timer(5, unit="ns")
    dut.i_sram_dq.value = 0x2222
    await Timer(T_SD - 3, unit="ns")
    dut.i_sram_we_n.value = 1
    await Timer(5, unit="ns")
    dut.i_sram_ce_n.value = 1
    await Timer(10, unit="ns")
    check_true(counter.count > 2, "data changed too late before WE# rises")
    n = counter.count
    dut.i_sram_dq.value = 0xFFFF
    dut.i_sram_addr.value = 0x50
    dut.i_sram_ce_n.value = 0
    dut.i_sram_oe_n.value = 0
    await Timer(30, unit="ns")
    dut.i_sram_dq.value = 0x0000
    await Timer(2, unit="ns")
    check_true(counter.count > n, "controller driving the data during a read")
