"""The cacheless FLASH fetch path with fetch_line false.

Every instruction is a word request, so each one pays the first-word
latency of the chip.

"""

import cocotb

from tests.python.unittests.cache.ifetch_path import (
    FIRST_LATENCY,
    FLASH,
    chip_requests,
    run_trace,
    start,
)
from tests.python.unittests.checks import check_equal, check_true, log_info
from tests.python.unittests.dut import Dut


@cocotb.test()
async def test_every_instruction_pays_the_first_word_latency(dut: Dut):
    """Check the clocks of a sequential run of 16 instructions."""
    await start(dut)
    base = FLASH + 0x400
    total = await run_trace(dut, [base + 4 * i for i in range(16)])
    check_equal(chip_requests(dut), 16)
    per_word = total / 16
    log_info(f"sequential: {per_word:.2f} clocks per instruction")
    check_true(FIRST_LATENCY <= per_word <= FIRST_LATENCY + 12, per_word)
