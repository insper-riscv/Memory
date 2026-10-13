# Data cache and AXI4-Lite external bus

## 1. The path

```
                     ┌─ dcache ─┐
core port ── split ──┤          ├── axil_master_bridge ── axil_router ──┬── axil_slave_word_bridge ── sdram_cpu_bridge ── arbiter ── controller ── chip
 (bit 31)            └─ direct ─┘                                       └── axil_slave_periph_bank ── p_* (eight peripheral slots)
```

Addresses with bit 31 clear are the SDRAM space and go through the cache, except its last 4 KB (0x43FFF000 to 0x43FFFFFF); addresses with bit 31 set are the peripheral window (bits 30:28 the peripheral, 9:2 the word). Both exceptions go straight to the master, uncached. The last 4 KB hold the words the host shares with the program (mailbox, tohost, fromhost, go flag, stdout), which the host reads and writes through the debug port of the SDRAM, behind the cache. All blocks left of the SDRAM bridge run on the core clock; the bridge crosses to the memory clock as before.

The core side of the whole is the contract of the private external bus: the access sits on the port while the stage is stopped, `ready` is a level until `mem_advance`, and `rdata` stays on the last completed load until the next one completes, because the load in the last stage still reads it while the next access is on the port. The peripheral side is the same `p_*` port with one pulse per access, so a peripheral (the JTAG UART) is the same VHDL on either bus.

Peripheral 7 (0xF0000000) is the cache's control: a write to its first word starts a flush, and a read gives 1 while a flush is under way, 0 otherwise. With bit 1 of the value set it also drops every line afterwards, which a boot ROM does when a test ends, before the host loads the next program behind the cache. An access that does not use the cache waits while a flush runs; the core's access that already owns the master when a flush starts finishes first, and the flush goes on after it.

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
| `WRITE_THROUGH` (generic) | Every store also goes to the memory before it completes and a store that misses does not bring the line in, so no line is ever dirty and the memory always holds what the core wrote. A debug port that reads the SDRAM behind the cache (the host of the SDRAM platform) needs it |
| Reset | All lines invalid |
| `flush` | A request, served before any access that waits: writes back every dirty line (a sweep of the 256 lines, three clocks for each clean one); the lines stay valid and become clean; `busy` is high from the clock after the request until `flush_done` pulses |

AXI4-Lite has no burst, so a line moves as four single-word accesses. Another master that writes the SDRAM (the JTAG debug port) must do it while the cache holds nothing for those addresses: after the reset, or after a `flush` for data the cache still holds dirty.

## 3. AXI4-Lite bridges

| Block | Role |
| :--- | :--- |
| Master bridge | Core word contract to the five channels, one access at a time. AW and W are offered together and accepted in any order; B and R are taken only after the request was accepted. `err` is the high bit of the response |
| Slave bridge | The five channels to the word contract of the SDRAM bridge. Accepts AW and W in any order, reads yield to a write that is offered or half accepted, the response is always OKAY, and nothing new is accepted before the response is taken |
| Peripheral bank | The five channels to the peripheral `p_*` port: one pulse of `p_we` or `p_re` per access, the read data taken in the clock of the pulse. A window nobody answers reads 0 and a write has no effect, both with OKAY |
| Cache control | `make test TEST=ExtAxiCache`: a cached write reaches the memory only with the flush, the flush holds back an access that does not use the cache until it ends, the shared window writes through, a flush with bit 1 drops the lines |
| Write-through | `make test TEST=DataCacheWriteThrough`: a store is in the chip when it completes, a missing store does not allocate, a hitting store updates the line, 300 random accesses with the chip checked every 25 without any flush |
| Router | One master, two slaves, no clock of delay. 0x40000000 to 0x43FFFFFF is the SDRAM, 0x80000000 and above the peripherals, anything else is accepted and answered with DECERR (reads give 0). A W that arrives before its AW waits; B and R return from the slave that took the request |

An access through the peripheral bank takes more clocks than on the private bus (the five channels and the router), and a miss costs the line's four word accesses; a hit is two clocks.

## 4. Verification

| What | How |
| :--- | :--- |
| Cache, bridges and SDRAM together | `make test TEST=DataCache`: reads and writes against a Python copy of the memory, byte enables, hold after ready, evictions, 300 random accesses over conflicting lines, flush; after each flush the chip model must hold exactly the copy |
| Same tests as the private bus | `make test TEST=ExtAxiBus` runs the tests of the private external bus (UART bytes in order, stopped pipeline pops once, full queues, unmapped window reads 0, load data stays while the next access runs) on this bus, with a word memory behind the SDRAM slave |
| Router | `make test TEST=AxilRouter`: both slaves for writes and reads, W before AW, DECERR below, between and above the windows, back-to-back; mutants (DECERR answered OKAY, W taken before its AW, a wrong decode) fail |
| Master bridge protocol | `bash formal/axil_master/run.sh`: valid held until ready with a stable payload, one request per access, responses only after the request, ready as a level, bounded wait; covers; mutants that must fail |
| Slave bridge protocol | `bash formal/axil_slave/run.sh`: the same kind of properties, the payload passed on is what was accepted, one transaction at a time, bounded wait; covers; 5 mutants |
| Cache mutants | A write hit that does not set dirty, a write-back that skips a word, and byte enables ignored on a hit each fail the cache tests |

The peripheral bank and the router are checked by the tests above and have no formal properties yet.

## 5. Cost of the path

Measured on the simulation of the SDRAM system (clocks of the core):

| Access | Clocks |
| :--- | ---: |
| Read hit | 2 |
| Read miss (the four words of the line, one AXI4-Lite access each) | 56 |
| Store, write-back, line present | 2 |
| Store, write-through | 14 |

A line fill costs four single-word accesses because AXI4-Lite has no burst and the controller opens the row for each word.
