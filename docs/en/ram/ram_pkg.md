# ram_pkg

Translation of the byte address of an access into the offset inside the window of a memory chip, written once for the window memories.

## 1. Role of the component in the SoC

A chip memory takes a window inside the 64 MiB region, starting at `base_kib` KiB. The address of the access uses the low 26 bits, and the offset in the window is the difference between that address and the base. The package has no ports or state and holds in elaboration and in synthesis.

| Block | Use |
| :--- | :--- |
| [ram_chip](ram_chip.md) | Word index of the access, after testing the base |
| [sram_ctrl](sram_ctrl.md) | Out-of-window test and offset of the SRAM access |
| [onchip_ram_port](onchip_ram_port.md) | Offset of the access to the RAM block, after testing the base |

## 2. Interface

The package has no generics or ports. The function is pure.

### 2.1. Function `window_offset`

| Parameter | Type | Range | Meaning |
| :--- | :--- | :--- | :--- |
| `addr` | `addr_t` | 0 to $2^{ADDR\_BITS}-1$ | Byte address of the access; only the low 26 bits count |
| `base_kib` | `natural` | 0 to 65535 | Base of the window inside the region, in KiB |
| return | `unsigned(25 downto 0)` | 0 to $2^{26}-1$ | Offset in bytes inside the window |

$$ \text{window\_offset} = \left(\text{addr}[25{:}0] - 1024 \cdot \text{base\_kib}\right) \bmod 2^{26} $$

Below the base the result wraps around in 26 bits. Whoever uses the function tests the base first, or compares the result with the size of the chip, which is how each block of the table decides whether the access is outside the window.

## 3. Verification

| Check | Coverage |
| :--- | :--- |
| `RamPkg` entry of `tests/python/tests.json`, module `tests.python.unittests.ram.ram_pkg`, testbench `tests/vhdl/ram_pkg_tb.vhd` | Base zero; base of 512 KiB with the address equal to the base, just after it and far from it; address below the base, which wraps around; bits above the low 26 ignored |
| `RamChipOffset`, `OnchipRamOffset` and `SramCtrl` entries | The package in use inside each memory with a nonzero base |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
