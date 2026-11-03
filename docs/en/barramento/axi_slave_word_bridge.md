# axi_slave_word_bridge

## 1. Role of the component in the SoC

AXI4 slave placed in front of a memory that follows the word contract of the core (access held until `ready`, advance through `mem_advance`), with the line extension of that contract. It translates INCR bursts of 4-byte beats into memory accesses, one transaction at a time and with no IDs (width 0). In the SoC it sits behind the memory port of the router, and the memory behind it is the SDRAM bridge.

## 2. Interface

The component has no generics.

### 2.1. Control

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | module clock |
| `i_rst` | input | 1 | synchronous reset, active at `'1'` |

### 2.2. AXI4 slave port

| Channel | Signals | Direction | Width | Meaning |
| :--- | :--- | :--- | ---: | :--- |
| AW | `i_s_awvalid`, `o_s_awready` | input, output | 1 | write address handshake |
| AW | `i_s_awaddr` | input | 32 | address of the first beat |
| AW | `i_s_awlen` | input | 8 | beats minus one |
| AW | `i_s_awsize` | input | 3 | log2 of the bytes per beat |
| AW | `i_s_awburst` | input | 2 | burst type |
| W | `i_s_wvalid`, `o_s_wready` | input, output | 1 | write beat handshake |
| W | `i_s_wdata` | input | 32 | data |
| W | `i_s_wstrb` | input | 4 | byte enables |
| W | `i_s_wlast` | input | 1 | last beat of the burst |
| B | `o_s_bvalid`, `i_s_bready` | output, input | 1 | write response handshake |
| B | `o_s_bresp` | output | 2 | `"00"` (OKAY) or `"10"` (SLVERR) |
| AR | `i_s_arvalid`, `o_s_arready` | input, output | 1 | read address handshake |
| AR | `i_s_araddr`, `i_s_arlen`, `i_s_arsize`, `i_s_arburst` | input | 32, 8, 3, 2 | same fields as AW |
| R | `o_s_rvalid`, `i_s_rready` | output, input | 1 | read beat handshake |
| R | `o_s_rdata` | output | 32 | read data, zero on a refused transaction |
| R | `o_s_rresp` | output | 2 | `"00"` (OKAY) or `"10"` (SLVERR) |
| R | `o_s_rlast` | output | 1 | last beat of the burst |

### 2.3. Memory port (word contract with line extension)

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `o_addr` | output | 32 | access address |
| `o_wdata` | output | 32 | write data of word 0 |
| `o_byteena` | output | 4 | byte enables of word 0 |
| `o_rden` | output | 1 | read request |
| `o_wren` | output | 1 | write request |
| `o_mem_advance` | output | 1 | access advance pulse |
| `i_ready` | input | 1 | the memory finished the access, the read data is valid |
| `i_rdata` | input | 32 | word 0 read |
| `o_line` | output | 1 | line access, four words |
| `o_wdata_x` | output | 96 | write words 1 to 3, word 1 in the lowest bits |
| `o_byteena_x` | output | 12 | byte enables of words 1 to 3 |
| `i_rdata_x` | input | 96 | read words 1 to 3 |

## 3. Behavior

### 3.1. Transactions served

All the transactions served are INCR with 4-byte beats and an address aligned to 4 bytes.

| Transaction | Handling |
| :--- | :--- |
| `len` equal to 3 and address aligned to 16 bytes | one line access to the memory, with `o_line` at `'1'` |
| any other `len` | one word access per beat, in order, with the address increased by 4 on each beat |
| size different from 4 bytes, type different from INCR or address not aligned to 4 bytes | refused, SLVERR response after all beats are consumed (write) or given as zeros (read), and nothing reaches the memory |

The refusal does not depend on `len`, and the length goes from 1 to 256 beats.

### 3.2. States

| State | Action | Next state |
| :--- | :--- | :--- |
| `ST_IDLE` | `o_s_awready` at `'1'`, and `o_s_arready` at `'1'` only if `i_s_awvalid` is at `'0'`. Copies the address and `len`, evaluates refusal and line | AW leads to `ST_WBEAT`. A refused AR leads to `ST_RBEAT`. A valid AR leads to `ST_ACC` |
| `ST_WBEAT` | `o_s_wready` at `'1'`. Refused, consumes beats up to `wlast`. Line, stores the four beats (beat k in word position k). Word, stores the beat | refused, `ST_BRESP` after `wlast`. Line, `ST_ACC` after the fourth beat. Word, `ST_ACC` |
| `ST_ACC` | holds `o_rden` or `o_wren` until `i_ready` | `ST_ADV` with `i_ready` |
| `ST_ADV` | holds `o_rden` or `o_wren` and emits `o_mem_advance` for one cycle | write, `ST_BRESP` if line or last beat, otherwise adds 4 to the address and goes to `ST_WBEAT`. Read, `ST_RBEAT` |
| `ST_RBEAT` | `o_s_rvalid` at `'1'` with the beat | with `i_s_rready`, `ST_IDLE` after the last beat, `ST_ACC` for the next word beat, the same state for the next line or refused beat |
| `ST_BRESP` | `o_s_bvalid` at `'1'` | `ST_IDLE` with `i_s_bready` |

A write offered at the same time as a read goes first, and the read waits. No request is accepted before the whole response is taken.

### 3.3. Write

1. AW is accepted first, and `o_s_wready` rises only afterwards. A W offered earlier waits.
2. On a refused transaction, each W beat is consumed up to `wlast`, and the response is SLVERR.
3. On a line, the four beats are stored and the memory receives a single line access, with word 0 on `o_wdata` and `o_byteena` and words 1 to 3 on `o_wdata_x` and `o_byteena_x`. After the advance comes a single B response.
4. On any other burst, each beat is a full word access (`ST_ACC`, `ST_ADV`), with the B response only after the last one.
5. On a valid transaction `wlast` is not checked, and the number of beats comes from `len`.

### 3.4. Read

1. A valid AR leads to the read access (`o_rden`) and, after the advance, to the first R beat.
2. On a line, the memory is read once, and the four R beats come out of `i_rdata` and `i_rdata_x` in order, with `o_s_rlast` on the fourth.
3. On any other burst, each beat makes one word access to the memory, with `o_s_rlast` on the last beat, which is the one with the remaining counter equal to zero.
4. On a refused transaction, the `len` plus one beats come out with zero data and SLVERR, with no memory access. The next beat is offered in the clock after the previous one is accepted.
5. The data read from the memory changes only on its own `mem_advance`, so it stays valid while a beat waits for `i_s_rready`.

### 3.5. Memory interface

The access stays on `o_addr`, `o_rden` or `o_wren` until `i_ready`. After that the component emits `o_mem_advance` for one cycle with the access still present. No other block is stopped behind the memory, so the advance is a pulse.

### 3.6. Response

| Situation | Response |
| :--- | :--- |
| valid transaction | OKAY |
| refused transaction | SLVERR on B or on each R beat, with zero data on R |

## 4. Integration

- The AXI4 interconnect of the Insper-RISC-V repository exposes the AXI4 master port of slave 0 of the router, and the word slave is connected to that port outside the interconnect.
- The simulation tops of the data cache and of the slave itself connect the component to the SDRAM bridge, with `axi_master_bridge` or with a test master.

See [DCACHE_AXI.md](../../DCACHE_AXI.md) for the full path, [SDRAM_LINE.md](../../SDRAM_LINE.md) for the line access of the controller and [AXI_UNALIGNED_BYTE_STORE.md](../../bugs/AXI_UNALIGNED_BYTE_STORE.md) for why unaligned addresses are refused.

## 5. Verification

| Coverage | Where |
| :--- | :--- |
| slave with the simulated chip | `AxiSdramSlave`, module [axi_sdram_slave.py](../../../tests/python/unittests/barramento/axi_sdram_slave.py) |
| slave in the cache chain | `DataCache` and `DataCacheWriteThrough` |
| formal proof | [formal/axi_slave](../../../formal/axi_slave/props.sv), run by `bash formal/axi_slave/run.sh` |

The `AxiSdramSlave` test covers five behaviors.

1. A line burst is written and read whole.
2. The `wstrb` of each beat of a line burst are respected.
3. Bursts of 1, 2, 3, 5 and 8 beats, aligned or not to 16 bytes, produce one word access per beat.
4. WRAP, FIXED, sizes different from 4 bytes and an unaligned address answer SLVERR on write and read without touching the chip, and a valid transaction is served after them.
5. A line read is faster than four word reads.

The formal proof treats the AXI4 master and the memory as free inputs bound by contract assumptions and guarantees the following.

1. Correct handshakes and last-beat flag, with `bvalid`, `rvalid`, `bresp`, `rresp`, `rdata` and `rlast` held until the matching `ready`.
2. One transaction at a time, with AW and AR never accepted together, and `o_rden` and `o_wren` never active together.
3. A refused transaction never reaches the memory, and a line access happens only with `len` equal to 3 and an address aligned to 16 bytes.
4. `o_mem_advance` happens only with the memory ready and the access active.
5. SLVERR response and zero data on every refused transaction, OKAY on the others.
6. A transaction of up to four beats is answered within 40 clocks after being accepted, if the master and the memory answer within 3 clocks.

The safety proof is bounded to 55 clocks from reset, which covers transactions of up to four beats. The content that reaches the memory is checked by the system test above, not by the proof. Six cover scenarios must be reachable (four-beat write and read, refused write and read, a two-beat write done word by word and a read that waits for a write), and six mutants of the VHDL must fail (a read that goes ahead of a write, AW accepted twice, early `rlast`, an unaligned address served, a response without waiting for `bready` and an advance without `i_ready`). The general method is in [FORMAL.md](../../FORMAL.md).

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
