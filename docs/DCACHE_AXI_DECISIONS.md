# Decisions of the data cache and the AXI4-Lite bus

## 1. Choices

| Decision | Chosen | Why | Cost |
| :--- | :--- | :--- | :--- |
| Bus for the core | AXI4, one master, one transaction in flight, INCR bursts of four beats for lines, IDs of width 0 | Third-party IP speaks AXI; with one master there is no need for IDs or reordering; a burst is one request to the controller | Every single access pays for five channels |
| Router | No clock of delay, W waits for its AW, DECERR where no slave is mapped | The core pays no extra clock per access; a bad address answers instead of hanging | One transaction per direction |
| Cache organization | 4 KB, direct-mapped, 16-byte lines | One block RAM for the tags and four for the data in the FPGA; a line is four words | Conflict misses between addresses 4 KB apart |
| Write policy of the platform | Write-through, write-around | The host reads the SDRAM behind the cache with no flush (see `bugs/CACHE_HOST_COHERENCE.md`) | A store takes the full SDRAM write |
| Write policy of the module | Write-back is the default of the `dcache` module | It is what a core without a debug port behind the cache would use | Needs a flush before anything else reads the memory |
| Uncached addresses | The peripheral window and the last 4 KB of the SDRAM | Peripherals have side effects on reads; the shared window is read and written by the host | Words there never hit |
| Cache control | Peripheral 7: a write flushes, bit 1 also invalidates, a read gives busy | No new instruction or CSR in the core | The program or the boot ROM must write it |
| Flush | Sweep of the 256 lines, served before any waiting access | Simple, and no access runs while lines move | 768 clocks at least, each time |
| Hit latency | Two clocks | The RAM has a registered read, as FPGA block RAMs do; one clock needs a combinational read | Every load pays two clocks |

## 2. What the measurement says

Clocks of the core (30 ns) on the SDRAM platform, from the request to the advance of the pipeline:

| Access | Direct bridge | Cache and AXI4 |
| :--- | ---: | ---: |
| Read | 8 | 3.4 average when the data is reused, 2 to 3 for a hit |
| Write | 6 | 16.4 (write-through) |
| Read of the window that skips the cache | 8 | 13 |

Time of whole programs, in ticks of the base clock without the 20 000 of the SDRAM power-up, against
the same program with the internal RAM:

| Programs | Direct bridge | Cache, AXI4-Lite (lines as four words) | Cache, AXI4 (lines as bursts) |
| :--- | ---: | ---: | ---: |
| 89 of the test suite, median | 1.81 | 2.86 | 2.97 |
| Sum of an array of 256 words, 16 passes | 233 300 | not measured | 214 800 |
| Copy of 128 words, 8 passes | 113 900 | not measured | 167 700 |

The burst does what it should (a read miss is 24 clocks against 56 as four words in the unit
simulation, and a line read through the bus is 13 clocks against 36), but it does not make programs faster, for two reasons
that do not depend on the burst:

1. At this core clock the SDRAM answers a word in 8 clocks, close to a cache hit, so there is little
   to save on a read. The cache pays when the core is much faster than the memory.
2. Every store goes to the SDRAM through five channels and costs 16.4 clocks against 6 on the direct
   bridge. Programs that write (a copy, the clearing of `.bss`, the stdout buffer) lose more than
   their reads gain; the suite's programs are short and mostly write.

## 3. What would change the result

| Change | Effect |
| :--- | :--- |
| A faster core clock (the SDRAM answer stays at about 60 ns) | Hits save more clocks per access; the break-even is a core several times faster than the memory |
| Fewer clocks on a single access through the bus (the master takes the request in the clock it arrives, the slave takes AW and W together and answers in the clock of the memory's ready) | About 5 of the 7 extra clocks of a single access |
| A write-back cache that flushes the dirty lines by itself when the program stores to the window it shares with the host, with a flush that visits only the dirty lines | A store to a line in the cache costs 2 to 3 clocks, and the host still sees the results |
| A store buffer in front of the write-through | The core does not wait for the SDRAM write, but a long run of stores is limited by the memory's rate |
