# sdram_arbiter

## 1. Role of the component in the SoC

Arbiter of three masters that share the request interface of the SDRAM controller. The masters are the core's data bridge (A), the core's instruction bridge (I) and the master of the debug port (B). The arbiter serves one request at a time, forwards the request fields to the controller and returns the read data and the acknowledge to the master. When several masters wait, they take turns, and none waits for more than one access of each of the others.

Master I is optional. Left unconnected it never requests. Masters A and I may request a line of four words, and master B moves one word at a time. The context of the debug port is in [sdram_debug.md](sdram_debug.md).

## 2. Interface

The block has one clock input and one reset input, three master ports and one controller port. Every master group repeats the same set of signals with different prefixes.

### 2.1. Clock and reset

| Port | Dir. | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | in | 1 | clock of the arbiter and of the controller |
| `i_rst` | in | 1 | synchronous reset, active at `'1'` |

### 2.2. Signals of each master and of the controller

For the arbiter, the direction of a master's signals is the one in the "Master" column. On the controller side the directions are reversed, because the arbiter is the one that requests.

| Function | Master A | Master I | Master B | Controller | Width | Master direction |
| :--- | :--- | :--- | :--- | :--- | ---: | :--- |
| request toggle | `i_a_req_tog` | `i_ins_req_tog` | `i_b_req_tog` | `o_c_req_tog` | 1 | in |
| acknowledge toggle | `o_a_ack_tog` | `o_ins_ack_tog` | `o_b_ack_tog` | `i_c_ack_tog` | 1 | out |
| write or read | `i_a_we` | `i_ins_we` | `i_b_we` | `o_c_we` | 1 | in |
| word address | `i_a_addr` | `i_ins_addr` | `i_b_addr` | `o_c_addr` | 24 | in |
| write data | `i_a_wdata` | `i_ins_wdata` | `i_b_wdata` | `o_c_wdata` | 32 | in |
| byte enables | `i_a_be` | `i_ins_be` | `i_b_be` | `o_c_be` | 4 | in |
| read data | `o_a_rdata` | `o_ins_rdata` | `o_b_rdata` | `i_c_rdata` | 32 | out |
| line access | `i_a_line` | `i_ins_line` | no port | `o_c_line` | 1 | in |
| write words 1 to 3 | `i_a_wdata_x` | `i_ins_wdata_x` | no port | `o_c_wdata_x` | 96 | in |
| byte enables of words 1 to 3 | `i_a_be_x` | `i_ins_be_x` | no port | `o_c_be_x` | 12 | in |
| read words 1 to 3 | `o_a_rdata_x` | `o_ins_rdata_x` | no port | `i_c_rdata_x` | 96 | out |

The line signals of master A (`i_a_line`, `i_a_wdata_x`, `i_a_be_x`) and every input of master I default to zero, which lets an unconnected master I never generate a request.

## 3. Behavior

### 3.1. Request protocol

A request is the flip of the master's request toggle, with the word on the buses. The acknowledge is the flip of the same master's acknowledge toggle, and the master keeps the buses stable from the request flip until the acknowledge. A request is pending while the request toggle, already synchronized, differs from the acknowledge toggle.

The toggles of masters A and I come from the core clock and pass through a two-flip-flop synchronizer inside the arbiter. The toggle of master B is on the arbiter clock and is read directly. The data buses are not synchronized. The arbiter reads them only after seeing the flip, when they are already stable.

### 3.2. States

| State | Exit condition |
| :--- | :--- |
| `ST_IDLE` | a master has a pending request, which the arbiter picks, copies to the controller outputs, flips `o_c_req_tog` and goes to `ST_BUSY` |
| `ST_BUSY` | `i_c_ack_tog` equal to `o_c_req_tog`, which returns the read data and the acknowledge to the served master and goes back to `ST_IDLE` |

When picking, the arbiter stores the synchronized value of the request toggle of A or I and uses that value as the acknowledge. For master B the acknowledge copies the current request toggle, which does not change during the access. The read data and, for A and I, the read words 1 to 3 are registered on the same clock as the acknowledge and change only at that response. Master B never requests a line, so the arbiter delivers `o_c_line` at `'0'` and the extra words at zero to the controller.

### 3.3. Service order

The master served last goes to the end of the circular order A, I, B. The choice walks the order from the master after the last served and takes the first one with a pending request.

| Last served | Priority in the choice |
| :--- | :--- |
| A, or none after reset | I, B, A |
| I | B, A, I |
| B | A, I, B |

### 3.4. Latency

Let $e$ be the first arbiter edge that samples the new toggle of a master, with no other request in progress.

| Master | Edge at which `o_c_req_tog` flips | Reason |
| :--- | :--- | :--- |
| B | $e$ | the toggle is read directly |
| A or I | $e+2$ | two stages of the synchronizer |

The arbiter acknowledges the master on the edge where it sees the controller response, and can pick again only on the next edge.

Each request occupies the controller for the time of its access plus one exchange edge. The access latencies are in [sdram_ctrl](sdram_ctrl.md). The formal proof of [formal.md](../formal/formal.md) bounds the wait of any master at 20 clocks, with a controller that answers within 4 clocks.

## 4. Integration

In the simulation top of the subsystem the arbiter connects the blocks below, all on the controller clock except the bridges.

| Arbiter port | Connected block |
| :--- | :--- |
| master A | data [sdram_cpu_bridge](sdram_cpu_bridge.md), on the core clock |
| master I | instruction [sdram_cpu_bridge](sdram_cpu_bridge.md), on the core clock; in the top it only reads, with the write data and enables at zero |
| master B | debug master, on the controller clock, commanded through JTAG |
| controller | [sdram_ctrl](sdram_ctrl.md), with `sync_req` false, because the request toggle is born on the same clock |

## 5. Verification

| Verification | Where | What it covers |
| :--- | :--- | :--- |
| formal proof | [props.sv](../../../formal/sdram_arbiter/props.sv), run by [run.sh](../../../formal/run.sh) | one request at a time to the controller with stable buses, every grant carrying the word of a master that was waiting, every answer once and with the toggle of its request, read data equal to the controller's, a wait bounded at 20 clocks, coverage of the situations and mutants that the proof must reject |
| simulation, master A | `SdramSystem` and `SdramDebugPort`, in [sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py) | word and line accesses of the core crossing the arbiter |
| simulation, master B | `SdramDebugPort`, in [sdram_debug_port.py](../../../tests/python/unittests/ram/sdram_debug_port.py) | read, write, fill and simultaneous traffic from the core and the host, including the wait bound of the core during a long fill |
| simulation, subsystem behind the cache and AXI | `DataCache`, `DataCacheWriteThrough` and `AxiSdramSlave` | the same subsystem, driven on the core side by the data cache and by the AXI slave |

The formal properties deal with word 0 (`we`, address, data, enables and read data). The extra line buses are free inputs with no property of their own. The simulation tests of the subsystem do not drive master I, and the formal proof covers it.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
