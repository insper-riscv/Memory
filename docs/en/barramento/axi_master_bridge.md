# axi_master_bridge

## 1. Role of the component in the SoC

Converts the external data access of the core, which follows the word contract with `ready` held as a level until `mem_advance`, into AXI4 master transactions. A word access becomes a single-beat transaction of 4 bytes. A line access, used by the data cache, becomes an INCR burst of four 4-byte beats. The bridge keeps one transaction at a time, with no IDs (width 0) and no ordering rules.

## 2. Interface

The component has no generics.

### 2.1. Core side

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | module clock |
| `i_rst` | input | 1 | synchronous reset, active at `'1'` |
| `i_addr` | input | 32 | access address; the 2 low bits are dropped |
| `i_wdata` | input | 32 | write data of word 0 |
| `i_byteena` | input | 4 | byte enables of word 0 |
| `i_rden` | input | 1 | read request |
| `i_wren` | input | 1 | write request; wins over `i_rden` when both are `'1'` |
| `i_mem_advance` | input | 1 | the pipeline advanced in this cycle |
| `o_ready` | output | 1 | access complete, the read data is valid |
| `o_rdata` | output | 32 | word 0 read |
| `i_line` | input | 1 | line access, four words (default `'0'`) |
| `i_wdata_x` | input | 96 | write words 1 to 3, word 1 in the lowest bits |
| `i_byteena_x` | input | 12 | byte enables of words 1 to 3, 4 bits per word |
| `o_rdata_x` | output | 96 | read words 1 to 3, word 1 in the lowest bits |
| `o_err` | output | 1 | the slave answered with an error, or `rlast` was missing on a read; valid only with `o_ready` at `'1'` |

### 2.2. AXI4 side (master)

| Channel | Signals | Direction | Width | Meaning |
| :--- | :--- | :--- | ---: | :--- |
| AW | `o_m_awvalid`, `i_m_awready` | output, input | 1 | write address handshake |
| AW | `o_m_awaddr` | output | 32 | write address, aligned to 4 bytes |
| AW | `o_m_awlen` | output | 8 | beats minus one, 3 for a line and 0 for a word |
| AW | `o_m_awsize` | output | 3 | log2 of the bytes per beat, fixed at `"010"` |
| AW | `o_m_awburst` | output | 2 | burst type, fixed at `"01"` (INCR) |
| AW | `o_m_awprot` | output | 3 | protection, fixed at `"000"` |
| W | `o_m_wvalid`, `i_m_wready` | output, input | 1 | write beat handshake |
| W | `o_m_wdata` | output | 32 | beat data |
| W | `o_m_wstrb` | output | 4 | byte enables of the beat |
| W | `o_m_wlast` | output | 1 | last beat of the burst |
| B | `i_m_bvalid`, `o_m_bready` | input, output | 1 | write response handshake |
| B | `i_m_bresp` | input | 2 | response; bit 1 at `'1'` flags an error |
| AR | `o_m_arvalid`, `i_m_arready` | output, input | 1 | read address handshake |
| AR | `o_m_araddr` | output | 32 | read address, aligned to 4 bytes |
| AR | `o_m_arlen`, `o_m_arsize`, `o_m_arburst`, `o_m_arprot` | output | 8, 3, 2, 3 | same values as the AW fields |
| R | `i_m_rvalid`, `o_m_rready` | input, output | 1 | read beat handshake |
| R | `i_m_rdata` | input | 32 | beat data |
| R | `i_m_rresp` | input | 2 | response; bit 1 at `'1'` flags an error |
| R | `i_m_rlast` | input | 1 | last beat of the burst |

## 3. Behavior

### 3.1. Core-side contract

The access stays on `i_addr`, `i_wdata`, `i_byteena`, `i_rden` and `i_wren` while the memory stage is stopped. `o_ready` rises when the access finishes and stays high until `i_mem_advance`. `o_rdata` and `o_rdata_x` change only on that same edge, because the load still in the write-back stage reads the previous value until then. A write changes neither `o_rdata` nor `o_rdata_x`.

### 3.2. States

| State | Exit condition | Next state |
| :--- | :--- | :--- |
| `ST_IDLE` | `i_rden` or `i_wren` at `'1'` | `ST_WR` if `i_wren`, otherwise `ST_RD` |
| `ST_WR` | `B` accepted with the address and all beats already accepted | `ST_DONE` |
| `ST_RD` | last `R` beat accepted | `ST_DONE` |
| `ST_DONE` | `i_mem_advance` at `'1'` | `ST_IDLE` |

On leaving `ST_IDLE` the address (with the 2 low bits cleared), the data, the byte enables and the kind of access are copied into registers. The AXI fields come out of those registers, so they stay stable while a `valid` is high, whatever the core does. The last beat is 3 when `i_line` is `'1'` and 0 otherwise.

### 3.3. Write

1. `o_m_awvalid` and `o_m_wvalid` rise together, one cycle after the access is captured. The bridge does not wait for the AW handshake to offer W, so W can be accepted before AW.
2. `o_m_awvalid` falls when `i_m_awready` is seen at `'1'`.
3. Each W beat is held until its `i_m_wready`. Beat 0 uses `i_wdata` and `i_byteena`, and beats 1 to 3 use the matching slice of `i_wdata_x` and `i_byteena_x`. `o_m_wlast` is `'1'` on the beat equal to the last one.
4. `o_m_bready` is `'1'` only in `ST_WR` with AW and W already accepted, so a response that arrives earlier is not taken.
5. On accepting B, bit 1 of `i_m_bresp` is stored as the error and the state moves to `ST_DONE`.

### 3.4. Read

1. `o_m_arvalid` rises one cycle after the capture and falls with `i_m_arready`.
2. `o_m_rready` is `'1'` only in `ST_RD` after AR is accepted.
3. Each R beat is stored in its word (word 0 for `o_rdata`, words 1 to 3 for `o_rdata_x`) and the beat counter advances.
4. The state moves to `ST_DONE` on the beat equal to the last one or when `i_m_rlast` comes at `'1'`, whichever happens first.
5. The words read are held and delivered on `o_rdata` and `o_rdata_x` only when `i_mem_advance` arrives in `ST_DONE`.

A read always asks for whole words, and `i_byteena` is not used.

### 3.5. Fixed fields of the transactions

| Field | Value |
| :--- | :--- |
| address | `i_addr` with bits 1 and 0 at zero |
| length | 3 if `i_line`, otherwise 0 |
| size | 4 bytes |
| burst type | INCR |
| protection | unprivileged, secure, data |
| ID, lock and cache | not present on the ports |

### 3.6. Errors

`o_err` is `'1'` in `ST_DONE` when any of these conditions occurred, and is `'0'` outside that state.

| Condition | Channel |
| :--- | :--- |
| bit 1 of `i_m_bresp` at `'1'` (SLVERR or DECERR) | B |
| bit 1 of `i_m_rresp` at `'1'` on any beat | R |
| `i_m_rlast` different from (current beat equal to the last) | R |

### 3.7. Latency

Counted in clock edges from the edge that captures the access, with a slave that accepts and answers without waiting, and derived from the state machine. `o_ready` is `'1'` in the cycle after the last edge in the table.

| Access | Edges |
| :--- | ---: |
| word (read or write) | 3 |
| line (read or write) | 6 |

Each wait of the slave adds one cycle to the phase in which it occurs.

## 4. Integration

- The AXI4 interconnect (`ext_axi_interconnect`, of the Insper-RISC-V repository) instantiates the bridge as the master and connects the AXI output to the router. On each access it chooses between the direct access of the core (word) and the access of the cache (word or line), and ties `i_byteena_x` to all bits at `'1'`. The `o_err` output is not used.
- The simulation top of the data cache connects the bridge directly to a word slave, with no router.
- The word contract side is the same as that of a core memory bridge, and the AXI side is accepted by the AXI router of the Insper-RISC-V repository and by `axi_slave_word_bridge`.

See [dcache_axi.md](dcache_axi.md) for the full data path and [AXI_UNALIGNED_BYTE_STORE.md](../bugs/AXI_UNALIGNED_BYTE_STORE.md) for why the address leaves aligned to the word.

## 5. Verification

| Coverage | Where |
| :--- | :--- |
| bridge with the cache and the word slave, end to end | tests `DataCache` and `DataCacheWriteThrough` in `tests/python/tests.json` |
| formal proof | [formal/axi_master](../../../formal/axi_master/props.sv), run by `bash formal/axi_master/run.sh` |

The formal proof uses the netlist synthesized from the VHDL, treats the core and the slave as free inputs bound by contract assumptions, and guarantees the following.

1. `valid` is held until the matching `ready`, with stable content (address, protection, data, `wstrb` and `wlast`).
2. Each access produces a single request, with an aligned address and length 3 or 0 according to `i_line`, and a write and a read are never active together.
3. Size 4 bytes, INCR and zero protection on every transaction, and `wlast` exactly on the last beat.
4. The words 1 to 3 sent are the ones the core gave, and `bready` and `rready` rise only after the request is accepted.
5. `o_ready` stays as a level until `i_mem_advance`, `o_rdata` and `o_rdata_x` change only on that edge, and `o_err` implies `o_ready`.
6. An access ends within 20 clocks when the slave accepts and answers within 3 clocks per channel and the core advances the pipeline the clock after `o_ready`.

The safety proof is by induction with no depth limit. Seven cover scenarios (word and line reads and writes, W still offered after AW is accepted, AW still offered after W is accepted, and an error response) must be reachable, and six mutants of the VHDL must fail (B accepted without waiting for AW and W, wrong `wstrb`, W without waiting for `wready`, `ready` without `i_mem_advance`, `wlast` always at `'1'` and wrong `arlen`). The general method is in [formal.md](../formal/formal.md).

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
