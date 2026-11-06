"""flash_simulation.

The two-port model of the internal FLASH, alone: both ports read with a
latency of one clock, only port B writes, and the content starts from
the file of the generic.

"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut

INIT_WORDS = 11  # words of the file the memory starts from
SETTLE_NS = 1  # time for the registered outputs to settle after an edge


async def start(dut: Dut) -> None:
    """Start the two clocks and park the inputs."""
    cocotb.start_soon(Clock(dut.i_clk_a, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.i_clk_b, 10, unit="ns").start())
    dut.i_address_a.value = 0
    dut.i_address_b.value = 0
    dut.i_rden_a.value = 1
    dut.i_rden_b.value = 1
    dut.i_wren_b.value = 0
    dut.i_data_b.value = 0
    await edge(dut)


async def edge(dut: Dut) -> None:
    """Wait for a rising edge and let the outputs settle."""
    await RisingEdge(dut.i_clk_a)
    await Timer(SETTLE_NS, unit="ns")


async def read_a(dut: Dut, index: int) -> int:
    """Read a word by port A and return it one clock later."""
    dut.i_address_a.value = index
    await edge(dut)
    return int(dut.o_q_a.value)


async def read_b(dut: Dut, index: int) -> int:
    """Read a word by port B and return it one clock later."""
    dut.i_address_b.value = index
    dut.i_wren_b.value = 0
    await edge(dut)
    return int(dut.o_q_b.value)


async def write_b(dut: Dut, index: int, value: int) -> None:
    """Write a word by port B for one clock."""
    dut.i_address_b.value = index
    dut.i_data_b.value = value
    dut.i_wren_b.value = 1
    await edge(dut)
    dut.i_wren_b.value = 0


@cocotb.test()
async def test_both_ports_start_from_the_file(dut: Dut):
    """Check that the words of the file come out of both ports."""
    await start(dut)
    for index in range(INIT_WORDS):
        check_equal(await read_a(dut, index), index, f"port A word {index}")
        check_equal(await read_b(dut, index), index, f"port B word {index}")


@cocotb.test()
async def test_words_after_the_file_start_zeroed(dut: Dut):
    """Check that the words the file does not have read as zero."""
    await start(dut)
    for index in (INIT_WORDS, INIT_WORDS + 1, 100, 1023):
        check_equal(await read_a(dut, index), 0, f"port A word {index}")
        check_equal(await read_b(dut, index), 0, f"port B word {index}")


@cocotb.test()
async def test_the_read_takes_one_clock(dut: Dut):
    """Check that the address of a clock gives the word in the next."""
    await start(dut)
    dut.i_address_a.value = 3
    dut.i_address_b.value = 4
    await Timer(SETTLE_NS, unit="ns")
    check_equal(int(dut.o_q_a.value), 0, "not before the edge")
    await edge(dut)
    check_equal(int(dut.o_q_a.value), 3)
    check_equal(int(dut.o_q_b.value), 4)


@cocotb.test()
async def test_a_write_by_port_b_is_read_by_both_ports(dut: Dut):
    """Check that a stored word is seen by A and by B."""
    await start(dut)
    await write_b(dut, 200, 0xCAFEF00D)
    check_equal(await read_a(dut, 200), 0xCAFEF00D)
    check_equal(await read_b(dut, 200), 0xCAFEF00D)
    check_equal(await read_a(dut, 201), 0, "the neighbour is untouched")
    check_equal(await read_a(dut, 3), 3, "the file word is untouched")


@cocotb.test()
async def test_a_write_shows_the_new_word_on_port_b(dut: Dut):
    """Check that port B returns the word it is writing."""
    await start(dut)
    dut.i_address_b.value = 5
    dut.i_data_b.value = 0x12345678
    dut.i_wren_b.value = 1
    await edge(dut)
    check_equal(int(dut.o_q_b.value), 0x12345678)


@cocotb.test()
async def test_the_write_enable_wins_over_the_read_enable(dut: Dut):
    """Check that port B writes even with its read enable low."""
    await start(dut)
    dut.i_rden_b.value = 0
    await write_b(dut, 7, 0xA5A5A5A5)
    dut.i_rden_b.value = 1
    check_equal(await read_a(dut, 7), 0xA5A5A5A5)


@cocotb.test()
async def test_a_low_read_enable_keeps_the_output(dut: Dut):
    """Check that the output holds without a read enable."""
    await start(dut)
    check_equal(await read_a(dut, 2), 2)
    check_equal(await read_b(dut, 6), 6)
    dut.i_rden_a.value = 0
    dut.i_rden_b.value = 0
    dut.i_address_a.value = 9
    dut.i_address_b.value = 9
    await edge(dut)
    check_equal(int(dut.o_q_a.value), 2)
    check_equal(int(dut.o_q_b.value), 6)
