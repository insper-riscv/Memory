# Decisions of the data cache and the AXI4-Lite bus

## 1. Choices

| Decision | Chosen | Why | Cost |
| :--- | :--- | :--- | :--- |
| Bus for the core | AXI4-Lite, one master, one transaction in flight | Third-party IP speaks AXI; with one master and no D$ burst there is no need for IDs or reordering | A line fill is four single-word accesses |
| Router | No clock of delay, W waits for its AW, DECERR where no slave is mapped | The core pays no extra clock per access; a bad address answers instead of hanging | One transaction per direction |
| Cache organization | 4 KB, direct-mapped, 16-byte lines | One block RAM for the tags and four for the data in the FPGA; a line is four words | Conflict misses between addresses 4 KB apart |
| Write policy of the platform | Write-through, write-around | The host reads the SDRAM behind the cache with no flush (see `bugs/CACHE_HOST_COHERENCE.md`) | A store takes the full SDRAM write |
| Write policy of the module | Write-back is the default of the `dcache` module | It is what a core without a debug port behind the cache would use | Needs a flush before anything else reads the memory |
| Uncached addresses | The peripheral window and the last 4 KB of the SDRAM | Peripherals have side effects on reads; the shared window is read and written by the host | Words there never hit |
| Cache control | Peripheral 7: a write flushes, bit 1 also invalidates, a read gives busy | No new instruction or CSR in the core | The program or the boot ROM must write it |
| Flush | Sweep of the 256 lines, served before any waiting access | Simple, and no access runs while lines move | 768 clocks at least, each time |
| Hit latency | Two clocks | The RAM has a registered read, as FPGA block RAMs do; one clock needs a combinational read | Every load pays two clocks |

## 2. What the measurement says

On the 89 programs of the test suite, the SDRAM platform with the cache and the AXI4-Lite bus runs
1.21 to 1.67 times slower than the SDRAM bridge without them (median 1.58), and 2.86 times slower
than the internal RAM (median), against 1.81 for the bridge alone. A read miss is 56 clocks, a
hit 2, a write-through store 14.

The programs are short and start with a cold cache, so almost every access is a first access. The
cost of a miss is four word accesses, each opening the row of the SDRAM, which the controller
does for every word it serves.

## 3. What would change the result

| Change | Effect |
| :--- | :--- |
| A burst on the line fill (AXI4 INCR, four beats) with a controller that serves the 16 bytes in one row opening | A miss near 20 clocks instead of 56 |
| A store buffer in front of the write-through | The core does not wait for the SDRAM write |
| A bigger program or one with loops over data | Hits pay for the misses; the suite has almost none |
