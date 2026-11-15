"""mem_region_router with a FLASH of many MiB in the SDRAM chip.

The FLASH starts after the 4 KiB of the BOOT_MEMORY and the window
of the chip covers all of it (flash_window_kib = flash_end_kib -
flash_base_kib), so a read far above the 1 MiB window of the default
still reaches the chip. The test takes the size of the FLASH from the
generics, and tests.json runs it with 16, 32 and 48 MiB.

"""

import cocotb

from tests.python.unittests.cache.mem_region_router import (
    line_words,
    request,
    start,
)
from tests.python.unittests.checks import check_equal, check_true
from tests.python.unittests.dut import Dut

KIB = 1024
MIB = 1 << 20
LINE = 16  # bytes of a line


def edges(dut: Dut) -> tuple[int, int]:
    """Return the first byte and the end (exclusive) of the FLASH."""
    return (
        int(dut.flash_base_kib.value) * KIB,
        int(dut.flash_end_kib.value) * KIB,
    )


@cocotb.test()
async def test_reads_across_the_whole_flash_reach_the_chip(dut: Dut):
    """The first line, one at 1 MiB and above, and the last line."""
    s, f = await start(dut)
    base, end = edges(dut)
    probes = [base, base + MIB, end // 2, end - LINE]
    for addr in probes:
        r, rx, _ = await request(dut, addr, rd=1, line=1)
        got = [r, rx & 0xFFFFFFFF, (rx >> 32) & 0xFFFFFFFF, rx >> 64]
        check_equal(got, line_words(0x22220000, addr), f"{addr:#x}")
    check_equal([a for a, _, _ in f.requests], probes)
    check_equal(s.requests, [], "nothing went to the SDRAM")


@cocotb.test()
async def test_the_edges_of_the_region(dut: Dut):
    """Below the FLASH and from its end on, the SDRAM answers."""
    s, f = await start(dut)
    base, end = edges(dut)
    below, above = base - LINE, end
    await request(dut, below, rd=1, line=1)
    await request(dut, above, rd=1, line=1)
    check_equal([a for a, _, _ in s.requests], [below, above])
    check_equal(f.requests, [], "nothing went to the FLASH")


@cocotb.test()
async def test_a_store_is_absorbed_anywhere_in_the_flash(dut: Dut):
    """A store high in the FLASH never reaches the chip."""
    s, f = await start(dut)
    base, end = edges(dut)
    for addr in (base + 0x40, base + 2 * MIB, end - 0x40):
        await request(dut, addr, wr=1)
    check_true(s.requests == [] and f.requests == [], "a store got out")
