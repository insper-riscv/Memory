# mem_region_router

## 1. Role of the component in the SoC

The region router takes the request of a master (the memory side of a cache) and forwards it to the SDRAM or to the FLASH depending on whether the address is in the FLASH region. It returns to the master the `ready` and the data of the chosen region. The choice is combinational on the address, which the master keeps stable during the request.

Two kinds of FLASH request never reach the chip and are completed inside the router.

| FLASH request | Router answer |
| :--- | :--- |
| Write | Completed with no effect, as on a write-protected chip |
| Read of an address beyond the window the chip serves | Completed with zeros in the four words |

## 2. Interface

### 2.1. Generics

| Generic | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `flash_base_kib` | natural | 524288 | Base of the FLASH region in KiB (0x20000000) |
| `flash_end_kib` | natural | 1048576 | Exclusive end of the FLASH region in KiB (0x40000000) |
| `flash_window_kib` | natural | 1024 | Size in KiB of the window the chip serves from the base; a read beyond it returns zero |
| `hold_rdata` | boolean | false | The data read follows the region of the last completed request, not the current address (a master without a data cache, see section 3.4) |

### 2.2. Master ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `i_clk` | input | 1 | Module clock |
| `i_rst` | input | 1 | Reset, active at 1 |
| `i_addr` | input | 32 | Request address |
| `i_wdata` | input | 32 | Write data (word 0) |
| `i_byteena` | input | 4 | Write byte enables |
| `i_rden` | input | 1 | Read request |
| `i_wren` | input | 1 | Write request |
| `i_line` | input | 1 | Request for a line of four words |
| `i_wdata_x` | input | 96 | Words 1 to 3 of the line write data (default zeros) |
| `i_advance` | input | 1 | The request was consumed in this cycle |
| `o_ready` | output | 1 | Request completed |
| `o_rdata` | output | 32 | Word read (word 0 of the line) |
| `o_rdata_x` | output | 96 | Words 1 to 3 of the line read |

### 2.3. SDRAM ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `o_s_addr` | output | 32 | Request address (equal to `i_addr`) |
| `o_s_wdata` | output | 32 | Write data |
| `o_s_byteena` | output | 4 | Write byte enables |
| `o_s_rden` | output | 1 | Read, at 1 only for addresses outside the FLASH region |
| `o_s_wren` | output | 1 | Write, at 1 only for addresses outside the FLASH region |
| `o_s_line` | output | 1 | Line request (equal to `i_line`) |
| `o_s_wdata_x` | output | 96 | Words 1 to 3 of the line write data |
| `o_s_advance` | output | 1 | `i_advance` only for addresses outside the FLASH region |
| `i_s_ready` | input | 1 | Request completed |
| `i_s_rdata` | input | 32 | Word read |
| `i_s_rdata_x` | input | 96 | Words 1 to 3 of the line read (default zeros) |

### 2.4. FLASH ports

| Port | Direction | Width | Meaning |
| :--- | :--- | ---: | :--- |
| `o_f_addr` | output | 32 | Request address (equal to `i_addr`) |
| `o_f_rden` | output | 1 | Read, at 1 only for FLASH reads inside the window |
| `o_f_line` | output | 1 | Line request (equal to `i_line`) |
| `o_f_advance` | output | 1 | `i_advance` only for FLASH requests that reach the chip |
| `i_f_ready` | input | 1 | Request completed |
| `i_f_rdata` | input | 32 | Word read |
| `i_f_rdata_x` | input | 96 | Words 1 to 3 of the line read (default zeros) |

The FLASH port has no write and no write data, because no write request reaches the chip.

## 3. Behavior

### 3.1. Destination selection

With $A$ the address and $B$, $E$ and $W$ the generics in KiB, the conditions are as follows.

$$
\text{flash} = (A \ge 1024\,B) \wedge (A < 1024\,E)
$$

$$
\text{beyond} = A \ge 1024\,(B + W)
$$

$$
\text{local} = \text{flash} \wedge (\texttt{i\_wren} \vee (\texttt{i\_rden} \wedge \text{beyond}))
$$

| Condition | Request destination | `o_ready` | `o_rdata` and `o_rdata_x` |
| :--- | :--- | :--- | :--- |
| `local` | None, completed in the router | Local-request register | Zeros |
| `flash` and not `local` | FLASH | `i_f_ready` | FLASH data |
| not `flash` | SDRAM | `i_s_ready` | SDRAM data |

The request addresses and write data go to both outputs unconditionally, but only the chosen output receives the read request, the write request and `i_advance`.

### 3.2. Local request

When `local` holds and the local-request register is 0, it goes to 1 on the next edge, so `o_ready` rises one cycle after the request. It stays at 1 until `i_advance` and then falls. The master lowers the request on the edge in which it sees `o_ready`, as the caches do. Reset clears the register.

### 3.3. Master contract

The request stays on the bus until `o_ready`, which is a level and falls only with `i_advance`. The data read changes only in the next request. For the outputs that do not go through the register (SDRAM and FLASH), the router adds no cycles, because `o_ready`, `o_rdata` and `o_rdata_x` are combinational on the slave answers.

For a read-only cache, `i_wren` stays at 0 and the store case does not occur.

### 3.4. Held read data (`hold_rdata`)

A cache keeps the data when the request ends, so choosing the data combinationally by the address is enough. A master that does not keep the data, such as the core wired straight to the router, changes the address as soon as the request ends, and the write-back stage still reads the data a third of a cycle later. With `hold_rdata` set to `true`, `o_rdata` and `o_rdata_x` follow the region of the last completed request, which a register keeps on the edge in which the chip changes the data read.

$$
\text{completes} = (\texttt{i\_rden} \vee \texttt{i\_wren}) \wedge \texttt{i\_advance} \wedge \texttt{o\_ready}
$$

On the edge in which `completes` holds, the `flash` and `local` registers take the conditions of section 3.1; otherwise they keep their value. Reset clears them, and the data read goes back to the SDRAM one. With `hold_rdata` set to `false` no register exists and the behavior is that of section 3.1.

## 4. Integration

| Instance | File | Connection |
| :--- | :--- | :--- |
| `u_router_i` | `src/cache/SoC/sim/flash_path_system.vhd` | Master wired to the memory side of the [icache](icache.md), with `i_wren` at 0; FLASH output wired to master A of the [flash_arbiter](flash_arbiter.md); SDRAM output without a slave |
| `u_router_b` | `src/cache/SoC/sim/flash_path_system.vhd` | Master wired to port B of the system, which stands for the memory side of a data cache; FLASH output wired to master B of the arbiter; SDRAM output without a slave |

The memory side of the [dcache](dcache.md) uses the same request and answer convention. A FLASH store forwarded by the dcache is the case in which the router completes it with no effect. No instance in the repository wires the dcache to this router. The modular top of Insper-RISC-V wires the core to the data router with `hold_rdata` set to `true` when there is no data cache.

## 5. Verification

The tests are cocotb tests in `tests/python/unittests/cache`, registered in `tests/python/tests.json`. The router has no formal proofs.

| `tests.json` entry | Test module | What it covers |
| :--- | :--- | :--- |
| `MemRegionRouter` | [mem_region_router.py](../../../tests/python/unittests/cache/mem_region_router.py) | Line read to the SDRAM and to the FLASH, FLASH store absorbed, read outside the window returns zero, SDRAM store passed through, mixed sequence |
| `MemRegionRouterLow` | [mem_region_router_low.py](../../../tests/python/unittests/cache/mem_region_router_low.py) | Generics `flash_base_kib` equal to 2, `flash_end_kib` equal to 32 and `flash_window_kib` equal to 30; a read inside the region reaches the ROM, region edges, ROM store absorbed and SDRAM store passed through |
| `MemRegionRouterHold` | [mem_region_router_hold.py](../../../tests/python/unittests/cache/mem_region_router_hold.py) | Generic `hold_rdata` set to `true`; the FLASH word and the SDRAM word stay after the address changes, and an absorbed store leaves zero |
| `FlashPath` | [flash_path.py](../../../tests/python/unittests/cache/flash_path.py) | Two routers, the icache, the arbiter and the chip together; a FLASH store never reaches the chip, a read beyond the window returns zero without touching the chip, SDRAM requests do not touch the FLASH path |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
