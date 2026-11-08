"""nor_flash_model.

The NOR FLASH chip model driven pin by pin: the valid cycles pass
without a violation, and each timing or usage rule it checks pulses
o_violation when it is broken (the model runs with abort_on_violation
false here, so the test can see the pulse; with the default it ends the
simulation).

"""

import cocotb
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

T_ACC, T_PACC, T_OE = 90, 25, 35
T_WC, T_WP, T_WPH, T_DS, T_AH = 90, 35, 30, 45, 45
T_BUSY, T_RP, T_RH = 90, 500, 50
T_PROG, T_ERASE = 2000, 20000
MASK32 = 0xFFFFFFFF
SECTOR = 4096


def pattern(addr: int) -> int:
    """Return the initial byte of the chip at a byte address."""
    return ((((addr * 0x9E3779B1) & MASK32) ^ 0x5A5A1234) >> 24) & 0xFF


# Pulsos de o_violation esperados quando uma regra de tempo é violada.
MIN_PULSES = 2


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
    """Drive the pins to the idle state and finish a clean reset."""
    dut.i_fl_ce_n.value = 1
    dut.i_fl_oe_n.value = 1
    dut.i_fl_we_n.value = 1
    dut.i_fl_wp_n.value = 1
    dut.i_fl_addr.value = 0
    dut.i_fl_dq.value = 0xFF
    dut.i_fl_rst_n.value = 0
    await Timer(T_RP + 100, unit="ns")
    dut.i_fl_rst_n.value = 1
    await Timer(T_RH + 10, unit="ns")


async def reset_pulse(dut: Dut, width: int, after: int = T_RH + 10):
    """Pulse RESET# low for a width, then wait the time after."""
    dut.i_fl_rst_n.value = 0
    await Timer(width, unit="ns")
    dut.i_fl_rst_n.value = 1
    await Timer(after, unit="ns")


async def write_cycle(  # noqa: PLR0913, PLR0917
    dut: Dut,
    addr: int,
    data: int,
    wp: int = T_WP,
    ds: int = T_DS,
    wph: int = T_WPH,
    gap: int = 0,
):
    """One write cycle with WE# low for wp and high for wph."""
    dut.i_fl_ce_n.value = 0
    dut.i_fl_oe_n.value = 1
    dut.i_fl_addr.value = addr
    dut.i_fl_dq.value = data
    await Timer(max(ds - wp, 1), unit="ns")
    dut.i_fl_we_n.value = 0
    await Timer(wp, unit="ns")
    dut.i_fl_we_n.value = 1
    await Timer(wph + gap, unit="ns")


async def command(dut: Dut, steps: list[tuple[int, int]]):
    """Write a sequence of (address, data) cycles."""
    for addr, data in steps:
        await write_cycle(
            dut, addr, data, wp=T_AH, wph=max(T_WC - T_AH, T_WPH)
        )
    dut.i_fl_ce_n.value = 1
    await Timer(1, unit="ns")


PROGRAM = [(0xAAA, 0xAA), (0x555, 0x55), (0xAAA, 0xA0)]
ERASE = [
    (0xAAA, 0xAA),
    (0x555, 0x55),
    (0xAAA, 0x80),
    (0xAAA, 0xAA),
    (0x555, 0x55),
]


async def read_byte(dut: Dut, addr: int, wait: int = T_ACC) -> str:
    """Read one byte with CE# and OE# low for the wait; return text."""
    dut.i_fl_addr.value = addr
    dut.i_fl_ce_n.value = 0
    dut.i_fl_oe_n.value = 0
    await Timer(wait + 1, unit="ns")
    value = str(dut.o_fl_dq.value)
    dut.i_fl_oe_n.value = 1
    dut.i_fl_ce_n.value = 1
    await Timer(5, unit="ns")
    return value


def as_int(text: str) -> int:
    """Return a byte read as text, failing when it has unknown bits."""
    check_true(set(text) <= {"0", "1"}, f"the byte has unknown bits: {text}")
    return int(text, 2)


@cocotb.test()
async def test_a_valid_read_has_no_violation(dut: Dut):
    """Check random and page reads at exactly the access times."""
    counter = Counter(dut)
    await idle(dut)
    check_equal(
        as_int(await read_byte(dut, 0x123)), pattern(0x123), "random access"
    )
    # Inside the page the next byte comes at the page time.
    dut.i_fl_addr.value = 0x2000
    dut.i_fl_ce_n.value = 0
    dut.i_fl_oe_n.value = 0
    await Timer(T_ACC + 1, unit="ns")
    check_equal(as_int(str(dut.o_fl_dq.value)), pattern(0x2000), "first byte")
    for off in range(1, 16):
        dut.i_fl_addr.value = 0x2000 + off
        await Timer(T_PACC - 3, unit="ns")
        check_true(
            "X" in str(dut.o_fl_dq.value),
            "the byte is not valid before the page time",
        )
        await Timer(4, unit="ns")
        check_equal(
            as_int(str(dut.o_fl_dq.value)),
            pattern(0x2000 + off),
            f"page byte {off}",
        )
    dut.i_fl_oe_n.value = 1
    dut.i_fl_ce_n.value = 1
    await Timer(10, unit="ns")
    check_equal(str(dut.o_fl_dq.value), "ZZZZZZZZ", "released")
    check_equal(counter.count, 0, "no violation")


@cocotb.test()
async def test_a_read_ended_too_early_is_a_violation(dut: Dut):
    """Check the random access time, the page time and CE# release."""
    counter = Counter(dut)
    await idle(dut)
    await read_byte(dut, 0x300, wait=T_ACC - 10)
    check_equal(counter.count, 1, "random access cut short")
    dut.i_fl_addr.value = 0x400
    dut.i_fl_ce_n.value = 0
    dut.i_fl_oe_n.value = 0
    await Timer(T_ACC, unit="ns")
    dut.i_fl_addr.value = 0x401
    await Timer(T_PACC - 5, unit="ns")
    dut.i_fl_addr.value = 0x402
    await Timer(2, unit="ns")
    check_equal(counter.count, 2, "page access cut short")
    await Timer(T_PACC, unit="ns")
    dut.i_fl_oe_n.value = 1
    dut.i_fl_ce_n.value = 1
    await Timer(10, unit="ns")
    check_equal(counter.count, 2, "the rest was valid")


@cocotb.test()
async def test_program_and_erase_sequences(dut: Dut):
    """Check a byte program, RY#, the status and an erase."""
    counter = Counter(dut)
    await idle(dut)
    addr = 0x1000 + 5
    old = pattern(addr)
    await command(dut, [*PROGRAM, (addr, 0x3C)])
    await Timer(T_BUSY + 5, unit="ns")
    check_equal(int(dut.o_fl_ry.value), 0, "RY# low after t_busy")
    # The status read: bit 7 is the complement of the bit 7 of the data.
    status = as_int(await read_byte(dut, addr))
    want = 0x3C & old
    check_equal(status, (~want) & 0x80, "status")
    await Timer(T_PROG, unit="ns")
    check_equal(int(dut.o_fl_ry.value), 1, "RY# high at the end")
    check_equal(as_int(await read_byte(dut, addr)), want, "programmed byte")
    # An erase of the sector of the byte.
    await command(dut, [*ERASE, (0x1000, 0x30)])
    await Timer(T_BUSY + 5, unit="ns")
    check_equal(int(dut.o_fl_ry.value), 0, "RY# low in the erase")
    await Timer(T_ERASE, unit="ns")
    check_equal(int(dut.o_fl_ry.value), 1, "RY# high after the erase")
    check_equal(as_int(await read_byte(dut, 0x1000)), 0xFF, "erased")
    check_equal(
        as_int(await read_byte(dut, 0x1FFF)), 0xFF, "erased, last byte"
    )
    check_equal(
        as_int(await read_byte(dut, 0x2000)),
        pattern(0x2000),
        "next sector untouched",
    )
    check_equal(counter.count, 0, "no violation")


@cocotb.test()
async def test_write_timing_violations(dut: Dut):
    """Check the pulse width, high time, data setup and cycle time."""
    counter = Counter(dut)
    await idle(dut)
    await write_cycle(dut, 0xAAA, 0xAA, wp=T_WP - 10)
    await Timer(2, unit="ns")
    check_equal(counter.count, 1, "short WE# pulse")
    await reset_pulse(dut, T_RP + 50)
    dut.i_fl_dq.value = 0
    await Timer(100, unit="ns")
    await write_cycle(dut, 0xAAA, 0xAA, ds=20)
    check_true(counter.count >= MIN_PULSES, "short data setup")
    n = counter.count
    await reset_pulse(dut, T_RP + 50)
    await write_cycle(dut, 0xAAA, 0xAA, wph=10)
    await write_cycle(dut, 0x555, 0x55)
    check_true(counter.count > n, "cycle shorter than t_wc")


@cocotb.test()
async def test_usage_violations(dut: Dut):
    """Check the sequence, the operation in progress and the reset."""
    counter = Counter(dut)
    await idle(dut)
    n = counter.count
    await command(dut, [(0x123, 0x55)])
    check_true(counter.count > n, "cycle out of sequence")
    await reset_pulse(dut, T_RP + 50)
    n = counter.count
    await command(dut, [*PROGRAM, (0x40, 0x00)])
    await Timer(T_BUSY + 5, unit="ns")
    await command(dut, [(0xAAA, 0xAA)])
    check_true(counter.count > n, "command during the operation")
    await Timer(T_PROG, unit="ns")
    n = counter.count
    dut.i_fl_ce_n.value = 0
    dut.i_fl_oe_n.value = 0
    await Timer(1, unit="ns")
    dut.i_fl_we_n.value = 0
    await Timer(T_WP, unit="ns")
    dut.i_fl_we_n.value = 1
    dut.i_fl_oe_n.value = 1
    dut.i_fl_ce_n.value = 1
    await Timer(T_WC, unit="ns")
    check_true(counter.count > n, "WE# and OE# low together")
    n = counter.count
    await reset_pulse(dut, T_RP - 100)
    check_true(counter.count > n, "short RESET# pulse")
    n = counter.count
    await reset_pulse(dut, T_RP + 10, T_RH - 20)
    dut.i_fl_ce_n.value = 0
    await Timer(1, unit="ns")
    dut.i_fl_ce_n.value = 1
    check_true(counter.count > n, "CE# before t_rh")
