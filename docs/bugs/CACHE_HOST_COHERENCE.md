# A write-back cache hid the program's results from the host

## 1. Summary

The first integration of the data cache in the SDRAM platform was write-back. The host reads the
SDRAM through the debug port, which is behind the cache, so what the program had written was
still in the cache when the host compared the memory with the golden.

| | |
| :--- | :--- |
| Symptom | 87 of the 89 programs failed the golden comparison: the results read as 0 although the mailbox said PASS |
| Cause | the stores stayed in dirty lines of the cache; nothing flushed them before the mailbox was written |
| Fix | the cache of the platform is write-through: a store reaches the SDRAM before it completes |
| Test | the 89 programs of the suite, on the platform with the cache: 88 pass (the other one hits the timeout, which is a speed problem, not a coherence one); `DataCacheWriteThrough` checks the chip after every group of accesses with no flush |

## 2. The mechanism

| Program | How it signals the end | Where a flush could go |
| :--- | :--- | :--- |
| C | `RV32_PASS()` of a generated header | the header could call the flush |
| Assembly | a store of 1 to the mailbox address written in each test | nowhere short of editing every test |

A flush placed in `_exit` helped only the C programs that return from `main`, and not even those
that call the macro. Flushing in software does not scale to programs that write the mailbox
themselves.

## 3. The fix and its price

A write-through cache with write-around (a store that misses does not bring the line in) holds no
dirty data. The host sees every store as soon as it completes, with no flush; loads still hit.
The price is that a store takes the full write to the SDRAM (14 clocks) instead of 2.

The same coherence problem exists in the other direction: the host writes the next program behind
the cache, so the lines of the previous program would be read in place of it. The boot ROM of the
platform writes the cache control with bit 1 set when a test ends, which drops every line, and the
accesses to the shared window (the last 4 KB of the SDRAM) skip the cache.

## 4. How to avoid it

Any master that reads or writes a memory behind a cache is a coherence problem. A debug port that
is not coherent needs a cache that keeps the memory current, an invalidate before the host writes,
and uncached addresses for what both sides use.
