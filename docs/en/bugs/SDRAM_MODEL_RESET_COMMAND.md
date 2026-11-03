# The chip model rejected a command that the controller drove on the edge of its reset

## 1. Summary

When one test ended and the next one reset the SDRAM system, the chip model sometimes failed the
run with "first command before the power-up wait", although the controller was correct.

| | |
| :--- | :--- |
| Symptom | the second or third test of a file failed at the first clock of its reset, only for some timings of the previous test |
| Cause | the controller's registers still drove the command of the previous run on the first clock edge of the reset, and the model had just restarted its power-up wait on that same edge |
| Fix | the model ignores commands on an edge where `reinit` is high |
| Test | the data cache tests (7 tests in one file, resets between them) failed before the fix and pass after; the SDRAM system, debug port and BIST tests are unchanged |

## 2. The mechanism

The model restarts its power-up timer when `reinit` is high, and in the same clock it looks at the
command pins. The controller resets synchronously, so on that first edge its outputs still hold
the command of the previous run, which is a refresh or an access, never a NOP. A real chip
ignores whatever is on the pins during its own power-up; the model counted the command as the first
one of the new run, at time zero.

Which tests failed depended on how long the previous test ran, so the SDRAM tests written before
did not show it.

## 3. How to avoid it

A model of a part that is being reset must not judge the pins on the edge of the reset. A test
bench that resets a design between tests must not rely on the design being idle at that edge.
