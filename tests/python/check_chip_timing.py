"""Check that chip_timing_pkg carries the times of the chip catalog.

The controllers and the chip models of the device memories take their
default times from src/ROM/SoC/chip_timing_pkg.vhd. The chip catalog in
chips/ is the source of those times, so this check fails when a constant
of the package differs from the catalog (the package is the form of the
catalog that VHDL reads, until it is generated from it).
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Catalog field -> constant of the package, per chip.
MAP = {
    "S29GL064N90": {
        "access_ns": "NOR_T_ACC_NS",
        "page_access_ns": "NOR_T_PACC_NS",
        "oe_ns": "NOR_T_OE_NS",
        "write_cycle_ns": "NOR_T_WC_NS",
        "write_pulse_ns": "NOR_T_WP_NS",
        "write_high_ns": "NOR_T_WPH_NS",
        "data_setup_ns": "NOR_T_DS_NS",
        "addr_hold_ns": "NOR_T_AH_NS",
        "busy_ns": "NOR_T_BUSY_NS",
        "reset_pulse_ns": "NOR_T_RP_NS",
        "reset_ready_ns": "NOR_T_RH_NS",
        "program_ns": "NOR_T_PROG_NS",
        "sector_erase_ns": "NOR_T_ERASE_NS",
    },
    "IS61WV102416BLL-10": {
        "access_ns": "SRAM_T_AA_NS",
        "read_cycle_ns": "SRAM_T_RC_NS",
        "write_cycle_ns": "SRAM_T_WC_NS",
        "ce_write_ns": "SRAM_T_SCE_NS",
        "addr_write_ns": "SRAM_T_AW_NS",
        "write_pulse_ns": "SRAM_T_PWE_NS",
        "data_setup_ns": "SRAM_T_SD_NS",
        "addr_hold_ns": "SRAM_T_HA_NS",
        "data_hold_ns": "SRAM_T_HD_NS",
    },
}


def main() -> int:
    """Compare the catalog with the package and return the exit code."""
    package = (ROOT / "src/ROM/SoC/chip_timing_pkg.vhd").read_text()
    constants = {
        m.group(1): int(m.group(2))
        for m in re.finditer(r"constant\s+(\w+)\s*:\s*natural\s*:=\s*(\d+);", package)
    }
    bad = 0
    for chip, fields in MAP.items():
        text = (ROOT / "chips" / f"{chip}.yaml").read_text()
        timing = re.search(r"^timing:\s*\{(.*)\}", text, re.MULTILINE)
        values = dict(
            (k.strip(), int(v)) for k, v in re.findall(r"(\w+):\s*(\d+)", timing.group(1))
        ) if timing else {}
        for field, name in fields.items():
            if values.get(field) != constants.get(name):
                print(f"{chip}.{field}={values.get(field)} but {name}={constants.get(name)}")
                bad += 1
    print("chip timing OK" if not bad else f"{bad} difference(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
