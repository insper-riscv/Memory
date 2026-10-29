# The cache and the core's own accesses fought over the AXI4-Lite master

## 1. Summary

The cache's line traffic and the core's accesses that skip the cache (peripherals, the shared
window of the SDRAM) use the same AXI4-Lite master. The first arbitration chose the owner by the
address on the core's port, and three different failures came out of it, all found by the cache
control tests.

| | |
| :--- | :--- |
| Symptom | a flush never ended, a read that waited for a flush never completed, and the core saw `ready` for accesses it had not made |
| Cause | the master's owner followed the core's address, not who had an access under way |
| Fix | the core owns the master only while it has an access on the port and either already owns it or no flush runs; the cache's `d_ready` and the core's `ready` are each gated by the owner |
| Test | `ExtAxiCache`: the four tests hung or failed before the fix and pass after |

## 2. The three failures

| # | Mechanism | Effect |
| :--- | :--- | :--- |
| 1 | The master was given to the core whenever the address on its port was a peripheral one, including when the port only rested there with no access | After a write to the cache control, the address stayed on the port; the flush's write-backs never reached the master and the flush hung |
| 2 | An access of the core was granted the master and then held back by the running flush, while the flush needed the same master | The access and the flush waited for each other |
| 3 | The core's `ready` was the master's `ready` whenever the address was a peripheral one | The master finished a write-back of the cache and the core took it as the answer to its own access |

## 3. The fix

One register tells whether the core's access has the master (set when it is granted, cleared when
its `mem_advance` arrives). The core is granted the master only if it has an access on the port
and either it already owns the master or the cache is idle. A flush that starts while the core's
access runs waits for that access to end; an access that comes while the flush runs waits for the
flush. The cache's `d_ready` and the core's `ready` are masked by the owner, so a master that
answers one of them is never taken as the answer to the other.

## 4. How to avoid it

An arbiter must decide by who has a request under way, never by a value that can rest on the bus
after the request ends. Every answer signal shared by two requesters needs the same mask as the
request it answers.
