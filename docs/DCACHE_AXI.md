# Data cache and AXI4 external bus

## 1. The path

```
                     ┌─ dcache ─┐
core port ── split ──┤          ├── axi_master_bridge ── axi_router ──┬── axi_slave_word_bridge ── sdram_cpu_bridge ── arbiter ── controller ── chip
 (bit 31)            └─ direct ─┘                                       └── axi_slave_periph_bank ── p_* (eight peripheral slots)
```

Addresses with bit 31 clear are the SDRAM space and go through the cache, except its last 4 KB (0x43FFF000 to 0x43FFFFFF); addresses with bit 31 set are the peripheral window (bits 30:28 the peripheral, 9:2 the word). Both exceptions go straight to the master, uncached. The last 4 KB hold the words the host shares with the program (tohost, fromhost, stdout), which the host reads and writes through the debug port of the SDRAM, behind the cache. All blocks left of the SDRAM bridge run on the core clock; the bridge crosses to the memory clock as before.

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
| Clean miss | One line request (a burst of four beats on the bus), then the four words into the RAM |
| Dirty miss | The four words of the old line out of the RAM, one line write request, then the line request above |
| `WRITE_THROUGH` (generic) | Every store also goes to the memory before it completes and a store that misses does not bring the line in, so no line is ever dirty and the memory always holds what the core wrote. A debug port that reads the SDRAM behind the cache (the host of the SDRAM platform) needs it |
| Reset | All lines invalid |
| `flush` | A request, served before any access that waits: writes back every dirty line (a sweep of the 256 lines, three clocks for each clean one); the lines stay valid and become clean; `busy` is high from the clock after the request until `flush_done` pulses |

AXI4-Lite has no burst, so a line moves as four single-word accesses. Another master that writes the SDRAM (the JTAG debug port) must do it while the cache holds nothing for those addresses: after the reset, or after a `flush` for data the cache still holds dirty.

## 3. AXI4 bridges

The bus carries the burst fields (length, size, burst type) and the last flags of W and R. IDs have width 0 (they are left out), and a transaction is one at a time, so there are no ordering rules. Every beat is 4 bytes; the address of a byte or half-word access goes out aligned to the word, and the byte enables say which bytes.

| Block | Role |
| :--- | :--- |
| Master bridge | The core's word contract, with a line extension, to the five channels. A word is one beat; a line (aligned to 16 bytes) is one INCR burst of four beats. AW and W are offered together, B and R are taken only after the request was accepted, and a read whose last beat does not carry rlast is reported in `err` |
| SDRAM slave bridge | The five channels to the word contract of the SDRAM bridge. A burst of four beats aligned to 16 bytes is one line access of the controller; any other INCR burst is one word access per beat. A size other than 4 bytes, a burst type other than INCR, or an address not aligned to 4 bytes is answered with SLVERR after all its beats are consumed (a read gives zeros), and nothing reaches the memory. W is taken only after AW |
| Peripheral bank | The five channels to the peripheral `p_*` port: one pulse of `p_we` or `p_re` per access, the read data taken in the clock of the pulse. Only a single beat is served; a longer burst is answered with SLVERR, consumed or given as zeros. A window nobody answers reads 0 and a write has no effect, both with OKAY |
| Router | One master, two slaves, no clock of delay. 0x40000000 to 0x43FFFFFF is the SDRAM, 0x80000000 and above the peripherals, anything else is accepted, all its beats consumed or given as zeros, and answered with DECERR. A W that arrives before its AW waits, and the beats after the first follow the same decision up to the one with wlast; B and R return from the slave that took the request |

The SDRAM controller moves the four words of a line in one opening of the row (see `SDRAM_LINE.md`), so the burst of the bus is one request to the controller, not four.

## 4. Verification

| What | How |
| :--- | :--- |
| Cache, bridges and SDRAM together | `make test TEST=DataCache`: reads and writes against a Python copy of the memory, byte enables, hold after ready, evictions, 300 random accesses over conflicting lines, flush; after each flush the chip model must hold exactly the copy |
| Same tests as the private bus | `make test TEST=ExtAxiBus` runs the tests of the private external bus (UART bytes in order, stopped pipeline pops once, full queues, unmapped window reads 0, load data stays while the next access runs) on this bus, with a word memory behind the SDRAM slave |
| Router | `make test TEST=AxiRouter`: both slaves for writes and reads, bursts of four beats whole to one slave, W before AW, DECERR below, between and above the windows for single beats and bursts, back-to-back; mutants (DECERR answered OKAY, W taken before its AW, a wrong decode) fail |
| Master bridge protocol | `bash formal/axi_master/run.sh`: valid held until ready with a stable payload, one request per access, burst length and wlast on the right beats, the words after the first are what the core gave, responses only after the request, ready as a level, bounded wait; covers; mutants that must fail (including a wrong wlast and a wrong length). Unbounded proof by induction |
| Slave bridge protocol | `bash formal/axi_slave/run.sh` (about ten minutes): handshakes, beats and the last flag, one transaction at a time, a request that is not served never reaches the memory, bounded wait; covers; 6 mutants. The safety proof is bounded to 55 clocks from reset (transactions of up to four beats); the payload is checked by the system test below |
| SDRAM slave with the chip | `make test TEST=AxiSdramSlave`: a line burst is written and read whole, byte strobes of each beat, bursts of 1, 2, 3, 5 and 8 beats aligned or not, WRAP, FIXED, other sizes and unaligned addresses are SLVERR and never reach the chip, a line read is faster than four single reads |
| Cache mutants | A write hit that does not set dirty, a write-back that skips a word, and byte enables ignored on a hit each fail the cache tests |

The peripheral bank and the router are checked by the tests above and have no formal properties yet.

## 5. Cost of the path

Measured on the simulation of the SDRAM platform (core clock 30 ns, SDRAM clock 7 ns), in clocks of the core, from the request to the advance of the pipeline:

| Access | Direct bridge (no cache) | Cache and AXI4 |
| :--- | ---: | ---: |
| Read in the SDRAM space | 8 | 3.4 on average in a loop that reuses a 1 KB array (a hit is 2 to 3) |
| Write in the SDRAM space | 6 | 16.4 (write-through, one beat) |
| Read in the window that skips the cache | 8 | 13 |

In the unit simulation (core clock 8 times slower than the SDRAM clock) a read miss takes 24 clocks, against 56 when the line moved as four AXI4-Lite words.

The SDRAM answers a word in about the time of a cache hit at this core clock, so the cache saves little on reads and the bus costs more on every write and every access that skips the cache. Programs that read data they reuse run a little faster; programs that write, or read once, run slower (see `DCACHE_AXI_DECISIONS.md`).
