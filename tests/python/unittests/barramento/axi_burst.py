"""AXI4 burst helpers of the Memory tests.

The master side of a write burst and of a read burst, played by the
testbench against an AXI4 slave port.
"""

from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.dut import Dut

AW_DELAY = 2  # clocks W is offered before AW in a burst
OKAY = 0


async def write_response(dut: Dut, tries: int):
    """Take the write response within a number of clocks."""
    dut.i_s_bready.value = 1
    for _ in range(tries):
        await Timer(1, unit="ns")
        if int(dut.o_s_bvalid.value):
            resp = int(dut.o_s_bresp.value)
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            dut.i_s_bready.value = 0
            return resp
        await RisingEdge(dut.i_clk)
    raise AssertionError("no write response")


async def burst_clock(
    dut: Dut, beats: list[tuple[int, int]], i: int, w_first: bool, cycle: int
):
    """Offer beat i for one clock; return (aw_taken, w_taken)."""
    data, strb = beats[i]
    dut.i_s_wdata.value = data
    dut.i_s_wstrb.value = strb
    dut.i_s_wlast.value = 1 if i == len(beats) - 1 else 0
    if w_first and cycle == AW_DELAY:
        dut.i_s_awvalid.value = 1
    await Timer(1, unit="ns")
    aw_hs = int(dut.i_s_awvalid.value) and int(dut.o_s_awready.value)
    w_hs = int(dut.i_s_wvalid.value) and int(dut.o_s_wready.value)
    await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    if aw_hs:
        dut.i_s_awvalid.value = 0
    return bool(aw_hs), bool(w_hs)


async def write_burst(  # noqa: PLR0913, PLR0917
    dut: Dut,
    addr: int,
    beats: list[tuple[int, int]],
    w_first: bool = False,
    size: int = 2,
    burst: int = 1,
):
    """Write a burst of len(beats) beats of (data, strobes).

    Return the response.
    """
    dut.i_s_awaddr.value = addr
    dut.i_s_awlen.value = len(beats) - 1
    dut.i_s_awsize.value = size
    dut.i_s_awburst.value = burst
    dut.i_s_awvalid.value = 0 if w_first else 1
    aw_done = w_closed = False
    i = 0
    dut.i_s_wvalid.value = 1
    for cycle in range(200):
        aw_hs, w_hs = await burst_clock(dut, beats, i, w_first, cycle)
        aw_done = aw_done or aw_hs
        if w_hs and i == len(beats) - 1:
            dut.i_s_wvalid.value = 0
            dut.i_s_wlast.value = 1
            w_closed = True
        elif w_hs:
            i += 1
        if aw_done and w_closed:
            break
    dut.i_s_awlen.value = 0
    dut.i_s_awsize.value = 2
    dut.i_s_awburst.value = 1
    dut.i_s_wlast.value = 1
    return await write_response(dut, 100)


async def read_burst(
    dut: Dut, addr: int, n: int, size: int = 2, burst: int = 1
):
    """Read a burst of n beats; return [(data, resp, last)]."""
    dut.i_s_araddr.value = addr
    dut.i_s_arlen.value = n - 1
    dut.i_s_arsize.value = size
    dut.i_s_arburst.value = burst
    dut.i_s_arvalid.value = 1
    for _ in range(60):
        await Timer(1, unit="ns")
        hs = int(dut.o_s_arready.value)
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        if hs:
            break
    else:
        raise AssertionError("the read request was never accepted")
    dut.i_s_arvalid.value = 0
    dut.i_s_arlen.value = 0
    dut.i_s_arsize.value = 2
    dut.i_s_arburst.value = 1
    dut.i_s_rready.value = 1
    got: list[tuple[int, int, int]] = []
    for _ in range(200):
        await Timer(1, unit="ns")
        if int(dut.o_s_rvalid.value):
            got.append(
                (
                    int(dut.o_s_rdata.value),
                    int(dut.o_s_rresp.value),
                    int(dut.o_s_rlast.value),
                )
            )
            last = got[-1][2]
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            if last:
                dut.i_s_rready.value = 0
                return got
        else:
            await RisingEdge(dut.i_clk)
    raise AssertionError(f"the burst ended after {len(got)} beats")
