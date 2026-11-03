# sdram_cpu_bridge

## 1. Role of the component in the SoC

Bridge between the core's memory stage, on the core clock, and the toggle request of the SDRAM controller, on another clock. The bridge receives a word or line access, stores the fields in a register, requests the access by flipping a toggle and returns to the core a ready signal that stays high until the pipeline advances. The read data changes only on the edge where the pipeline advances, because the load still in the write-back stage reads the previous value until then.

The same bridge serves the data path and the instruction path, in two instances. The line access moves the four words of a cache line, as described in [SDRAM_LINE.md](../../SDRAM_LINE.md). The byte selection of a load and the generation of the enables of a store happen in the core, as [SDRAM_SUBWORD_READ.md](../../SDRAM_SUBWORD_READ.md) explains.

## 2. Interface

### 2.1. Core side

| Port | Dir. | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk_cpu` | in | 1 | core clock |
| `i_rst_cpu` | in | 1 | core-side reset, active at `'1'` |
| `i_addr` | in | 32 | byte address of the access |
| `i_wdata` | in | 32 | write data (word 0) |
| `i_byteena` | in | 4 | byte enables of the write, one bit per byte |
| `i_rden` | in | 1 | read request |
| `i_wren` | in | 1 | write request |
| `i_mem_advance` | in | 1 | the pipeline advanced in this cycle, and the access in progress may complete |
| `o_ready` | out | 1 | access complete, with valid read data |
| `o_rdata` | out | 32 | read data (word 0) |
| `i_line` | in | 1 | line access of four words (default `'0'`) |
| `i_wdata_x` | in | 96 | words 1 to 3 of the write data, word 1 in the lowest bits (default zero) |
| `i_byteena_x` | in | 12 | byte enables of words 1 to 3 (default zero) |
| `o_rdata_x` | out | 96 | words 1 to 3 of the read data |

### 2.2. Controller side

| Port | Dir. | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `o_req_tog` | out | 1 | each flip is a new request |
| `i_ack_tog` | in | 1 | acknowledge toggle of the controller, synchronized inside the bridge |
| `i_init_done` | in | 1 | the SDRAM initialization finished, synchronized inside the bridge |
| `o_c_we` | out | 1 | write (`'1'`) or read (`'0'`) |
| `o_c_addr` | out | 24 | word address |
| `o_c_wdata` | out | 32 | write data |
| `o_c_be` | out | 4 | byte enables |
| `i_c_rdata` | in | 32 | read data |
| `o_c_line` | out | 1 | line access |
| `o_c_wdata_x` | out | 96 | words 1 to 3 of the write data |
| `o_c_be_x` | out | 12 | byte enables of words 1 to 3 |
| `i_c_rdata_x` | in | 96 | words 1 to 3 of the read data |

## 3. Behavior

### 3.1. State machine

| State | Action | Exit to the next state |
| :--- | :--- | :--- |
| `ST_IDLE` | with `i_rden` or `i_wren` at `'1'` and the synchronized initialization at `'1'`, copies the access fields to the output registers, flips `o_req_tog` and goes to `ST_WAIT` | request accepted |
| `ST_WAIT` | waits for the synchronized acknowledge toggle to equal `o_req_tog` and stores the read data | acknowledge received |
| `ST_DONE` | keeps `o_ready` at `'1'` until `i_mem_advance` | pipeline advance, which goes back to `ST_IDLE` |

At the advance of a read, the stored data goes to `o_rdata` and `o_rdata_x`. At the advance of a write those outputs do not change. If `i_rden` and `i_wren` are `'1'` together, the access is a write. After the advance the bridge returns to the idle state and accepts, on the next edge, the access that is on the inputs.

### 3.2. Address

The address sent to the controller is

$$
\text{o\_c\_addr} = \text{i\_addr}[25:2]
$$

The two low bits select the byte inside the word and do not go to the controller. Bits 31 to 26 are not used, and 24 bits of word address cover the 64 MB of the chip. In a line access, the controller also ignores the two low bits of the word address and uses the aligned 16-byte line that contains the address.

### 3.3. Clock crossing

The acknowledge toggle and the end-of-initialization signal each cross a two-flip-flop synchronizer. The request buses change on the same edge that flips `o_req_tog` and stay stable until the acknowledge. The controller samples them only after seeing the flip, so they need only a delay constraint shorter than the synchronizer latency, and not synchronizers of their own.

### 3.4. Latency

The counts use $e$ as the first edge of the controller clock that samples the flip of `o_req_tog`, with the controller idle and no refresh pending. The arbiter picks the request at $e+2$, the controller decides the ACTIVE at $e+3$, and the arbiter acknowledges the master after the controller response.

| Access | Edge at which the arbiter flips the acknowledge, counted from $e$ |
| :--- | ---: |
| word read | 13 |
| word write | 8 |
| line read | 19 |
| line write | 14 |

After that the acknowledge crosses the synchronizer back to the core clock, and the bridge still spends one core edge to change from `ST_WAIT` to `ST_DONE`. The values of each controller access are in [sdram_ctrl](sdram_ctrl.md) and those of the arbiter in [sdram_arbiter](sdram_arbiter.md).

## 4. Integration

| Instance | Arbiter master | Notes |
| :--- | :--- | :--- |
| `u_bridge` in `sdram_system` | A, the data path | full read, write and line |
| `u_ibridge` in `sdram_system` | I, the instruction path | `i_wren` and the write data fixed at zero, so it only reads |

The other bridges of the repository follow the same core-side contract, among them the AXI master bridge, the data cache and the external RAM model.

The synchronizer comes from Common-Components (`src/common/src/synchronizer.vhd`). The end of initialization used to release accesses is the controller's `o_init_done`.

## 5. Verification

| `tests.json` entry | Test module | What it exercises in the bridge |
| :--- | :--- | :--- |
| `SdramSystem` | [sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py) | write and read with every byte-enable mask, read data that changes only when the pipeline advances (pipeline held for extra cycles after ready), core and controller clocks in different relations (14 ns, 53 ns with offset and 100 ns with offset, against 7 ns), latency bounds in core cycles, line accesses and a mix of lines and words |
| `SdramDebugPort` | [sdram_debug_port.py](../../../tests/python/unittests/ram/sdram_debug_port.py) | core accesses concurrent with the host, with a wait bound |
| `DataCache`, `DataCacheWriteThrough` and `AxiSdramSlave` | [axi_sdram_slave.py](../../../tests/python/unittests/barramento/axi_sdram_slave.py) and the cache modules | the bridge behind the cache and the AXI slave, with line and word bursts |

The instruction instance exists in the simulation top, but the SDRAM tests do not drive it. It uses the same description as the data instance.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
