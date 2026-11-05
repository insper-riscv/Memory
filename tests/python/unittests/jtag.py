"""The JTAG port of the debug registers, driven by the cocotb tests."""

from cocotb.triggers import Timer

from tests.python.unittests.dut import Dut

HALF_TCK_NS = 40


async def tck(dut: Dut, port: str = "jtag_", **states: bool) -> None:
    """Give one TCK pulse with the given scan states.

    `port` is the prefix between `i_` and the signal name: `jtag_` in
    the SDRAM system, empty on the JTAG core itself.
    """
    for name in ("cdr", "sdr", "udr", "uir"):
        getattr(dut, f"i_{port}state_{name}").value = (
            1 if states.get(name) else 0
        )
    getattr(dut, f"i_{port}tck").value = 0
    await Timer(HALF_TCK_NS, unit="ns")
    getattr(dut, f"i_{port}tck").value = 1
    await Timer(HALF_TCK_NS, unit="ns")
    getattr(dut, f"i_{port}tck").value = 0
    for name in ("cdr", "sdr", "udr", "uir"):
        getattr(dut, f"i_{port}state_{name}").value = 0


async def load_ir(dut: Dut, value: int, port: str = "jtag_") -> None:
    """Load a value into the instruction register."""
    getattr(dut, f"i_{port}ir_in").value = value
    await tck(dut, port, uir=True)


async def shift_dr(
    dut: Dut, length: int, value: int, port: str = "jtag_"
) -> int:
    """Capture, shift `length` bits (LSB first) and update.

    Returns the bits shifted out.

    """
    await tck(dut, port, cdr=True)
    out = 0
    for i in range(length):
        getattr(dut, f"i_{port}tdi").value = (value >> i) & 1
        await Timer(1, unit="ns")
        out |= int(getattr(dut, f"o_{port}tdo").value) << i
        await tck(dut, port, sdr=True)
    await tck(dut, port, udr=True)
    return out
