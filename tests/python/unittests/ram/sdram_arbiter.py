"""The SDRAM arbiter: three masters, one controller port.

The testbench plays the three masters (A, the data bridge; I, the
instruction bridge; B, the debug master) and the controller. The
controller keeps the order in which it saw the requests and answers each
after a fixed delay with data derived from the address, so a master
that gets another master's answer is caught.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

CLK_NS = 10
TIMEOUT = 400  # clock cycles a master may wait for its answer
CONTROLLER_DELAY = 6  # clock cycles the controller takes per request
REQUESTS = 6  # requests each master makes in the contention test
MASTERS = ("A", "I", "B")
LINE_MASTERS = ("A", "I")
# ports of each master: (request, ack, we, addr, wdata, be)
PORTS = {
    "A": ("a_req_tog", "a_ack_tog", "a_we", "a_addr", "a_wdata", "a_be"),
    "I": (
        "ins_req_tog",
        "ins_ack_tog",
        "ins_we",
        "ins_addr",
        "ins_wdata",
        "ins_be",
    ),
    "B": ("b_req_tog", "b_ack_tog", "b_we", "b_addr", "b_wdata", "b_be"),
}
RDATA = {"A": "o_a_rdata", "I": "o_ins_rdata", "B": "o_b_rdata"}
RDATA_X = {"A": "o_a_rdata_x", "I": "o_ins_rdata_x"}


def answer(addr: int, line: bool = False) -> int:
    """Return the word the controller answers for an address."""
    return (0xA5000000 | (addr & 0xFFFFFF)) ^ (0x00FF0000 if line else 0)


def answer_x(addr: int) -> int:
    """Return the extra words the controller answers for a line."""
    return sum(
        (answer(addr + i + 1, True) & 0xFFFFFFFF) << (32 * i) for i in range(3)
    )


class Controller:
    """The controller side: records requests and answers them."""

    def __init__(self, dut: Dut, delay: int = CONTROLLER_DELAY) -> None:
        """Keep the design and the answer delay."""
        self.dut = dut
        self.delay = delay
        self.seen: list[tuple[int, int, int, int, int, int]] = []

    async def run(self) -> None:
        """Answer every request the arbiter makes, forever."""
        dut = self.dut
        last = 0
        while True:
            await RisingEdge(dut.i_clk)
            req = int(dut.o_c_req_tog.value)
            if req == last:
                continue
            last = req
            addr = int(dut.o_c_addr.value)
            self.seen.append(
                (
                    int(dut.o_c_we.value),
                    addr,
                    int(dut.o_c_wdata.value),
                    int(dut.o_c_be.value),
                    int(dut.o_c_line.value),
                    int(dut.o_c_wdata_x.value),
                )
            )
            for _ in range(self.delay):
                await RisingEdge(dut.i_clk)
            line = int(dut.o_c_line.value)
            dut.i_c_rdata.value = answer(addr, bool(line))
            dut.i_c_rdata_x.value = answer_x(addr)
            dut.i_c_ack_tog.value = req


async def start(dut: Dut) -> Controller:
    """Start the clock, reset and start the controller."""
    quiet = {"req_tog": 0, "we": 0, "addr": 0, "wdata": 0, "be": 0}
    for master in ("a", "b", "ins"):
        for field, value in quiet.items():
            getattr(dut, f"i_{master}_{field}").value = value
    for master in ("a", "ins"):
        for field in ("line", "wdata_x", "be_x"):
            getattr(dut, f"i_{master}_{field}").value = 0
    dut.i_c_ack_tog.value = 0
    dut.i_c_rdata.value = 0
    dut.i_c_rdata_x.value = 0
    dut.i_rst.value = 1
    cocotb.start_soon(Clock(dut.i_clk, CLK_NS, unit="ns").start())
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await RisingEdge(dut.i_clk)
    controller = Controller(dut)
    cocotb.start_soon(controller.run())
    return controller


def drive(
    dut: Dut, master: str, addr: int, we: bool = False, line: bool = False
) -> int:
    """Put a request on a master's bus and flip its toggle.

    Returns the toggle value the answer must reach.
    """
    req, _, w, a, d, b = PORTS[master]
    getattr(dut, f"i_{w}").value = int(we)
    getattr(dut, f"i_{a}").value = addr
    getattr(dut, f"i_{d}").value = 0xD0000000 | addr
    getattr(dut, f"i_{b}").value = 0xF if we else 0
    if master in LINE_MASTERS:
        prefix = "a" if master == "A" else "ins"
        getattr(dut, f"i_{prefix}_line").value = int(line)
        getattr(dut, f"i_{prefix}_wdata_x").value = 0xE0 + addr
        getattr(dut, f"i_{prefix}_be_x").value = 0xFFF
    toggle = 1 - int(getattr(dut, f"i_{req}").value)
    getattr(dut, f"i_{req}").value = toggle
    return toggle


async def wait_ack(dut: Dut, master: str, toggle: int) -> int:
    """Wait for a master's acknowledge. Returns the cycles waited."""
    ack = getattr(dut, f"o_{PORTS[master][1]}")
    for cycles in range(TIMEOUT):
        if int(ack.value) == toggle:
            return cycles
        await RisingEdge(dut.i_clk)
        await Timer(1, unit="ns")
    raise AssertionError(f"master {master} never got its answer")


async def one_request(
    dut: Dut, master: str, addr: int, we: bool = False, line: bool = False
) -> None:
    """Make one request and check the answer and the forwarded bus."""
    toggle = drive(dut, master, addr, we, line)
    await wait_ack(dut, master, toggle)
    got = int(getattr(dut, RDATA[master]).value)
    check_equal(got, answer(addr, line), f"master {master} rdata")
    if line and master in RDATA_X:
        got_x = int(getattr(dut, RDATA_X[master]).value)
        check_equal(got_x, answer_x(addr), f"master {master} rdata_x")


@cocotb.test()
async def test_each_master_alone(dut: Dut):
    """A lone master gets its request forwarded and its own answer."""
    controller = await start(dut)
    for master, addr in (("A", 0x100), ("I", 0x200), ("B", 0x300)):
        await one_request(dut, master, addr, we=True)
        we, c_addr, wdata, be, line, _ = controller.seen[-1]
        check_equal(
            (we, c_addr, wdata, be, line),
            (1, addr, 0xD0000000 | addr, 0xF, 0),
            f"master {master} forwarded",
        )
    check_equal(len(controller.seen), len(MASTERS))


@cocotb.test()
async def test_reads_are_forwarded_as_reads(dut: Dut):
    """A read request reaches the controller with the write flag low."""
    controller = await start(dut)
    for master in MASTERS:
        await one_request(dut, master, 0x40)
        check_equal(controller.seen[-1][0], 0, f"master {master} read")


@cocotb.test()
async def test_line_requests_carry_four_words(dut: Dut):
    """Masters A and I move a line, with the extra words both ways."""
    controller = await start(dut)
    for master in LINE_MASTERS:
        await one_request(dut, master, 0x80, we=True, line=True)
        _, _, _, _, line, wdata_x = controller.seen[-1]
        check_equal(line, 1, f"master {master} line flag")
        check_equal(wdata_x & 0xFFFFFFFF, 0xE0 + 0x80, "word 1")
        await one_request(dut, master, 0x90, line=True)


@cocotb.test()
async def test_the_debug_master_never_asks_for_a_line(dut: Dut):
    """Master B has no line port, so its requests are single words."""
    controller = await start(dut)
    await one_request(dut, "B", 0x55)
    check_equal(controller.seen[-1][4], 0)


@cocotb.test()
async def test_contention_serves_every_master_in_turn(dut: Dut):
    """Three masters asking over and over each get every request served.

    No master is served twice in a row while the others wait, so the
    order is a rotation and nobody starves.
    """
    controller = await start(dut)
    owner: dict[int, str] = {}

    async def hammer(master: str) -> None:
        for n in range(REQUESTS):
            addr = {"A": 0x1000, "I": 0x2000, "B": 0x3000}[master] + n
            owner[addr] = master
            await one_request(dut, master, addr)

    tasks = [cocotb.start_soon(hammer(master)) for master in MASTERS]
    for task in tasks:
        await task
    order = [owner[entry[1]] for entry in controller.seen]
    check_equal(len(order), REQUESTS * len(MASTERS), f"served {order}")
    for master in MASTERS:
        check_equal(order.count(master), REQUESTS, f"master {master}")
    for window in zip(order, order[1:], order[2:], strict=False):
        check_true(
            len(set(window)) == len(MASTERS),
            f"not a rotation at {window}: {order}",
        )


@cocotb.test()
async def test_a_waiting_master_waits_for_one_access(dut: Dut):
    """A master that asks during another's access waits only for it."""
    controller = await start(dut)
    toggle_a = drive(dut, "A", 0x10)
    for _ in range(2 * CONTROLLER_DELAY // 3):
        await RisingEdge(dut.i_clk)
    toggle_b = drive(dut, "B", 0x20)
    await wait_ack(dut, "A", toggle_a)
    waited = await wait_ack(dut, "B", toggle_b)
    check_true(waited <= 3 * CONTROLLER_DELAY + 8, f"B waited {waited} cycles")
    check_equal([e[1] for e in controller.seen], [0x10, 0x20])


@cocotb.test()
async def test_reset_clears_the_acknowledges(dut: Dut):
    """After a reset no master sees an old acknowledge."""
    await start(dut)
    for master in MASTERS:
        await one_request(dut, master, 0x77)
    dut.i_rst.value = 1
    for name in ("a", "b", "ins"):
        getattr(dut, f"i_{name}_req_tog").value = 0
    for _ in range(4):
        await RisingEdge(dut.i_clk)
    await Timer(1, unit="ns")
    for master in MASTERS:
        ack = getattr(dut, f"o_{PORTS[master][1]}")
        check_equal(int(ack.value), 0, f"master {master} acknowledge")
