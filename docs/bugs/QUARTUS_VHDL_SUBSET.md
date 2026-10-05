# Code that GHDL accepts and Quartus rejects

## 1. Summary

Two VHDL-2008 constructs in the SDRAM controller and its self test passed every GHDL
simulation and then stopped the Quartus compile for the board.

| | |
| :--- | :--- |
| Symptom | Quartus analysis fails: a syntax error on a conditional assignment, then "object maximum is used but not declared" |
| Cause | the Quartus VHDL front end takes a smaller subset of VHDL-2008 than GHDL |
| Fix | write the same logic with an `if` statement and a small function of our own |
| Why the tests did not see it | the simulation tests run only on GHDL; the first Quartus compile of the design was the first time another tool read the files |

## 2. The two constructs

| Construct | GHDL | Quartus |
| :--- | :--- | :--- |
| `signal <= value when condition else other;` as a statement inside a process | accepted (VHDL-2008) | syntax error at the `when` |
| the standard `maximum` function on two numbers | accepted (VHDL-2008) | "used but not declared" |

The conditional assignment was a one-bit output of the self test (the write-enable of a
request); the `maximum` computed the shortest time between two row activations in the
controller.

## 3. The fix

| Where | Before | After |
| :--- | :--- | :--- |
| a request's write flag | one conditional assignment | an `if` with an assignment in each branch |
| the row-to-row time | two nested uses of the standard function | a two-argument function of the same name and meaning declared in the controller, applied the same way |

Neither change alters the behavior: the 18 controller and self-test entity tests give the
same results before and after.

## 4. How to avoid it

Everything that goes to the board is compiled by Quartus, so a design file must stay in the
subset both tools accept. The practical rule for this repository: no conditional or
selected assignment inside a process, and no use of the VHDL-2008 standard
numeric helpers such as `maximum` and `minimum`; declare the few functions needed.
A change to a file that reaches the board is not finished until Quartus compiles it.
