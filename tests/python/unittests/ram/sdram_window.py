"""One SDRAM chip shared by two regions, each bridge with its window.

The data bridge forces the most significant bit of the chip word address
to 1 and the instruction bridge forces it to 0 (the 32 MiB and 32 MiB
split of the DE0-CV), so that the core reaches the upper half of the
chip only by data and the lower half only by instruction. The host, on
the debug port, sees the whole chip.

"""

import cocotb

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut
from tests.python.unittests.ram.sdram_debug_port import (
    read,
    start_debug,
    write,
)
from tests.python.unittests.ram.sdram_helpers import (
    access,
    model_word,
    post_edge,
)

HALF = 1 << 23  # word address of the upper half of the 16-bit chip
TIMEOUT = 400  # core cycles an instruction fetch may take


async def fetch(dut: Dut, addr: int) -> int:
    """Read one word through the instruction bridge."""
    dut.i_ins_addr.value = addr
    dut.i_ins_rden.value = 1
    for _ in range(TIMEOUT):
        await post_edge(dut)
        if int(dut.o_ins_ready.value):
            break
    else:
        raise AssertionError("the instruction fetch never finished")
    dut.i_ins_advance.value = 1
    await post_edge(dut)
    dut.i_ins_advance.value = 0
    dut.i_ins_rden.value = 0
    return int(dut.o_ins_rdata.value)


@cocotb.test()
async def test_a_data_write_lands_in_the_upper_half(dut: Dut):
    """The data bridge puts the write in the upper half of the chip."""
    await start_debug(dut)
    await write(dut, 0x001234, 0x11111111)  # the lower half, by the host
    await access(dut, True, 0x001234, 0xA5A5A5A5)
    check_equal(await model_word(dut, HALF | 0x1234), 0xA5A5A5A5, "upper")
    check_equal(await model_word(dut, 0x1234), 0x11111111, "lower alone")
    check_equal(await read(dut, HALF | 0x1234), 0xA5A5A5A5, "host view")
    got, _ = await access(dut, False, 0x001234)
    check_equal(got, 0xA5A5A5A5, "the core reads it back")


@cocotb.test()
async def test_a_data_address_in_the_upper_half_stays_in_it(dut: Dut):
    """An address with the top bit set reaches the same word."""
    await start_debug(dut)
    await write(dut, HALF | 0x77, 0x77777777)
    got, _ = await access(dut, False, 0x77)
    check_equal(got, 0x77777777, "bit 23 of the address is not used")
    got, _ = await access(dut, False, HALF | 0x77)
    check_equal(got, 0x77777777)


@cocotb.test()
async def test_an_instruction_fetch_reads_the_lower_half(dut: Dut):
    """The instruction bridge reads the lower half, whatever the bit."""
    await start_debug(dut)
    await write(dut, 0x000555, 0x0BADC0DE)
    await write(dut, HALF | 0x555, 0x600DF00D)
    check_equal(await fetch(dut, 0x555 << 2), 0x0BADC0DE, "low address")
    check_equal(
        await fetch(dut, (HALF | 0x555) << 2),
        0x0BADC0DE,
        "address with the top bit set",
    )
