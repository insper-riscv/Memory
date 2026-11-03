# sdram_pkg

## 1. Role of the component in the SoC

VHDL package that gathers the numbers of the SDRAM chip on the DE0-CV board (32M x 16, 4 banks, 13 row bits and 10 column bits, grade -7, CAS latency 3) and the encoding of its commands. The controller and the chip model read the same values, so the model fails the simulation when the controller violates any time in the package. Changing a time means editing this file only.

The origin of each value in the datasheet and the comparison with the controller's cycle counts are in [SDRAM_TIMINGS.md](../../SDRAM_TIMINGS.md).

## 2. Interface

The package has no ports and no generics. It exports constants, one function and no new type.

### 2.1. Times and counts

| Constant | Value | Meaning |
| :--- | ---: | :--- |
| `T_CK_PS` | 7000 | clock period the cycle counts assume, in ps |
| `T_RCD_PS` | 15000 | ACTIVE to READ or WRITE, in ps |
| `T_RP_PS` | 15000 | PRECHARGE to ACTIVE, in ps |
| `T_RAS_PS` | 42000 | ACTIVE to PRECHARGE, in ps |
| `T_RC_PS` | 60000 | ACTIVE to ACTIVE in the same bank, in ps |
| `T_RFC_PS` | 63000 | AUTO REFRESH to any command, in ps |
| `T_WR_PS` | 14000 | last write data to PRECHARGE, in ps |
| `T_MRD_CK` | 2 | LOAD MODE REGISTER to any command, in clocks |
| `T_INIT_PS` | 200000000 | wait with a stable clock before the first command, in ps |
| `T_REFI_PS` | 7812500 | interval between refreshes, in ps |
| `INIT_REFRESHES` | 8 | AUTO REFRESH commands of the power-up sequence |
| `CAS_LATENCY` | 3 | CAS latency, in clocks |

### 2.2. Mode register

`MODE_REG` has 13 bits and is placed on the address bus during LOAD MODE REGISTER.

| Bits | Value | Meaning |
| :--- | :--- | :--- |
| 2 to 0 | `001` | burst of 2 beats of 16 bits, which makes one 32-bit word |
| 3 | `0` | sequential burst |
| 6 to 4 | `011` | CAS latency 3 |
| 9 | `0` | writes are also bursts |
| 12 to 10 and 8 to 7 | `0` | reserved |

### 2.3. Commands

Each command is the vector formed by chip select, RAS, CAS and write enable, all active low.

| Constant | Code (cs, ras, cas, we) | Command |
| :--- | :--- | :--- |
| `CMD_NOP` | `0111` | no operation |
| `CMD_ACTIVE` | `0011` | opens a row |
| `CMD_READ` | `0101` | read |
| `CMD_WRITE` | `0100` | write |
| `CMD_PRECHARGE` | `0010` | closes rows |
| `CMD_REFRESH` | `0001` | AUTO REFRESH |
| `CMD_LOAD_MODE` | `0000` | loads the mode register |

### 2.4. Function

| Function | Parameters | Return |
| :--- | :--- | :--- |
| `cycles` | `ps` and `tck_ps`, both `natural` | number of clocks that cover `ps`, rounded up |

## 3. Behavior

The rounding function is

$$
\text{cycles}(t, T_{CK}) = \left\lceil \frac{t}{T_{CK}} \right\rceil
$$

With $T_{CK} = 7000$ ps, the times of the package become the counts below, which the controller uses as local constants.

| Time | Cycles |
| :--- | ---: |
| $T_{RCD}$ | 3 |
| $T_{RP}$ | 3 |
| $T_{RAS}$ | 6 |
| $T_{RC}$ | 9 |
| $T_{RFC}$ | 9 |
| $T_{WR}$ | 2 |
| $T_{INIT}$ | 28572 |
| $T_{REFI}$ | 1117 |

The controller does not use $T_{RAS}$, because the chip's auto-precharge already waits that time before closing the row. The power-up sequence of the controller issues `INIT_REFRESHES` refreshes, and the chip model requires only two before the mode register, without using that constant.

Every value is equal to or more conservative than the datasheet minimum, as the table of [SDRAM_TIMINGS.md](../../SDRAM_TIMINGS.md) shows. The addressing of the chip comes from its geometry and not from constants of the package, and is described in [sdram_ctrl.md](sdram_ctrl.md).

## 4. Integration

| Used by | Constants read |
| :--- | :--- |
| [sdram_ctrl](sdram_ctrl.md) | every time except $T_{RAS}$, `MODE_REG`, `CAS_LATENCY`, `INIT_REFRESHES`, the `CMD_*` codes and `cycles` |
| [sdram_model](sdram_model.md) | every time, `MODE_REG`, `CAS_LATENCY`, the `CMD_*` codes |
| simulation tops of the subsystem | `cycles`, `T_INIT_PS`, `T_REFI_PS` and `T_CK_PS` as default values of the wait and refresh generics |

In `tests/python/tests.json` the package comes before the controller and the model in the source list of every test that compiles one of them.

## 5. Verification

The package has no test of its own. The values are exercised by the tests that compile the controller and the model, because the model fails the simulation with `severity failure` when a time is violated.

| Test | What it covers of the values |
| :--- | :--- |
| `SdramSystem` in [sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py) | power-up, word and line accesses and refresh under the model |
| `SdramBist` and `SdramBistRegisteredPins` in [sdram_bist.py](../../../tests/python/unittests/ram/sdram_bist.py) | the controller alone over the model, with and without registered data pins |
| `SdramDebugPort` in [sdram_debug_port.py](../../../tests/python/unittests/ram/sdram_debug_port.py) | concurrent traffic from the core and from the host |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
