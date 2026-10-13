# Data cache and AXI4-Lite path to the SDRAM

## 1. The path

```
core port ── dcache ── axil_master_bridge ══ AXI4-Lite ══ axil_slave_word_bridge ── sdram_cpu_bridge ── arbiter ── controller ── chip
```

All blocks left of the SDRAM bridge run on the core clock; the bridge crosses to the memory clock as before. The peripherals of the external interconnect do not go through the cache.

## 2. Data cache

| Property | Value |
| :--- | :--- |
| Size | 4 KB, direct-mapped |
| Line | 16 bytes, four words |
| Write policy | Write-back, write-allocate |
| Address split (64 MB of SDRAM) | Bits 25:12 tag, 11:4 line, 3:2 word |
| Core contract | The access sits on the port while the stage is stopped; `ready` is a level until `mem_advance`; `rdata` changes only on that edge |
| Hit | Ready in 2 clocks (the RAMs read with a register, as block RAMs do) |
| Clean miss | The line's four word reads, one after the other |
| Dirty miss | Four word writes of the old line, then the four reads |
| Reset | All lines invalid |
| `flush` | Writes back every dirty line; the lines stay valid and become clean; `busy` is high until `flush_done` pulses |

AXI4-Lite has no burst, so a line moves as four single-word accesses. Another master that writes the SDRAM (the JTAG debug port) must do it while the cache holds nothing for those addresses: after the reset, or after a `flush` for data the cache still holds dirty.

## 3. AXI4-Lite bridges

| Block | Role |
| :--- | :--- |
| Master bridge | Core word contract to the five channels, one access at a time. AW and W are offered together and accepted in any order; B and R are taken only after the request was accepted. `err` is the high bit of the response |
| Slave bridge | The five channels to the word contract of the SDRAM bridge. Accepts AW and W in any order, reads yield to a write that is offered or half accepted, the response is always OKAY, and nothing new is accepted before the response is taken |

## 4. Verification

| What | How |
| :--- | :--- |
| Cache, bridges and SDRAM together | `make test TEST=DataCache`: reads and writes against a Python copy of the memory, byte enables, hold after ready, evictions, 300 random accesses over conflicting lines, flush; after each flush the chip model must hold exactly the copy |
| Master bridge protocol | `bash formal/axil_master/run.sh`: valid held until ready with a stable payload, one request per access, responses only after the request, ready as a level, bounded wait; covers; mutants that must fail |
| Cache mutants | A write hit that does not set dirty, a write-back that skips a word, and byte enables ignored on a hit each fail the cache tests |

The slave bridge is checked only through the system tests so far.
