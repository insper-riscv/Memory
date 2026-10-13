# The router could send one write data beat twice

## 1. Summary

The first version of the AXI4-Lite router offered W to the slave in the clock in which AW was
offered, before knowing that AW had been taken. If the slave took W and not AW in that clock, the
router had no record of the W handshake and offered W again after AW was accepted.

| | |
| :--- | :--- |
| Symptom | none in any test: found by reading the handshake rules before the router had tests |
| Cause | the write data followed the address decision, but its handshake was recorded only together with the address handshake |
| Fix | W is offered only in the clock in which the AW handshake completes, or after it; the W handshake is recorded in the same clock as AW's, or in its own state afterwards |
| Test | `AxilRouter`: W before AW, W with AW and back-to-back writes; the mutant that offers W with an AW that is not yet taken fails |

## 2. The mechanism

A slave with `awready` low and `wready` high accepts W alone, which the specification allows. A
router that offers W in every clock in which AW is offered then completes the W handshake without
a record of it. When AW is finally accepted, the router believes W is still pending and offers it
again; the slave receives two data beats for one address.

## 3. How to avoid it

Every channel handshake that can complete on its own must be recorded in the clock in which it
completes. A decision taken from one channel (here the address) must not let another channel
complete before the decision is stored.
