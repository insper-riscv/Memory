# The JTAG UART lost bytes and ran a command after a reset

## 1. Summary

The first version of the JTAG UART let the host read the answer of a command at the start of the
next scan. Two faults showed up in simulation, both from the same cause: the JTAG clock runs only
while a scan is in progress.

| | |
| :--- | :--- |
| Symptom | bytes the core sent never reached the host, or showed up twice; after a core reset, a byte from before the reset appeared in the receive queue |
| Cause | the answer and the done flag cross to the JTAG clock through flip-flops that only advance on JTAG clock edges, and the clock was stopped between scans |
| Fix | the scan logic keeps the answer in its own register at the end of a scan, shows it once at the next capture, and the core side drops a command that was pending at reset |
| Test | the transmit tests (bytes in order, the queue full, an answer shown once) failed before the fix, and the receive tests failed after a reset |

## 2. The mechanism

1. Every accepted scan runs a command on the core side: it takes up to four bytes out of the
   transmit queue and writes them to an answer register.
2. The core side finishes within nanoseconds and flips a done flag. That flag reaches the JTAG
   clock through two flip-flops, which move only when the JTAG clock ticks.
3. The next scan captures its answer in its first clock edge. At that point the done flag has not
   crossed yet, so the capture shows the previous answer, or none.
4. The command of that next scan then runs and overwrites the answer register. The answer that
   was never captured is lost, and an answer captured twice shows its bytes twice.

The second fault has the same root. The JTAG side is not reset with the core: a command that was
issued before the reset, and not yet run, still differs from the done flag afterwards, so the
core side ran it as if the host had just sent it.

## 3. The fix

1. At the end of a scan, when the done flag has crossed (the shift is many JTAG clock edges long,
   so it always has), the scan logic copies the answer into its own register, before it issues
   the next command. The capture of the following scan reads that register, and clears its bytes
   so an answer is shown once.
2. The cost is one scan of latency: a scan shows the answer to the command of the scan before the
   previous one. A host that keeps scanning loses nothing.
3. At reset the core side sets its done flag equal to the command flag it sees, so a command that
   was pending before the reset is not run.

## 4. How to avoid it

A value that crosses into a clock that is not free-running is only valid after that clock has
ticked. Do not capture it, and do not let its source change, until the crossing is known to be
complete; take a copy on the slow side first. Any state on the slow side that is not reset with
the fast side needs an explicit rule for what a reset does to a transfer in flight.
