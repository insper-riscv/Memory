"""The JTAG port of the debug registers, driven by the cocotb tests."""

from cocotb.triggers import Timer

from tests.python.unittests.dut import Dut

HALF_TCK_NS = 40


async def tck(dut: Dut, **states: bool) -> None:
    """Give one TCK pulse with the given scan states."""
    for name in ("cdr", "sdr", "udr", "uir"):
        getattr(dut, f"i_jtag_state_{name}").value = (
            1 if states.get(name) else 0
        )
    dut.i_jtag_tck.value = 0
    await Timer(HALF_TCK_NS, unit="ns")
    dut.i_jtag_tck.value = 1
    await Timer(HALF_TCK_NS, unit="ns")
    dut.i_jtag_tck.value = 0
    for name in ("cdr", "sdr", "udr", "uir"):
        getattr(dut, f"i_jtag_state_{name}").value = 0


async def load_ir(dut: Dut, value: int) -> None:
    """Load a value into the instruction register."""
    dut.i_jtag_ir_in.value = value
    await tck(dut, uir=True)


async def shift_dr(dut: Dut, length: int, value: int) -> int:
    """Capture, shift `length` bits (LSB first) and update.

    Returns the bits shifted out.

    """
    await tck(dut, cdr=True)
    out = 0
    for i in range(length):
        dut.i_jtag_tdi.value = (value >> i) & 1
        await Timer(1, unit="ns")
        out |= int(dut.o_jtag_tdo.value) << i
        await tck(dut, sdr=True)
    await tck(dut, udr=True)
    return out
