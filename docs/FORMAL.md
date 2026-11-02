# Formal verification of the SDRAM arbiter

The arbiter shares the request interface of the SDRAM controller between the core's data bridge, the core's instruction bridge and the debug port. A simulation exercises the cases a testbench thinks of; a formal proof covers every state the block can reach. This document describes what is proved, under which assumptions, and what the proof does not cover.

## 1. The block

Three masters send requests to one controller: A (the core's data bridge, on another clock), I (the core's instruction bridge, on the same clock as A) and B (the debug master). A request is a flip of a toggle with its word on the buses, and it is answered by a flip of the answer toggle. The arbiter takes one pending request at a time and, when several masters wait, serves them in turn: the master served last goes to the end of the order A, I, B. The toggles of A and I cross a two-flop synchronizer each, inside the arbiter.

## 2. Method

1. GHDL synthesizes the VHDL into a Verilog netlist (`ghdl --synth --out=verilog`).
2. Yosys reads the netlist together with the properties, written in SystemVerilog around it.
3. SymbiYosys runs the SMT solver `z3` on the result.

A copy of the netlist exposes nine internal registers (the state, the served master and the last served master, as two flags each, and the latched toggle and the synchronizer of A and of I) as outputs. The logic is the same; the registers let the proof state invariants of the arbiter, which the induction needs to rule out states that cannot occur.

## 3. Assumptions about the environment

| Environment | Assumption |
| :--- | :--- |
| reset | one reset clock at the start, with every toggle at its reset value |
| a master | flips its toggle only after the previous request was answered, and holds the buses from the flip until the answer (A, I and B alike) |
| the controller | answers only a pending request, with the toggle of that request, within 4 clocks |
| clocks | one clock for all; the synchronizers of A and I are the arbiter's own two flops |

## 4. Properties

| Property | Check | Result |
| :--- | :--- | :--- |
| at most one request toward the controller at a time, and its buses hold while it is pending | proof by induction | holds |
| every grant carries the word of a master that was waiting | proof by induction | holds |
| every request is answered once, with the toggle of that request, and never two masters in the same clock | proof by induction | holds |
| the read data of a master is the one the controller returned, and changes only with its answer | proof by induction | holds |
| a request of any of the three masters is answered within 20 clocks (the controller answers within 4) | bounded check, depth 60 | holds |

The proof by induction has no depth limit. The bounded check covers every run of up to 60 clocks.

## 5. Checks that guard the proof

| Check | Purpose | Result |
| :--- | :--- | :--- |
| cover of the situations (a grant to each master, a grant with all three waiting and the instruction bridge served, an answer to each master, an answer while another waits) | the assumptions do not rule out the interesting cases | all reached |
| the bound of 19 clocks | the bound of 20 is the smallest that holds | fails, as required |
| a mutant that returns the wrong read data to A | the properties detect a wrong answer | caught |
| a mutant that answers without waiting for the controller | the properties detect a premature answer | caught |

## 6. What the proof does not cover

1. Resets after the first clock.
2. A controller that takes longer than 4 clocks, or that answers without a request.
3. Master A on a clock independent of the arbiter's: the synchronizer is modeled, the clock crossing is not.
4. The bound of 20 clocks beyond depth 60.

## 7. Running

```bash
bash formal/run.sh   # the arbiter alone
make formal          # the arbiter and the AXI master and slave bridges, at once
```

It needs `ghdl`, `yosys`, `sby` and `z3`, all in the toolchain image of insper-riscv/Infra. The script exits with a failure when any expectation of section 5 changes, including a check that should fail and passes.

## 8. Parallel execution and verdicts

The proofs of a script are independent, so they run side by side, and `make formal` also runs the three blocks side by side. At most `FORMAL_JOBS` proofs run at the same time (default: the number of cores, up to 8), shared by all the blocks. The results are printed in a fixed order, whatever order the proofs end in.

SymbiYosys ends with a code that tells a verdict from a failure of the tool:

| Exit code | Meaning | Result |
| :--- | :--- | :--- |
| 0 | the property holds, or the goal is covered | PASS |
| 2 | a counterexample exists, or a goal cannot be covered | FAIL |
| any other | the tool reached no verdict (4 unknown, 8 timeout, 16 error) | ERROR |

An expected FAIL only holds for the code 2. An ERROR fails the run with the exit code and the log of the proof, so a broken solver or netlist is never taken for a defect that was caught.
