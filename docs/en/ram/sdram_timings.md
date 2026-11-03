# SDRAM timings

## 1. The chip and the source

The DE0-CV carries a 512 Mbit (32M x 16) SDR SDRAM. The timings come from the AC characteristics table and the operating frequency and latency table of the ISSI IS42/45S16320D datasheet (Rev. B1, 02/14/2025), column `-7`, CAS latency 3. The part number printed on the chip of a given board should be confirmed against the `-7` grade.

## 2. Datasheet against the controller

| Parameter | Datasheet `-7`, CL3 | Constant in `sdram_pkg` | Cycles at 7 ns |
| :--- | :--- | :--- | ---: |
| Clock period (tCK3) | 7 ns minimum | `T_CK_PS` = 7000 | 1 |
| ACTIVE to READ or WRITE (tRCD) | 15 ns, 3 cycles | `T_RCD_PS` = 15000 | 3 |
| PRECHARGE to ACTIVE (tRP) | 15 ns, 3 cycles | `T_RP_PS` = 15000 | 3 |
| ACTIVE to PRECHARGE (tRAS) | 37 ns minimum, 6 cycles | `T_RAS_PS` = 42000 | 6 |
| ACTIVE to ACTIVE, same bank, and REF to REF (tRC) | 60 ns, 9 cycles | `T_RC_PS` = 60000 and `T_RFC_PS` = 63000 | 9 |
| Last write data to PRECHARGE (tDPL) | 14 ns, 2 cycles | `T_WR_PS` = 14000 | 2 |
| LOAD MODE REGISTER to any command (tMRD) | 14 ns, 2 cycles | `T_MRD_CK` = 2 | 2 |
| Refresh | 8192 cycles in 64 ms | `T_REFI_PS` = 7812500 | 1116 |
| Power-up wait before the first command | 100 us | `T_INIT_PS` = 200 us | |
| AUTO REFRESH commands at power-up | at least 2 | `INIT_REFRESHES` = 8 | |
| CAS latency | 3 at 143 MHz | `CAS_LATENCY` = 3 | |

Every constant is equal to the datasheet value or more conservative. The cycle counts the controller derives from the constants equal the cycle counts of the datasheet's frequency and latency table for the `-7` grade at CL3 (tRCD 3, tRAS 6, tRP 3, tRC 9, tDPL 2, tMRD 2).

## 3. Not covered by the table

1. Setup and hold of the inputs at the pins (tAS, tAH, tDS, tDH, tCMS, tCMH, all 1.5 ns setup and 0.8 ns hold) and the output access time (tAC3 = 5.4 ns) depend on the pin delays and the clock phase to the chip. The platform's PLL phase shift and the Quartus timing analysis cover them, not this package.
2. The controller keeps one row open at a time, so the bank-to-bank spacing (tRRD = 14 ns) does not apply.
3. The self-refresh and power-down parameters (tXSR, tDDE) are unused.
