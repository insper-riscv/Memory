# The debug port's status read started a command of its own

## 1. Summary

The first version of the SDRAM debug port let the host poll for the end of a command by
shifting a "status" command. Every poll was itself a command, so the status it returned
never became "idle".

| | |
| :--- | :--- |
| Symptom | every command appeared to run forever: the busy flag stayed set on every shift |
| Cause | a status shift sent a new command, and the status is read before the previous command's answer reaches the JTAG clock domain |
| Fix | a status shift sends nothing; only commands that do something start a transaction |
| Test | every debug-port test (write, read, fill, next-word) failed with "the debug command never finished" before the fix and passes after |

## 2. The mechanism

The debug register is shifted on the JTAG clock, which is far slower than the clock of the
SDRAM controller that runs the command. The answer of a command ("done") crosses to the
JTAG clock through two flip-flops, and those only advance on JTAG clock edges.

1. The host shifts a command. When the shift ends, the command is sent and the status
   becomes busy.
2. The controller side finishes within nanoseconds and signals done.
3. The host shifts again to read the status. The status is captured at the start of that
   shift, only one or two JTAG clock edges after the command was sent, so the done signal
   has not crossed yet: busy is still shown.
4. That poll was itself a command ("status" was an ordinary op). When its shift ended it
   was sent, and busy came back at once.

The cycle repeats on every poll: the status read always happened right after the previous
poll's command, never long enough after.

## 3. The fix

A shift whose op is 0 is only a way to read the status: it sends nothing. The commands that
do something (read, write, fill, set count, read next, write next) are sent as before. A
poll then costs no transaction, and the 64 JTAG clocks of the shift give the done signal
time to cross, so the second shift after a command shows busy cleared.

The first shift after a command can still show busy; the documentation says so, and the
host polls until it clears.

## 4. How to avoid it

A status read that must be free of side effects cannot be an ordinary command. Any value
that crosses from a fast clock to a slow one is only valid after the slow clock has run a
few edges, so a capture taken at the very start of an access is stale by construction;
the protocol must allow for a second read.
