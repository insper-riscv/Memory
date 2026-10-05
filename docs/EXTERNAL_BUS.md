# External bus and JTAG UART

## 1. What it is

Every data access of the core at or above `0x40000000` leaves through one external port with a
`ready` handshake. The interconnect behind that port sends it to the SDRAM or to a peripheral. The
only peripheral today is a UART whose other end is a host on JTAG.

| Block | Role |
| :--- | :--- |
| Interconnect | decodes the address, gives the core the ready and the data of the slave that answered |
| SDRAM bridge | the memory slave (see `SDRAM_DEBUG.md` for the host path to the same chip) |
| JTAG UART | transmit and receive queues of 64 bytes, a Virtual JTAG instance for the host |

## 2. Address map

| Range | Slave |
| :--- | :--- |
| bit 31 = 0 (from `0x40000000`) | the SDRAM bridge |
| bit 31 = 1 | a peripheral window: bits 30:28 are the id, bits 9:2 the word offset in the window |

| Id | Window | Peripheral |
| ---: | :--- | :--- |
| 4 | `0xC0000000` | JTAG UART |
| 0 to 3, 5 to 7 | | none: a read gives 0, a write has no effect, the access completes |

## 3. The handshake

The core holds the access on the port until `ready`, which stays high as a level until
`mem_advance`.

1. A memory access passes through: the read and write strobes go to the bridge and its `ready`
   and data come back, whatever the number of cycles it takes.
2. A peripheral access takes one cycle: the interconnect sends one pulse of read or write to the
   slave, then keeps `ready` high until `mem_advance`. A pipeline that stays stopped for another
   reason does not repeat the pulse, so a read that removes a byte from a queue removes one.
3. The data of a load is copied when the load advances, and the choice of slave is registered at
   the same time. The next access, already on the port while the load is in its last stage, does
   not disturb it.

## 4. The UART registers (core side)

| Word | Name | Read | Write |
| ---: | :--- | :--- | :--- |
| 0 | TXDATA | 0 | queue bits 7:0 for the host; dropped and flagged if the queue is full |
| 1 | RXDATA | bit 8 = a byte was waiting, bits 7:0 = that byte (removed); 0 when empty | ignored |
| 2 | STATUS | bits 7:0 free places in the transmit queue (0 to 64), bits 15:8 bytes in the receive queue, bit 16 a byte was dropped since the last read (the read clears it) | ignored |

A program that must not stop when no host is attached reads STATUS before a write and gives up
after a bounded wait; a write to a full queue never blocks the core.

## 5. The host side

The UART is the second Virtual JTAG instance (instance index 1) next to the SDRAM debug port's. Its
instruction register has 2 bits; instruction 1 selects a 48-bit data register.

| Direction | Bits | Meaning |
| :--- | :--- | :--- |
| in | 8 | push: give the byte below to the core |
| in | 7:0 | the byte (taken only if push is 1) |
| out | 31:0 | up to four bytes from the core, the first in bits 7:0 |
| out | 34:32 | how many of them are valid |
| out | 35 | the push of the command was dropped (receive queue full) |
| out | 36 | the previous scan was dropped: the command before it had not finished |
| out | 47:40 | bytes still waiting in the transmit queue |

Every accepted scan takes up to four bytes out of the transmit queue. The JTAG clock runs only
during a scan, so an answer is shown by the second scan after its command (a scan shows the answer
to the command of the scan before the previous one) and only once. A host that wants the output
keeps scanning; one that wants to send a byte sets push in a scan.

## 6. Limits

| Item | Value |
| :--- | :--- |
| Bytes per scan, board to host | 4 |
| Bytes per scan, host to board | 1 |
| Queue depth | 64 bytes each way |
| Peripheral access | 1 core cycle plus the wait for `mem_advance` |
