"""The bridge between the core clock and the SDRAM controller clock.

The testbench plays the core (an access held until the pipeline
advances) and the controller (it answers a request toggle with an
acknowledge toggle after some memory clocks, with data derived from the
address). The two clock ratios of the platform are run: a 50 MHz core
and a 100 MHz core, both against the 142.857 MHz memory clock.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

MEM_PS = 7000  # 142.857 MHz
CPU_50_PS = 20000  # a 50 MHz core
CPU_100_PS = 10000  # a 100 MHz core
CONTROLLER_DELAY = 5  # memory clocks the controller takes per request
TIMEOUT = 200  # core cycles ready may take
SETTLE_CYCLES = 6  # core cycles for a level to cross the clocks


def word_of(addr: int) -> int:
    """Return the word the controller answers for a word address."""
    return 0x5A000000 | addr


class Controller:
    """The controller side: answers the request toggle."""

    def __init__(self, dut: Dut) -> None:
        """Keep the design and an empty log of requests."""
        self.dut = dut
        self.seen: list[tuple[int, int, int, int, int]] = []

    async def run(self) -> None:
        """Answer every request, one memory clock a step."""
        dut = self.dut
        last = 0
        while True:
            await Timer(MEM_PS, unit="ps")
            req = int(dut.o_req_tog.value)
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
                )
            )
            for _ in range(CONTROLLER_DELAY):
                await Timer(MEM_PS, unit="ps")
            dut.i_c_rdata.value = word_of(addr)
            dut.i_c_rdata_x.value = (
                word_of(addr + 1)
                | (word_of(addr + 2) << 32)
                | (word_of(addr + 3) << 64)
            )
            dut.i_ack_tog.value = req


def _set(dut: Dut, **values: int) -> None:
    """Drive the named inputs of the design."""
    for name, value in values.items():
        getattr(dut, name).value = value


async def start(dut: Dut, cpu_ps: int, init_done: bool = True) -> Controller:
    """Start the core clock, reset and release init_done."""
    _set(dut, i_addr=0, i_wdata=0, i_byteena=0, i_rden=0, i_wren=0)
    _set(dut, i_mem_advance=0, i_line=0, i_wdata_x=0, i_byteena_x=0)
    _set(dut, i_ack_tog=0, i_c_rdata=0, i_c_rdata_x=0, i_init_done=0)
    dut.i_rst_cpu.value = 1
    cocotb.start_soon(Clock(dut.i_clk_cpu, cpu_ps, unit="ps").start())
    for _ in range(4):
        await RisingEdge(dut.i_clk_cpu)
    dut.i_rst_cpu.value = 0
    controller = Controller(dut)
    cocotb.start_soon(controller.run())
    if init_done:
        dut.i_init_done.value = 1
        await settle(dut)
    return controller


async def settle(dut: Dut) -> None:
    """Wait for a level to cross to the core clock."""
    for _ in range(SETTLE_CYCLES):
        await RisingEdge(dut.i_clk_cpu)
    await Timer(1, unit="ns")


async def access(  # noqa: PLR0913, PLR0917
    dut: Dut,
    we: bool,
    word: int,
    wdata: int = 0,
    be: int = 0xF,
    line: bool = False,
) -> tuple[int, int]:
    """Make one access. Returns (read data, core cycles until ready)."""
    _set(dut, i_addr=0x40000000 | (word << 2), i_wdata=wdata, i_byteena=be)
    _set(dut, i_line=int(line), i_wren=int(we), i_rden=int(not we))
    cycles = 0
    while True:
        await RisingEdge(dut.i_clk_cpu)
        await Timer(1, unit="ns")
        cycles += 1
        if int(dut.o_ready.value):
            break
        check_true(cycles < TIMEOUT, "ready never came")
    dut.i_rden.value = 0
    dut.i_wren.value = 0
    return int(dut.o_rdata.value), cycles


async def advance(dut: Dut) -> None:
    """Let the pipeline advance for one core cycle."""
    dut.i_mem_advance.value = 1
    await RisingEdge(dut.i_clk_cpu)
    await Timer(1, unit="ns")
    dut.i_mem_advance.value = 0


async def read_word(dut: Dut, word: int) -> int:
    """Read one word through the bridge and advance the pipeline."""
    _, _ = await access(dut, False, word)
    await advance(dut)
    return int(dut.o_rdata.value)


async def run_read_write(dut: Dut, cpu_ps: int) -> None:
    """Write a word, read it back and check the requests."""
    controller = await start(dut, cpu_ps)
    await access(dut, True, 0x1234, 0xCAFEBABE, 0x5)
    await advance(dut)
    we, addr, wdata, be, line = controller.seen[-1]
    check_equal((we, addr, wdata, be, line), (1, 0x1234, 0xCAFEBABE, 5, 0))
    got = await read_word(dut, 0x4321)
    check_equal(got, word_of(0x4321))
    we, addr, _, _, line = controller.seen[-1]
    check_equal((we, addr, line), (0, 0x4321, 0))
    check_equal(len(controller.seen), 2, "one request per access")


async def run_line(dut: Dut, cpu_ps: int) -> None:
    """Read a line and check the four words reach the core."""
    controller = await start(dut, cpu_ps)
    await access(dut, False, 0x2000, line=True)
    await advance(dut)
    words = [int(dut.o_rdata.value)]
    extra = int(dut.o_rdata_x.value)
    words += [(extra >> (32 * i)) & 0xFFFFFFFF for i in range(3)]
    check_equal(words, [word_of(0x2000 + i) for i in range(4)])
    check_equal(controller.seen[-1][4], 1, "line flag forwarded")


async def run_hold(dut: Dut, cpu_ps: int) -> None:
    """Ready and the read data hold until the pipeline advances."""
    await start(dut, cpu_ps)
    await access(dut, False, 0x777)
    before = int(dut.o_rdata.value)
    for _ in range(5):
        await RisingEdge(dut.i_clk_cpu)
        await Timer(1, unit="ns")
        check_equal(int(dut.o_ready.value), 1, "ready dropped")
        check_equal(int(dut.o_rdata.value), before, "data moved early")
    await advance(dut)
    check_equal(int(dut.o_ready.value), 0, "ready after the advance")
    check_equal(int(dut.o_rdata.value), word_of(0x777))


@cocotb.test()
async def test_read_and_write_at_50_mhz(dut: Dut):
    """A write and a read cross the clocks with a 50 MHz core."""
    await run_read_write(dut, CPU_50_PS)


@cocotb.test()
async def test_read_and_write_at_100_mhz(dut: Dut):
    """A write and a read cross the clocks with a 100 MHz core."""
    await run_read_write(dut, CPU_100_PS)


@cocotb.test()
async def test_line_access_at_50_mhz(dut: Dut):
    """A line read returns four words with a 50 MHz core."""
    await run_line(dut, CPU_50_PS)


@cocotb.test()
async def test_line_access_at_100_mhz(dut: Dut):
    """A line read returns four words with a 100 MHz core."""
    await run_line(dut, CPU_100_PS)


@cocotb.test()
async def test_ready_and_data_hold_until_the_pipeline_advances(dut: Dut):
    """The bridge keeps ready and data steady at both ratios."""
    await run_hold(dut, CPU_50_PS)


@cocotb.test()
async def test_ready_and_data_hold_at_100_mhz(dut: Dut):
    """The same holds with a 100 MHz core."""
    await run_hold(dut, CPU_100_PS)


@cocotb.test()
async def test_a_write_leaves_the_read_data_alone(dut: Dut):
    """Only reads change the data the core sees."""
    await start(dut, CPU_50_PS)
    got = await read_word(dut, 0x10)
    await access(dut, True, 0x11, 0x12345678)
    check_equal(int(dut.o_rdata.value), got, "write moved the read data")
    await advance(dut)
    check_equal(int(dut.o_rdata.value), got, "advance moved the read data")


@cocotb.test()
async def test_no_request_before_the_sdram_is_initialized(dut: Dut):
    """The bridge holds an access until init_done is seen."""
    controller = await start(dut, CPU_50_PS, init_done=False)
    dut.i_addr.value = 0x40000040
    dut.i_rden.value = 1
    for _ in range(20):
        await RisingEdge(dut.i_clk_cpu)
        await Timer(1, unit="ns")
        check_equal(int(dut.o_ready.value), 0, "ready before init")
    check_equal(len(controller.seen), 0, "request before init")
    dut.i_init_done.value = 1
    cycles = 0
    while not int(dut.o_ready.value):
        await RisingEdge(dut.i_clk_cpu)
        await Timer(1, unit="ns")
        cycles += 1
        check_true(cycles < TIMEOUT, "ready never came after init")
    check_equal(len(controller.seen), 1)
