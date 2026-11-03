# A fill of the whole SDRAM was read as a fill of nothing

## 1. Summary

The debug port's fill command takes its length from a count register that was 24 bits wide. A
fill of the whole SDRAM is $2^{24}$ words, which needs 25 bits, so the count wrapped to 0 and the
fill did nothing, without an error.

| | |
| :--- | :--- |
| Symptom | zeroing the RAM from the host finished in 0.6 s and printed OK, and a dump afterwards still held the old data |
| Cause | the count register held bits 23 to 0 of the value sent; $2^{24}$ has bit 24 set and nothing else |
| Fix | the count register is 25 bits wide |
| Test | the count register reads $2^{24}$ after the command that sets it; before the fix it read 0 |

## 2. The mechanism

The SDRAM has $2^{24}$ words of 32 bits. The fill command writes a value to `count` words from an address, and
the count is set by another command whose data field carries it. The register that kept the count
took only the low 24 bits of that field, so the largest value it could hold was $2^{24} - 1$.

| Count asked | Count kept (24 bits) | Count kept (25 bits) |
| ---: | ---: | ---: |
| 64 | 64 | 64 |
| $2^{24} - 1$ | $2^{24} - 1$ | $2^{24} - 1$ |
| $2^{24}$ (the whole SDRAM) | 0 | $2^{24}$ |

A count of 0 means "write nothing" in the fill command, so the host got a quick, silent success.

## 3. Why the tests did not see it

Every simulation fill used a few thousand words. Filling $2^{24}$ words takes about 250 million
controller clocks, which is far too long for a simulation, so the largest legal value was never
exercised. The value is a boundary of the field, and only a test of the boundary finds it: the new test
checks the register after setting $2^{24}$ and $2^{24} - 1$ without running the fill.

## 4. How to avoid it

A count that can equal the size of the thing it counts needs one bit more than an index into
it. The same mistake hides in any "all of it" request, and a command that does nothing for a
bad value should report an error, not success.
