"""flash_arbiter: two read masters share one FLASH chip.

Ties alternate, a grant is never cut.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal

LAT = 4


def word(addr):
    """Return the data word the models hold at an address."""
    return ((addr * 2654435761) ^ 0x33330000) & 0xFFFFFFFF


class Chip:
    """A chip with a latency; holds ready until advance.

    Logs the requests it served.

    """

    def __init__(self, dut):
        """Bind the model to the DUT."""
        self.dut = dut
        self.log = []
        self.busy = False

    async def run(self):
        """Drive the slave side of the port, clock by clock."""
        dut = self.dut
        state, count = "idle", 0
        dut.i_ready.value = 0
        while True:
            await RisingEdge(dut.i_clk)
            if state == "idle" and int(dut.o_rden.value) == 1:
                self.log.append(int(dut.o_addr.value))
                state, count = "wait", LAT
            elif state == "wait":
                count -= 1
                if count == 0:
                    a = self.log[-1]
                    dut.i_rdata.value = word(a)
                    dut.i_ready.value = 1
                    state = "done"
            elif state == "done" and int(dut.o_advance.value) == 1:
                dut.i_ready.value = 0
                state = "idle"


async def start(dut):
    """Start the clock and reset the DUT."""
    cocotb.start_soon(Clock(dut.i_clk, 10, unit="ns").start())
    dut.i_rst.value = 1
    for n in (
        "i_a_rden",
        "i_a_advance",
        "i_b_rden",
        "i_b_advance",
        "i_a_line",
        "i_b_line",
    ):
        getattr(dut, n).value = 0
    dut.i_a_addr.value = 0
    dut.i_b_addr.value = 0
    dut.i_rdata_x.value = 0
    dut.i_rdata.value = 0
    dut.i_ready.value = 0
    for _ in range(3):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    chip = Chip(dut)
    cocotb.start_soon(chip.run())
    return chip


async def master(dut, who, addr, results, start_delay=0, hold_after=0):  # noqa: PLR0913, PLR0917
    """Model a cache-like master.

    Hold the request until ready, advance, drop on the same edge.

    """
    for _ in range(start_delay):
        await RisingEdge(dut.i_clk)
    rden = getattr(dut, f"i_{who}_rden")
    adv = getattr(dut, f"i_{who}_advance")
    ready = getattr(dut, f"o_{who}_ready")
    rdata = getattr(dut, f"o_{who}_rdata")
    getattr(dut, f"i_{who}_addr").value = addr
    rden.value = 1
    clocks = 0
    while True:
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
        clocks += 1
        if int(ready.value) == 1:
            results.append((who, addr, int(rdata.value), clocks))
            adv.value = 1
            await RisingEdge(dut.i_clk)
            await Timer(1, unit="ns")
            rden.value = 0
            adv.value = 0
            for _ in range(hold_after):
                await RisingEdge(dut.i_clk)
            return


@cocotb.test()
async def test_single_requests(dut):
    """Check that single requests."""
    chip = await start(dut)
    res = []
    await master(dut, "a", 0x20000010, res)
    await master(dut, "b", 0x20000020, res)
    check_equal(
        [(w, a) for w, a, _, _ in res],
        [
            ("a", 0x20000010),
            ("b", 0x20000020),
        ],
    )
    check_equal(
        [d for _, _, d, _ in res], [word(0x20000010), word(0x20000020)]
    )
    check_equal(chip.log, [0x20000010, 0x20000020])


@cocotb.test()
async def test_a_wins_a_tie_then_b_follows(dut):
    """Check that a wins a tie then b follows."""
    chip = await start(dut)
    res = []
    ta = cocotb.start_soon(master(dut, "a", 0x20000100, res))
    tb = cocotb.start_soon(master(dut, "b", 0x20000200, res))
    await ta
    await tb
    check_equal([w for w, _, _, _ in res], ["a", "b"])
    check_equal(chip.log, [0x20000100, 0x20000200])


@cocotb.test()
async def test_a_grant_is_not_cut(dut):
    """Check that a grant is not cut."""
    chip = await start(dut)
    res = []
    tb = cocotb.start_soon(master(dut, "b", 0x20000300, res))
    # A shows up while B is being served
    ta = cocotb.start_soon(master(dut, "a", 0x20000400, res, start_delay=2))
    await tb
    await ta
    check_equal([w for w, _, _, _ in res], ["b", "a"])
    check_equal(chip.log, [0x20000300, 0x20000400])
    # each master got its own word
    check_equal(
        {a: d for _, a, d, _ in res},
        {
            0x20000300: word(0x20000300),
            0x20000400: word(0x20000400),
        },
    )


@cocotb.test()
async def test_b_is_not_starved_by_back_to_back_requests_of_a(dut):
    """Check that b is not starved by back to back requests of a."""
    await start(dut)
    res = []

    async def a_twice():
        await master(dut, "a", 0x20000500, res)
        await master(dut, "a", 0x20000510, res)

    ta = cocotb.start_soon(a_twice())
    tb = cocotb.start_soon(master(dut, "b", 0x20000600, res, start_delay=3))
    await ta
    await tb
    order = [w for w, _, _, _ in res]
    check_equal(order, ["a", "b", "a"], order)
