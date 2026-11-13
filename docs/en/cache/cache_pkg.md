# cache_pkg

Functions that the caches, the fetch bridge and the region router share, so that the membership of an address in a region and the width of the line index exist once.

The memory block addresses are of type `addr_t` and the core data word is `word_t`, both from the `config_pkg` of Common-Components, so the widths follow `ADDR_BITS` and `XLEN` of the platform. The address windows of the caches come from the platform map (`FLASH_BASE`, `FLASH_END`, `RAM_BASE`, `RAM_END`, `I_CACHE_WINDOW_BITS` and `D_CACHE_WINDOW_BITS`), passed through the generics of each block.

## 1. Role of the component in the SoC

Every block that separates the FLASH region from the others tests the address against the same range, and the two caches compute the width of the line index the same way. The package gathers the two computations. It keeps no state, holds in elaboration and in synthesis and has no ports.

| Block | Use |
| :--- | :--- |
| [icache](icache.md) | `in_window` on the tag and on the fill, `index_bits_of` on the size of the line memory |
| [dcache](dcache.md) | `in_window` on the tag, on the write and on the line read, `index_bits_of` on the size of the line memory |
| [ifetch_bridge](ifetch_bridge.md) | `in_window` on the address of the memory request |
| [mem_region_router](mem_region_router.md) | `in_window` on the selection of the FLASH region |

## 2. Interface

The package has no generics or ports. Each function is pure and takes the parameters below.

### 2.1. Function `in_window`

| Parameter | Type | Range | Meaning |
| :--- | :--- | :--- | :--- |
| `addr` | `addr_t` | 0 to $2^{ADDR\_BITS}-1$ | Byte address tested |
| `base_kib` | `natural` | 0 to $2^{22}-1$ | First KiB of the region |
| `end_kib` | `natural` | 0 to $2^{22}-1$ | KiB after the last one of the region |
| return | `std_logic` | `'0'` or `'1'` | `'1'` when the address is in the region |

$$ \text{in\_window} = \begin{cases} \texttt{'1'} & 1024 \cdot \text{base\_kib} \le \text{addr} < 1024 \cdot \text{end\_kib} \\ \texttt{'0'} & \text{otherwise} \end{cases} $$

When `base_kib` equals `end_kib` the region is empty and the result is always `'0'`. The defaults of the caches are `base_kib` 524288 and `end_kib` 1048576, the FLASH region from `0x20000000` to `0x3FFFFFFF`.

### 2.2. Function `index_bits_of`

| Parameter | Type | Range | Meaning |
| :--- | :--- | :--- | :--- |
| `bits` | `positive` | power of two, at least 256 | Size of the data memory of the cache, in bits |
| return | `natural` | at least 1 | Bits of the line index |

$$ \text{index\_bits\_of}(b) = \log_2 b - 7 $$

A line has 128 bits, so $b \ge 256$ guarantees at least two lines. A size that is not a power of two, or is below 256, fails the elaboration.

## 3. Verification

| Check | Coverage |
| :--- | :--- |
| `CachePkg` entry of `tests/python/tests.json`, module `tests.python.unittests.cache.cache_pkg`, testbench `tests/vhdl/cache_pkg_tb.vhd` | Address one unit below the base, equal to the base, one unit above, one unit below the end, equal to the end and one unit above; empty region; region that ends at the last KiB of the address space; index widths from 256 bits to 1 Mibit |
| Formal proofs of `icache`, `dcache` and `mem_region_router` | They compile the package with the entity, and the mutants that change the membership in the region are still caught |

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](../../../LICENSE).
