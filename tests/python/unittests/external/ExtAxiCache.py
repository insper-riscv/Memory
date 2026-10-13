"""The cache on the AXI4-Lite external bus: what is cached, what is not, and the flush a program asks for.

The memory behind the SDRAM slave can be read without the bus (dbg_word_*), so each test sees what
reached it. The address of word w of the SDRAM is 0x40000000 + 4 w; the memory of the test has 4096
words, so the tests use the words below 0x1000, and the uncached window through its alias there
(the cache's tag is 14 bits of address, the memory's is 12 bits of word).
"""

import cocotb

from tests.python.unittests.external.ExtBus import access, post_edge, start

CACHE = 0xF0000000          # peripheral 7: write = flush, read = busy
SDRAM = 0x40000000
UNCACHED = 0x43FFF000       # the last 4 KB of the SDRAM space; the memory of the test holds 4096 words


async def peek(dut, word):
    dut.dbg_word_addr.value = word
    await post_edge(dut)
    return int(dut.dbg_word_data.value)


async def wait_idle(dut):
    for _ in range(100_000):
        v, _c = await access(dut, CACHE)
        if v == 0:
            return
    raise AssertionError("the flush never ended")


@cocotb.test()
async def test_a_cached_write_reaches_the_memory_only_with_the_flush(dut):
    await start(dut)
    await access(dut, SDRAM + 0x200, we=True, wdata=0xCAFE0001)
    assert await peek(dut, 0x80) == 0, "a write-back cache wrote through"
    v, _c = await access(dut, SDRAM + 0x200)
    assert v == 0xCAFE0001
    await access(dut, CACHE, we=True, wdata=1)
    await wait_idle(dut)
    assert await peek(dut, 0x80) == 0xCAFE0001


@cocotb.test()
async def test_the_flush_stops_other_accesses_until_it_ends(dut):
    await start(dut)
    for i in range(8):
        await access(dut, SDRAM + 0x400 + 0x10 * i, we=True, wdata=0x1000 + i)
    await access(dut, CACHE, we=True, wdata=1)
    # the next access is not a poll of the status: it just has to wait, and see the flush done
    v, _c = await access(dut, 0xC0000008)       # the UART status, an access that does not use the cache
    for i in range(8):
        assert await peek(dut, 0x100 + 4 * i) == 0x1000 + i, f"line {i} was not written back before the access"


@cocotb.test()
async def test_the_uncached_window_writes_through(dut):
    await start(dut)
    await access(dut, UNCACHED + 0x20, we=True, wdata=0x600D)
    assert await peek(dut, 0xC08) == 0x600D, "a word of the shared window stayed in the cache"
    v, _c = await access(dut, UNCACHED + 0x20)
    assert v == 0x600D


@cocotb.test()
async def test_cache_status_reads_zero_when_idle(dut):
    await start(dut)
    v, _c = await access(dut, CACHE)
    assert v == 0
