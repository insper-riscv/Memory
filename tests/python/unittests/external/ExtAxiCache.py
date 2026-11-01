"""The cache on the AXI4-Lite external bus: what is cached, what is not, and the flush a program asks for.

The memory behind the SDRAM slave can be read without the bus (dbg_word_*), so each test sees what
reached it. The address of word w of the SDRAM is 0x40000000 + 4 w; the memory of the test has 4096
words, so the tests use the words below 0x1000, and the uncached window through its alias there
(the cache's tag is 14 bits of address, the memory's is 12 bits of word).
"""

import cocotb

from tests.python.unittests.external.ExtBus import access, post_edge, start

CACHE = 0xF0000000  # peripheral 7: write = flush, read = busy
SDRAM = 0x40000000
UNCACHED = 0x43FFF000  # the last 4 KB of the SDRAM space; the memory of the test holds 4096 words


async def peek(dut, word):
    dut.i_dbg_word_addr.value = word
    await post_edge(dut)
    return int(dut.o_dbg_word_data.value)


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
    v, _c = await access(
        dut, 0xC0000008
    )  # the UART status, an access that does not use the cache
    for i in range(8):
        assert await peek(dut, 0x100 + 4 * i) == 0x1000 + i, (
            f"line {i} was not written back before the access"
        )


@cocotb.test()
async def test_the_uncached_window_writes_through(dut):
    await start(dut)
    await access(dut, UNCACHED + 0x20, we=True, wdata=0x600D)
    assert await peek(dut, 0xC08) == 0x600D, (
        "a word of the shared window stayed in the cache"
    )
    v, _c = await access(dut, UNCACHED + 0x20)
    assert v == 0x600D


@cocotb.test()
async def test_cache_status_reads_zero_when_idle(dut):
    await start(dut)
    v, _c = await access(dut, CACHE)
    assert v == 0


@cocotb.test()
async def test_flush_with_invalidate_drops_the_lines(dut):
    """A flush keeps the lines (the next read is a hit); a flush with bit 1 set drops them (a miss)."""
    await start(dut)
    await access(dut, SDRAM + 0x600, we=True, wdata=0x77)
    await access(dut, CACHE, we=True, wdata=1)
    await wait_idle(dut)
    _v, hit = await access(dut, SDRAM + 0x600)
    await access(dut, CACHE, we=True, wdata=2)
    await wait_idle(dut)
    assert await peek(dut, 0x180) == 0x77, "the invalidate lost the dirty data"
    v, miss = await access(dut, SDRAM + 0x600)
    assert v == 0x77
    assert miss > hit + 4, (
        f"the read after an invalidate was a hit ({miss} against {hit} clocks)"
    )


async def store_bytes(dut, addr, data, be):
    """One store the way the core makes a byte or half-word one: the byte address, the data, the byte enables."""
    dut.i_addr.value = addr
    dut.i_wdata.value = data
    dut.i_byteena.value = be
    dut.i_wren.value = 1
    dut.i_rden.value = 0
    for _ in range(200):
        await post_edge(dut)
        if int(dut.o_ready.value):
            break
    else:
        raise AssertionError("the store never completed")
    dut.i_mem_advance.value = 1
    await post_edge(dut)
    dut.i_mem_advance.value = 0
    dut.i_wren.value = 0


@cocotb.test()
async def test_a_byte_store_at_an_unaligned_address_changes_only_its_byte(dut):
    """The window the host shares with the program is not cached: a byte store goes out as a
    word-aligned write with the byte enable of its lane (the stdout buffer is written this way).
    """
    await start(dut)
    await store_bytes(dut, UNCACHED + 0x40, 0x11223344, 0xF)
    await store_bytes(
        dut, UNCACHED + 0x41, 0x0000AA00, 0x2
    )  # byte 1 of the word
    await store_bytes(dut, UNCACHED + 0x42, 0x00BB0000, 0x4)  # byte 2
    await store_bytes(dut, UNCACHED + 0x42, 0xCCDD0000, 0xC)  # half-word at +2
    assert await peek(dut, 0xC10) == 0xCCDDAA44, hex(await peek(dut, 0xC10))
