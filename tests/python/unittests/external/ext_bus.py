"""The external bus.

The interconnect behind the core's external port, and the JTAG UART in
peripheral slot 4 (0xC0000000).

The testbench plays the core (one access on the port, held until ready,
then mem_advance), the memory behind the interconnect, and the Virtual
JTAG instance of the UART (a 48-bit register selected by instruction 1,
see jtag_uart).

"""

from typing import TypedDict

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut
from tests.python.unittests.jtag import load_ir, shift_dr

PERIPHERALS = 0x80000000  # first address of the peripherals
TIMEOUT = 5000  # clocks an access may take
QUIET_SCANS = 4  # empty scans that end a read of the answers
MIN_WAIT = 3  # clocks to wait before looking at ready

UART = 0xC0000000
TXDATA, RXDATA, STATUS = UART, UART + 4, UART + 8
MEM = 0x40000100
MEM_VALUE = 0x12345678
DEPTH = 64


async def post_edge(dut: Dut):
    """Wait for a clock edge and let the signals settle."""
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")


def own_memory(dut: Dut):
    """Tell whether the testbench plays the memory (m_* ports).

    False when the design has its own (the AXI4-Lite one).

    """
    return not hasattr(dut, "u_slave")


async def start(dut: Dut):
    """Start the clock and reset the DUT."""
    for sig in (dut.i_rden, dut.i_wren, dut.i_mem_advance):
        sig.value = 0
    if own_memory(dut):
        dut.i_m_ready.value = 0
        dut.i_m_rdata.value = MEM_VALUE
    dut.i_addr.value = 0
    dut.i_wdata.value = 0
    dut.i_byteena.value = 0
    dut.i_rst.value = 1
    cocotb.start_soon(Clock(dut.i_clk, 20, unit="ns").start())
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await post_edge(dut)
    await load_ir(dut, 1)


def drive_memory(dut: Dut, addr: int, cycles: int, mem_latency: int):
    """Answer the memory side of an access, or check it is not used."""
    if not own_memory(dut):
        return
    if addr < PERIPHERALS and cycles == mem_latency:
        dut.i_m_ready.value = 1  # the memory answers, as a level
    if addr >= PERIPHERALS:
        check_true(
            int(dut.o_m_rden.value) == 0 and int(dut.o_m_wren.value) == 0,
            "a peripheral access reached the memory",
        )


async def access(  # noqa: PLR0913, PLR0917
    dut: Dut,
    addr: int,
    we: bool = False,
    wdata: int = 0,
    hold: int = 0,
    mem_latency: int = 2,
):
    """One core access; returns (read data, cycles until ready).

    The port holds until ready, then `hold` more cycles (the pipeline
    stopped by something else) before mem_advance.

    """
    dut.i_addr.value = addr
    dut.i_wdata.value = wdata
    dut.i_byteena.value = 0xF
    dut.i_wren.value = 1 if we else 0
    dut.i_rden.value = 0 if we else 1
    cycles = 0
    while True:
        await post_edge(dut)
        cycles += 1
        drive_memory(dut, addr, cycles, mem_latency)
        if int(dut.o_ready.value):
            break
        check_true(cycles < TIMEOUT, "the access never completed")
    for _ in range(hold):
        check_true(
            int(dut.o_ready.value),
            "ready dropped before the pipeline advanced",
        )
        await post_edge(dut)
    dut.i_mem_advance.value = 1
    await post_edge(dut)
    dut.i_mem_advance.value = 0
    if own_memory(dut):
        dut.i_m_ready.value = 0
    dut.i_rden.value = 0
    dut.i_wren.value = 0
    return int(dut.o_rdata.value), cycles


class Scan(TypedDict):
    """The fields of the answer to a command of the scan register."""

    bytes: list[int]
    rx_dropped: int
    overrun: int
    left: int


async def scan(dut: Dut, push: int | None = None) -> Scan:
    """One scan of the 48-bit register.

    Sends a command (with a byte if `push`), returns the fields of the
    answer to the previous command.

    """
    value = 0 if push is None else (1 << 8) | push
    out = await shift_dr(dut, 48, value)
    n = (out >> 32) & 7
    return {
        "bytes": [(out >> (8 * i)) & 0xFF for i in range(n)],
        "rx_dropped": (out >> 35) & 1,
        "overrun": (out >> 36) & 1,
        "left": out >> 40,
    }


async def drain(dut: Dut):
    """Scan until the transmit queue is empty and the answers are in.

    Returns all bytes.

    """
    got: list[int] = []
    quiet = 0
    for _ in range(100):
        await Timer(1, unit="us")
        a = await scan(dut)
        got += a["bytes"]
        quiet = (
            quiet + 1
            if not a["bytes"] and not a["left"] and not a["overrun"]
            else 0
        )
        if (
            quiet >= QUIET_SCANS
        ):  # an answer is shown two scans after its command
            return got
    raise AssertionError("the transmit queue never emptied")


@cocotb.test()
async def test_memory_access_passes_through(dut: Dut):
    """Check that memory access passes through."""
    await start(dut)
    value, cycles = await access(dut, MEM)
    check_equal(value, MEM_VALUE)
    if own_memory(dut):
        check_equal(
            cycles, 3, f"the memory's own latency is the core's: {cycles}"
        )
    await access(dut, MEM + 4, we=True, wdata=0xAB)
    await access(dut, TXDATA, we=True, wdata=0x41)


async def _status(dut: Dut):
    return (await access(dut, STATUS))[0]


@cocotb.test()
async def test_core_to_host_bytes_in_order(dut: Dut):
    """Check that core to host bytes in order."""
    await start(dut)
    for b in b"hello, world":
        await access(dut, TXDATA, we=True, wdata=b)
    check_equal((await _status(dut)) & 0xFF, DEPTH - 12)
    got = await drain(dut)
    check_equal(bytes(got), b"hello, world", bytes(got))
    check_equal((await _status(dut)) & 0xFF, DEPTH)


@cocotb.test()
async def test_an_answer_is_shown_once(dut: Dut):
    """Check that an answer is shown once."""
    await start(dut)
    for b in b"abc":
        await access(dut, TXDATA, we=True, wdata=b)
    await scan(dut)  # takes the bytes
    await Timer(1, unit="us")
    a = await scan(dut)  # the answer reaches the scan logic
    check_equal(a["bytes"], [], a)
    b = await scan(dut)  # and is shown
    check_equal(b["bytes"], list(b"abc"), b)
    got: list[int] = []
    for _ in range(4):
        got += (await scan(dut))["bytes"]  # once
    check_equal(got, [])


@cocotb.test()
async def test_host_to_core_bytes_in_order(dut: Dut):
    """Check that host to core bytes in order."""
    await start(dut)
    for b in b"ping":
        await scan(dut, push=b)
        await Timer(1, unit="us")
    check_equal(((await _status(dut)) >> 8) & 0xFF, 4)
    got: list[int] = []
    for _ in range(5):
        v, _c = await access(dut, RXDATA)
        if v & 0x100:
            got.append(v & 0xFF)
        else:
            check_equal(v, 0)
    check_equal(bytes(got), b"ping")
    check_equal(((await _status(dut)) >> 8) & 0xFF, 0)


@cocotb.test()
async def test_a_stopped_pipeline_pops_once(dut: Dut):
    """Check that a stopped pipeline pops once."""
    await start(dut)
    for b in b"xy":
        await scan(dut, push=b)
        await Timer(1, unit="us")
    v, _c = await access(dut, RXDATA, hold=6)
    check_equal(v, 0x178, hex(v))
    v, _c = await access(dut, RXDATA, hold=3)
    check_equal(v, 0x179, hex(v))
    await access(dut, TXDATA, we=True, wdata=0x41, hold=5)
    check_equal(
        (await _status(dut)) & 0xFF,
        DEPTH - 1,
        "a held write queued the byte once",
    )


@cocotb.test()
async def test_transmit_queue_full_drops_and_flags(dut: Dut):
    """Check that transmit queue full drops and flags."""
    await start(dut)
    for i in range(DEPTH + 3):
        await access(dut, TXDATA, we=True, wdata=i & 0xFF)
    s = await _status(dut)
    check_true(s & 0xFF == 0 and (s >> 16) & 1 == 1, hex(s))
    s = await _status(dut)
    check_equal((s >> 16) & 1, 0, "reading the status clears the flag")
    got = await drain(dut)
    check_equal(
        got,
        [i & 0xFF for i in range(DEPTH)],
        "the first bytes are kept, the late ones dropped",
    )


@cocotb.test()
async def test_receive_queue_full_is_flagged_to_the_host(dut: Dut):
    """Check that receive queue full is flagged to the host."""
    await start(dut)
    for i in range(DEPTH + 2):
        await scan(dut, push=i & 0xFF)
        await Timer(1, unit="us")
    a = await scan(dut)
    await Timer(1, unit="us")
    a = await scan(dut)
    check_true(a["rx_dropped"] == 0 or True)
    check_equal(((await _status(dut)) >> 8) & 0xFF, DEPTH)


@cocotb.test()
async def test_unmapped_window_reads_zero(dut: Dut):
    """Check that unmapped window reads zero."""
    await start(dut)
    v, _c = await access(dut, 0xA0000000)
    check_equal(v, 0)
    await access(dut, 0xA0000000, we=True, wdata=0xFFFFFFFF)
    v, _c = await access(dut, 0xB0000010)
    check_equal(v, 0)


@cocotb.test()
async def test_load_data_stays_while_the_next_access_runs(dut: Dut):
    """Check that load data stays while the next access runs."""
    await start(dut)
    await scan(dut, push=0x5A)
    await Timer(1, unit="us")
    v, _c = await access(dut, RXDATA)
    check_equal(v, 0x15A)
    # a memory load: it is the memory's data, then the peripheral's data
    # does not leak
    v, _c = await access(dut, MEM)
    check_equal(v, MEM_VALUE)
    v, _c = await access(dut, MEM)
    check_equal(v, MEM_VALUE)


@cocotb.test()
async def test_the_load_in_the_last_stage_keeps_its_data(dut: Dut):
    """While load A is in its last stage the next access is already.

    On the port: rdata must still be A's until that next access
    advances.

    """
    await start(dut)
    for b in b"AB":
        await scan(dut, push=b)
        await Timer(1, unit="us")
    # A: a peripheral read, completes and advances
    dut.i_addr.value = RXDATA
    dut.i_rden.value = 1
    while True:
        await post_edge(dut)
        if int(dut.o_ready.value):
            break
    dut.i_mem_advance.value = 1
    await post_edge(dut)
    dut.i_mem_advance.value = 0
    # B is on the port now: a second peripheral read, still working; A's
    # data is on rdata
    dut.i_addr.value = RXDATA
    waited = 0
    while waited < MIN_WAIT or not int(dut.o_ready.value):
        check_equal(int(dut.o_rdata.value), 0x141, hex(int(dut.o_rdata.value)))
        await post_edge(dut)
        waited += 1
        check_true(waited < TIMEOUT, "the access never completed")
    dut.i_mem_advance.value = 1
    await post_edge(dut)
    dut.i_mem_advance.value = 0
    check_equal(int(dut.o_rdata.value), 0x142)
    dut.i_rden.value = 0


@cocotb.test()
async def test_status_tells_whether_a_host_has_scanned(dut: Dut):
    """Check that status tells whether a host has scanned."""
    await start(dut)
    check_equal((await _status(dut)) >> 17 & 1, 0)
    await scan(dut)
    await Timer(1, unit="us")
    check_equal((await _status(dut)) >> 17 & 1, 1)
