# A byte store to the window the host shares was refused by the bus

## 1. Summary

The first AXI4 master put the byte address of the core on the bus. A store of one byte at an
address that is not a multiple of 4 reached the slave, which refuses addresses not aligned to 4
bytes, so the store never reached the memory.

| | |
| :--- | :--- |
| Symptom | 3 of 89 programs failed on the platform with the cache: the stdout buffer held each character in its own word, one test signalled FAIL, and one read zeros |
| Cause | the core's `sb` and `sh` put the byte address on the port with the byte enable of the lane; the bridge passed the address as it was |
| Fix | the master bridge sends the address aligned to the word; the byte enables say which bytes |
| Test | `ExtAxiCache.test_a_byte_store_at_an_unaligned_address_changes_only_its_byte` fails without the fix; the formal proof of the master states the aligned address |

## 2. The mechanism

On the private bus the word address is bits 25:2 and the low bits are ignored, so a byte address was
harmless. An AXI4 transfer of size 4 bytes must be aligned, and the slave answers SLVERR to one that
is not: the write was dropped and the core, which has no way to receive an error, went on.

## 3. How to avoid it

A bridge between a bus that ignores the low address bits and one that checks them must clear them,
and a refused transfer must be visible somewhere the test looks (here the program results and the
stdout buffer, compared with Spike).
