"""The display register.

The seven-segment pattern of each digit, the core's access to it, and
the host's access through the Virtual JTAG instance (a 25-bit register
selected by instruction 1, and the 2-bit failure flag selected by
instruction 2).

The testbench plays the core (one pulse of we or re) and the instance
(it drives the JTAG states).

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import Prng, check_equal
from tests.python.unittests.dut import Dut

HALF_TCK_NS = 40
# segments g..a of each hexadecimal digit, low level lit (the DE0-CV)
PATTERNS = [
    0b1000000,
    0b1111001,
    0b0100100,
    0b0110000,
    0b0011001,
    0b0010010,
    0b0000010,
    0b1111000,
    0b0000000,
    0b0010000,
    0b0001000,
    0b0000011,
    0b1000110,
    0b0100001,
    0b0000110,
    0b0001110,
]


def expected_hex(value: int) -> int:
    """Return the segment pattern expected for a value."""
    out = 0
    for n in range(6):
        out |= PATTERNS[(value >> (4 * n)) & 0xF] << (7 * n)
    return out


async def post_edge(dut: Dut):
    """Wait for a clock edge and let the signals settle."""
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")


async def start(dut: Dut):
    """Start the clock and reset the DUT."""
    for sig in (
        dut.i_we,
        dut.i_re,
        dut.i_state_cdr,
        dut.i_state_sdr,
        dut.i_state_udr,
        dut.i_state_uir,
    ):
        sig.value = 0
    dut.i_addr.value = 0
    dut.i_wdata.value = 0
    dut.i_tck.value = 0
    dut.i_tdi.value = 0
    dut.i_ir_in.value = 0
    dut.i_rst.value = 1
    cocotb.start_soon(Clock(dut.i_clk, 20, unit="ns").start())
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await post_edge(dut)
    await tck(dut, ir=1)


async def core_write(dut: Dut, value: int, addr: int = 0):
    """Write a value from the core side."""
    dut.i_addr.value = addr
    dut.i_wdata.value = value
    dut.i_we.value = 1
    await post_edge(dut)
    dut.i_we.value = 0
    await post_edge(dut)


async def core_read(dut: Dut, addr: int = 0):
    """Read a value from the core side."""
    dut.i_addr.value = addr
    dut.i_re.value = 1
    await Timer(1, unit="ns")
    value = int(dut.o_rdata.value)
    await post_edge(dut)
    dut.i_re.value = 0
    return value


async def tck(  # noqa: PLR0913, PLR0917
    dut: Dut,
    cdr: int = 0,
    sdr: int = 0,
    udr: int = 0,
    uir: int = 0,
    ir: int | None = None,
):
    """Give one TCK pulse with the given scan states."""
    if ir is not None:
        dut.i_ir_in.value = ir
        uir = 1
    dut.i_state_cdr.value, dut.i_state_sdr.value = cdr, sdr
    dut.i_state_udr.value, dut.i_state_uir.value = udr, uir
    dut.i_tck.value = 0
    await Timer(HALF_TCK_NS, unit="ns")
    dut.i_tck.value = 1
    await Timer(HALF_TCK_NS, unit="ns")
    dut.i_tck.value = 0
    for sig in (
        dut.i_state_cdr,
        dut.i_state_sdr,
        dut.i_state_udr,
        dut.i_state_uir,
    ):
        sig.value = 0


async def scan(dut: Dut, value: int | None = None):
    """One scan of the 25-bit register.

    Writes `value` if given, returns the value read at the start.

    """
    word = 0 if value is None else (1 << 24) | value
    await tck(dut, cdr=1)
    out = 0
    for i in range(25):
        dut.i_tdi.value = (word >> i) & 1
        await Timer(1, unit="ns")
        out |= int(dut.o_tdo.value) << i
        await tck(dut, sdr=1)
    await tck(dut, udr=1)
    return out & 0xFFFFFF


async def scan_fail(dut: Dut, value: int | None = None):
    """One scan of the 2-bit failure register (instruction 2).

    Writes `value` if given, returns the flag read.

    """
    await tck(dut, ir=2)
    word = 0 if value is None else 2 | int(value)
    await tck(dut, cdr=1)
    out = 0
    for i in range(2):
        dut.i_tdi.value = (word >> i) & 1
        await Timer(1, unit="ns")
        out |= int(dut.o_tdo.value) << i
        await tck(dut, sdr=1)
    await tck(dut, udr=1)
    await tck(dut, ir=1)
    return out & 1


@cocotb.test()
async def test_every_digit_pattern(dut: Dut):
    """Check that every digit pattern."""
    await start(dut)
    for digit in range(16):
        await core_write(dut, digit * 0x111111)
        check_equal(
            int(dut.o_hex.value),
            expected_hex(digit * 0x111111),
            f"digit {digit:X}",
        )


@cocotb.test()
async def test_each_digit_is_its_own_position(dut: Dut):
    """Check that each digit is its own position."""
    await start(dut)
    await core_write(dut, 0x123456)
    check_equal(int(dut.o_hex.value), expected_hex(0x123456))
    check_equal(int(dut.o_value.value), 0x123456)


@cocotb.test()
async def test_core_write_and_read_back(dut: Dut):
    """Check that core write and read back."""
    await start(dut)
    check_equal(await core_read(dut), 0)
    await core_write(dut, 0xFFABCDEF)
    check_equal(
        await core_read(dut), 0xABCDEF, "only the 24 low bits are kept"
    )
    check_equal(await core_read(dut, addr=1), 0, "other words read zero")
    await core_write(dut, 0x777777, addr=1)
    check_equal(
        await core_read(dut), 0xABCDEF, "a write to another word is ignored"
    )


@cocotb.test()
async def test_host_write_and_read(dut: Dut):
    """Check that host write and read."""
    await start(dut)
    check_equal(await scan(dut, 0x00000F), 0)
    for _ in range(6):
        await post_edge(dut)
    check_equal(int(dut.o_value.value), 0x00000F)
    check_equal(await core_read(dut), 0x00000F)
    check_equal(
        await scan(dut), 0x00000F, "a scan without the write bit only reads"
    )
    for _ in range(6):
        await post_edge(dut)
    check_equal(int(dut.o_value.value), 0x00000F)


@cocotb.test()
async def test_host_sees_the_core_write(dut: Dut):
    """Check that host sees the core write."""
    await start(dut)
    await core_write(dut, 0x5A5A5A)
    check_equal(await scan(dut), 0x5A5A5A)


@cocotb.test()
async def test_the_value_survives_a_program_reset_not_the_hardware_reset(
    dut: Dut,
):
    """Check that the value survives a program reset.

    It does not survive the hardware reset.

    """
    await start(dut)
    await core_write(dut, 0x00AB01)
    for _ in range(10):
        await post_edge(dut)
    check_equal(
        int(dut.o_value.value),
        0x00AB01,
        "the display keeps the value between two programs",
    )
    dut.i_rst.value = 1
    await post_edge(dut)
    dut.i_rst.value = 0
    await post_edge(dut)
    check_equal(int(dut.o_value.value), 0, "the reset clears it")


@cocotb.test()
async def test_a_thousand_writes_read_back_without_a_difference(dut: Dut):
    """Check that a thousand writes read back without a difference."""
    await start(dut)
    rng = Prng(7)
    for i in range(1000):
        value = rng.getrandbits(24)
        if i % 2:
            await core_write(dut, value)
        else:
            await scan(dut, value)
            for _ in range(6):
                await post_edge(dut)
        check_equal(int(dut.o_value.value), value)
        check_equal(await scan(dut), value, f"scan {i}")
        check_equal(await core_read(dut), value)


@cocotb.test()
async def test_failure_flag_starts_clear_and_the_host_sets_and_clears_it(
    dut: Dut,
):
    """Check that the failure flag starts clear.

    The host sets it and clears it.

    """
    await start(dut)
    check_equal(int(dut.o_fail.value), 0)
    check_equal(await scan_fail(dut), 0)
    check_equal(
        await scan_fail(dut, True), 0, "the scan returns the flag as it was"
    )
    check_equal(int(dut.o_fail.value), 1)
    check_equal(
        await scan_fail(dut), 1, "a scan without the write bit only reads"
    )
    check_equal(int(dut.o_fail.value), 1)
    check_equal(await scan_fail(dut, False), 1)
    check_equal(int(dut.o_fail.value), 0)


@cocotb.test()
async def test_failure_flag_is_independent_of_the_value_and_the_reset(
    dut: Dut,
):
    """Check that the failure flag is independent of the value.

    It is also independent of the reset.

    """
    await start(dut)
    await scan_fail(dut, True)
    await core_write(dut, 0x123456)
    check_equal(int(dut.o_fail.value), 1, "a display write leaves the flag")
    check_equal(await scan(dut, 0xABCDEF), 0x123456)
    for _ in range(6):
        await post_edge(dut)
    check_equal(int(dut.o_fail.value), 1, "a value scan leaves the flag")
    dut.i_rst.value = 1
    await post_edge(dut)
    dut.i_rst.value = 0
    await post_edge(dut)
    check_equal(int(dut.o_value.value), 0)
    check_equal(
        int(dut.o_fail.value), 1, "the core reset does not clear the flag"
    )
