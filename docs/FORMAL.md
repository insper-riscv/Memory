# Formal verification of the SDRAM arbiter

The arbiter shares the request interface of the SDRAM controller between the core and the debug port. A simulation exercises the cases a testbench thinks of; a formal proof covers every state the block can reach. This document describes what is proved, under which assumptions, and what the proof does not cover.

## 1. The block

Two masters, A (the core's bridge, on another clock) and B (the debug master), send requests to one controller. A request is a flip of a toggle with its word on the buses, and it is answered by a flip of the answer toggle. The arbiter takes one pending request at a time and, when both masters wait, alternates between them. Master A's toggle crosses a two-flop synchronizer inside the arbiter.

## 2. Method

1. GHDL synthesizes the VHDL into a Verilog netlist (`ghdl --synth --out=verilog`).
2. Yosys reads the netlist together with the properties, written in SystemVerilog around it.
3. SymbiYosys runs the SMT solver `z3` on the result.

A copy of the netlist exposes five internal registers (the state, the served master, the last served master, the latched toggle of A and the synchronizer of A) as outputs. The logic is the same; the registers let the proof state invariants of the arbiter, which the induction needs to rule out states that cannot occur.

## 3. Assumptions about the environment

| Environment | Assumption |
| :--- | :--- |
| reset | one reset clock at the start, with every toggle at its reset value |
| a master | flips its toggle only after the previous request was answered, and holds the buses from the flip until the answer |
| the controller | answers only a pending request, with the toggle of that request, within 4 clocks |
| clocks | one clock for all; the synchronizer of A is the arbiter's own two flops |

## 4. Properties

| Property | Check | Result |
| :--- | :--- | :--- |
| at most one request toward the controller at a time, and its buses hold while it is pending | proof by induction | holds |
| every grant carries the word of a master that was waiting | proof by induction | holds |
| every request is answered once, with the toggle of that request, and never both masters in the same clock | proof by induction | holds |
| the read data of a master is the one the controller returned, and changes only with its answer | proof by induction | holds |
| a request is answered within 14 clocks (the controller answers within 4) | bounded check, depth 45 | holds |

The proof by induction has no depth limit. The bounded check covers every run of up to 45 clocks.

## 5. Checks that guard the proof

| Check | Purpose | Result |
| :--- | :--- | :--- |
| cover of seven situations (a grant to each master, a grant with both waiting, an answer to each master, an answer while the other waits) | the assumptions do not rule out the interesting cases | all reached |
| the bound of 13 clocks | the bound of 14 is the smallest that holds | fails, as required |
| a mutant that returns the wrong read data to A | the properties detect a wrong answer | caught |
| a mutant that answers without waiting for the controller | the properties detect a premature answer | caught |

Two further changes to the priority rule between the masters (always A first, always B first) are not caught, because the toggle protocol already prevents starvation: a master can ask again only after it sees the answer, and in that interval the arbiter serves the other one. Within this model and depth, the register that remembers the last served master is not needed for the bound of 14 clocks.

## 6. What the proof does not cover

1. Resets after the first clock.
2. A controller that takes longer than 4 clocks, or that answers without a request.
3. Master A on a clock independent of the arbiter's: the synchronizer is modeled, the clock crossing is not.
4. The bound of 14 clocks beyond depth 45.

## 7. Running

```bash
bash formal/run.sh
```

It needs `ghdl`, `yosys`, `sby` and `z3`, all in the toolchain image of insper-riscv/Infra, and takes a few seconds. The script exits with a failure when any expectation of section 5 changes, including a check that should fail and passes.
