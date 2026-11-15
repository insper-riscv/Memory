"""The window of a bridge inside the SDRAM chip.

A bridge forces the most significant bit of the chip word address
(`fixed_msb`) and adds a constant (`word_offset`), so that one chip
serves two regions of any sizes: 32 MiB each, 16 MiB and 48 MiB, or 48
MiB and 16 MiB. The test reads the two generics of the design under test
and checks the word address the controller receives against a table of
values worked out by hand for each configuration in tests.json.

"""

import cocotb

from tests.python.unittests.checks import check_equal
from tests.python.unittests.dut import Dut
from tests.python.unittests.ram.sdram_cpu_bridge import (
    CPU_100_PS,
    access,
    advance,
    start,
)

WORD_BITS = 24  # bits of the chip word address (64 MiB of 32-bit words)
MIB_WORDS = 1 << 18  # words of 32 bits in 1 MiB

# (fixed_msb, word_offset) -> {core word address: chip word address}
EXPECTED: dict[tuple[str, int], dict[int, int]] = {
    # neutral defaults: the address goes through unchanged
    ("U", 0): {0x000000: 0x000000, 0x123456: 0x123456, 0xFFFFFF: 0xFFFFFF},
    # the lower half of the chip: the 32 MiB FLASH
    ("0", 0): {0x000000: 0x000000, 0x800000: 0x000000, 0xFFFFFF: 0x7FFFFF},
    # the upper half of the chip: the 32 MiB RAM
    ("1", 0): {0x000000: 0x800000, 0x000123: 0x800123, 0x7FFFFF: 0xFFFFFF},
    # 16 MiB of FLASH below 48 MiB of RAM: RAM starts at 16 MiB
    ("U", 16 * MIB_WORDS): {
        0x000000: 16 * MIB_WORDS,
        0x000010: 16 * MIB_WORDS + 0x10,
        48 * MIB_WORDS - 1: (1 << WORD_BITS) - 1,
        48 * MIB_WORDS: 0,
    },
    # 48 MiB of FLASH below 16 MiB of RAM: RAM starts at 48 MiB
    ("U", 48 * MIB_WORDS): {
        0x000000: 48 * MIB_WORDS,
        16 * MIB_WORDS - 1: (1 << WORD_BITS) - 1,
    },
    # both at once: the forced bit first, the offset after it
    ("1", 0x000010): {0x000000: 0x800010, 0x000001: 0x800011},
}


def generics(dut: Dut) -> tuple[str, int]:
    """Return the (fixed_msb, word_offset) generics of the design."""
    msb = str(dut.fixed_msb.value)
    return msb, int(dut.word_offset.value)


@cocotb.test()
async def test_the_chip_address_follows_the_window(dut: Dut):
    """The controller gets the address the window gives."""
    key = generics(dut)
    table = EXPECTED[key]
    controller = await start(dut, CPU_100_PS)
    for index, (word, chip) in enumerate(table.items()):
        await access(dut, False, word)
        await advance(dut)
        we, addr, _, _, _ = controller.seen[-1]
        check_equal(
            (we, addr),
            (0, chip),
            f"{key}: core word 0x{word:06X} reached 0x{addr:06X}",
        )
        check_equal(len(controller.seen), index + 1, "one request each")


@cocotb.test()
async def test_a_write_and_a_line_use_the_same_window(dut: Dut):
    """A write and a line read are placed like a word read."""
    key = generics(dut)
    word, chip = next(iter(EXPECTED[key].items()))
    controller = await start(dut, CPU_100_PS)
    await access(dut, True, word, 0xA5A5A5A5, 0xF)
    await advance(dut)
    we, addr, _, _, line = controller.seen[-1]
    check_equal((we, addr, line), (1, chip, 0), "write")
    await access(dut, False, word, line=True)
    await advance(dut)
    we, addr, _, _, line = controller.seen[-1]
    check_equal((we, addr, line), (0, chip, 1), "line read")
