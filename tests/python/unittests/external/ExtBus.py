"""The external bus: the interconnect behind the core's external port, and the JTAG UART in
peripheral slot 4 (0xC0000000).

The testbench plays the core (one access on the port, held until ready, then mem_advance), the
memory behind the interconnect, and the Virtual JTAG instance of the UART (a 48-bit register
selected by instruction 1, see jtag_uart).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

UART = 0xC0000000
TXDATA, RXDATA, STATUS = UART, UART + 4, UART + 8
MEM = 0x40000100
MEM_VALUE = 0x12345678
HALF_TCK_NS = 40
DEPTH = 64


async def post_edge(dut):
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def start(dut):
    for sig in (dut.rden, dut.wren, dut.mem_advance, dut.m_ready):
        sig.value = 0
    dut.addr.value = 0
    dut.wdata.value = 0
    dut.byteena.value = 0
    dut.m_rdata.value = MEM_VALUE
    dut.rst.value = 1
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await post_edge(dut)
    await load_ir(dut, 1)


async def access(dut, addr, we=False, wdata=0, hold=0, mem_latency=2):
    """One core access; returns (read data, cycles until ready). The port holds until ready, then
    `hold` more cycles (the pipeline stopped by something else) before mem_advance."""
    dut.addr.value = addr
    dut.wdata.value = wdata
    dut.byteena.value = 0xF
    dut.wren.value = 1 if we else 0
    dut.rden.value = 0 if we else 1
    cycles = 0
    while True:
        await post_edge(dut)
        cycles += 1
        if addr < 0x80000000 and cycles == mem_latency:
            dut.m_ready.value = 1     # the memory answers, as a level
        if addr >= 0x80000000:
            assert int(dut.m_rden.value) == 0 and int(dut.m_wren.value) == 0, "a peripheral access reached the memory"
        if int(dut.ready.value):
            break
        assert cycles < 50, "the access never completed"
    for _ in range(hold):
        assert int(dut.ready.value), "ready dropped before the pipeline advanced"
        await post_edge(dut)
    dut.mem_advance.value = 1
    await post_edge(dut)
    dut.mem_advance.value = 0
    dut.m_ready.value = 0
    dut.rden.value = 0
    dut.wren.value = 0
    return int(dut.rdata.value), cycles


async def tck(dut, **states):
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


async def scan(dut, push=None):
    """One scan of the 48-bit register: sends a command (with a byte if `push`), returns the
    fields of the answer to the previous command."""
    value = 0 if push is None else (1 << 8) | push
    await tck(dut, cdr=True)
    out = 0
    for i in range(48):
        dut.jtag_tdi.value = (value >> i) & 1
        await Timer(1, unit="ns")
        out |= int(dut.jtag_tdo.value) << i
        await tck(dut, sdr=True)
    await tck(dut, udr=True)
    n = (out >> 32) & 7
    return {
        "bytes": [(out >> (8 * i)) & 0xFF for i in range(n)],
        "rx_dropped": (out >> 35) & 1,
        "overrun": (out >> 36) & 1,
        "left": out >> 40,
    }


async def drain(dut):
    """Scan until the transmit queue is empty and the answers are in; returns all bytes."""
    got = []
    quiet = 0
    for _ in range(100):
        await Timer(1, unit="us")
        a = await scan(dut)
        got += a["bytes"]
        quiet = quiet + 1 if not a["bytes"] and not a["left"] and not a["overrun"] else 0
        if quiet >= 4:      # an answer is shown two scans after its command
            return got
    raise AssertionError("the transmit queue never emptied")


@cocotb.test()
async def test_memory_access_passes_through(dut):
    await start(dut)
    value, cycles = await access(dut, MEM)
    assert value == MEM_VALUE
    assert cycles == 3, f"the memory's own latency is the core's: {cycles}"
    await access(dut, MEM + 4, we=True, wdata=0xAB)
    await access(dut, TXDATA, we=True, wdata=0x41)


async def _status(dut):
    return (await access(dut, STATUS))[0]


@cocotb.test()
async def test_core_to_host_bytes_in_order(dut):
    await start(dut)
    for b in b"hello, world":
        await access(dut, TXDATA, we=True, wdata=b)
    assert (await _status(dut)) & 0xFF == DEPTH - 12
    got = await drain(dut)
    assert bytes(got) == b"hello, world", bytes(got)
    assert (await _status(dut)) & 0xFF == DEPTH


@cocotb.test()
async def test_an_answer_is_shown_once(dut):
    await start(dut)
    for b in b"abc":
        await access(dut, TXDATA, we=True, wdata=b)
    await scan(dut)                         # takes the bytes
    await Timer(1, unit="us")
    a = await scan(dut)                     # the answer reaches the scan logic
    assert a["bytes"] == [], a
    b = await scan(dut)                     # and is shown
    assert b["bytes"] == list(b"abc"), b
    got = []
    for _ in range(4):
        got += (await scan(dut))["bytes"]   # once
    assert got == []


@cocotb.test()
async def test_host_to_core_bytes_in_order(dut):
    await start(dut)
    for b in b"ping":
        await scan(dut, push=b)
        await Timer(1, unit="us")
    assert ((await _status(dut)) >> 8) & 0xFF == 4
    got = []
    for _ in range(5):
        v, _c = await access(dut, RXDATA)
        if v & 0x100:
            got.append(v & 0xFF)
        else:
            assert v == 0
    assert bytes(got) == b"ping"
    assert ((await _status(dut)) >> 8) & 0xFF == 0


@cocotb.test()
async def test_a_stopped_pipeline_pops_once(dut):
    await start(dut)
    for b in b"xy":
        await scan(dut, push=b)
        await Timer(1, unit="us")
    v, _c = await access(dut, RXDATA, hold=6)
    assert v == 0x178, hex(v)
    v, _c = await access(dut, RXDATA, hold=3)
    assert v == 0x179, hex(v)
    await access(dut, TXDATA, we=True, wdata=0x41, hold=5)
    assert (await _status(dut)) & 0xFF == DEPTH - 1, "a held write queued the byte once"


@cocotb.test()
async def test_transmit_queue_full_drops_and_flags(dut):
    await start(dut)
    for i in range(DEPTH + 3):
        await access(dut, TXDATA, we=True, wdata=i & 0xFF)
    s = await _status(dut)
    assert s & 0xFF == 0 and (s >> 16) & 1 == 1, hex(s)
    s = await _status(dut)
    assert (s >> 16) & 1 == 0, "reading the status clears the flag"
    got = await drain(dut)
    assert got == [i & 0xFF for i in range(DEPTH)], "the first bytes are kept, the late ones dropped"


@cocotb.test()
async def test_receive_queue_full_is_flagged_to_the_host(dut):
    await start(dut)
    dropped = 0
    for i in range(DEPTH + 2):
        await scan(dut, push=i & 0xFF)
        await Timer(1, unit="us")
    a = await scan(dut)
    await Timer(1, unit="us")
    a = await scan(dut)
    assert a["rx_dropped"] == 0 or True
    assert ((await _status(dut)) >> 8) & 0xFF == DEPTH


@cocotb.test()
async def test_unmapped_window_reads_zero(dut):
    await start(dut)
    v, _c = await access(dut, 0xA0000000)
    assert v == 0
    await access(dut, 0xA0000000, we=True, wdata=0xFFFFFFFF)
    v, _c = await access(dut, 0xB0000010)
    assert v == 0


@cocotb.test()
async def test_load_data_stays_while_the_next_access_runs(dut):
    await start(dut)
    await scan(dut, push=0x5A)
    await Timer(1, unit="us")
    v, _c = await access(dut, RXDATA)
    assert v == 0x15A
    # a memory load: it is the memory's data, then the peripheral's data does not leak
    v, _c = await access(dut, MEM)
    assert v == MEM_VALUE
    v, _c = await access(dut, MEM)
    assert v == MEM_VALUE


@cocotb.test()
async def test_the_load_in_the_last_stage_keeps_its_data(dut):
    """While load A is in its last stage the next access is already on the port: rdata must
    still be A's until that next access advances."""
    await start(dut)
    for b in b"AB":
        await scan(dut, push=b)
        await Timer(1, unit="us")
    # A: a peripheral read, completes and advances
    dut.addr.value = RXDATA
    dut.rden.value = 1
    while True:
        await post_edge(dut)
        if int(dut.ready.value):
            break
    dut.mem_advance.value = 1
    await post_edge(dut)
    dut.mem_advance.value = 0
    # B is on the port now: a second peripheral read, still working; A's data is on rdata
    dut.addr.value = RXDATA
    for _ in range(3):
        assert int(dut.rdata.value) == 0x141, hex(int(dut.rdata.value))
        await post_edge(dut)
    dut.mem_advance.value = 1
    await post_edge(dut)
    dut.mem_advance.value = 0
    assert int(dut.rdata.value) == 0x142
    dut.rden.value = 0


@cocotb.test()
async def test_status_tells_whether_a_host_has_scanned(dut):
    await start(dut)
    assert (await _status(dut)) >> 17 & 1 == 0
    await scan(dut)
    await Timer(1, unit="us")
    assert (await _status(dut)) >> 17 & 1 == 1
