# sim_util_pkg

Utilities of the memory simulation models and of the test systems, for simulation only.

## 1. Role of the component in the SoC

The chip models of the NOR FLASH and of the SRAM record violations of the chip rules the same way, and the data pattern that fills a chip is reproduced by the models and by the test systems. The package gathers these three utilities, has no ports or state of its own and is never synthesized.

| Block | Use |
| :--- | :--- |
| [nor_flash_model](../rom/nor_flash_model.md) | `tns`, `violate` and `pattern_word` on the initial content |
| [sram_model](../ram/sram_model.md) | `tns` and `violate` |
| `flash_path_system` (`src/cache/SoC/sim/`) | `pattern_word` in the registered-read storage |

## 2. Interface

The package has no generics or ports.

### 2.1. Function `tns`

| Parameter | Type | Range | Meaning |
| :--- | :--- | :--- | :--- |
| `n` | `natural` | 0 to $2^{31}-1$ | Time in nanoseconds |
| return | `time` | | $n$ nanoseconds |

### 2.2. Function `pattern_word`

| Parameter | Type | Range | Meaning |
| :--- | :--- | :--- | :--- |
| `a` | `std_logic_vector(31 downto 0)` | 0 to $2^{32}-1$ | Byte address |
| return | `std_logic_vector(31 downto 0)` | | Pattern word at the address |

$$ \text{pattern\_word}(a) = \left((a \cdot \texttt{0x9E3779B1}) \bmod 2^{32}\right) \oplus \texttt{0x5A5A1234} $$

The byte at address $a$ of a chip is byte 3 of `pattern_word(a)`, and address zero returns the xor constant itself.

### 2.3. Procedure `violate`

| Parameter | Class | Type | Meaning |
| :--- | :--- | :--- | :--- |
| `o_violation` | signal, out | `std_logic` | Violation output of the model, which receives the pulse |
| `prefix` | constant | `string` | Name of the model, prefix of the message |
| `abort` | constant | `boolean` | True to fail the simulation, false to only warn |
| `msg` | constant | `string` | Chip rule that was violated |

The procedure raises `o_violation` for 1 ns and emits the message `prefix: msg` with severity `failure` when `abort` is true and `warning` when it is false. The signal passed as a parameter keeps the driver of the process that called the procedure.

## 3. Verification

| Check | Coverage |
| :--- | :--- |
| `SimUtilPkg` entry of `tests/python/tests.json`, module `tests.python.unittests.sim.sim_util_pkg`, testbench `tests/vhdl/sim_util_pkg_tb.vhd` | The pattern at edge addresses; the 20 ns delay of `tns`, before and after; the pulse of `violate` with `abort` false and the end of the pulse |
| `NorFlashModel` and `SramModel` entries | The violation pulses of each timing rule of the chips |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
