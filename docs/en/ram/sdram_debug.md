# SDRAM debug port

## 1. What it is

A way for a host to read and write any word of the SDRAM through JTAG while a core uses
it, or while the core is stopped or hung. It is a second master of the SDRAM controller,
behind an arbiter, driven by a Virtual JTAG instance.

| Block | Clock | Role |
| :--- | :--- | :--- |
| Virtual JTAG core | JTAG clock | the instruction and data registers, and the hand-off of a command |
| Debug master | controller clock (142.857 MHz) | runs a command: reads, writes, fills |
| Arbiter | controller clock | serves the core and the debug master, one request at a time, alternating when both wait |

A host access never changes what the core sees: it reads and writes the same chip.

## 2. The JTAG registers

The instance has a 2-bit instruction register. Instruction 1 selects the 64-bit DEBUG
data register; any other instruction leaves a 1-bit bypass.

### 2.1 Shifted in (host to board), least significant bit first

| Bits | Field | Meaning |
| :--- | :--- | :--- |
| 63:60 | op | the command (section 3) |
| 59:56 | be | byte enables of a write: bit $i$ enables byte $i$ of the word |
| 55:32 | addr | word address, $2^{24}$ words of 32 bits: byte address $= 4 \cdot \text{addr}$ from the SDRAM base |
| 31:0 | data | the value to write, or the count of a fill |

### 2.2 Shifted out (board to host)

| Bits | Field | Meaning |
| :--- | :--- | :--- |
| 63:56 | status | see below |
| 55:32 | word | the word accessed last |
| 31:0 | data | what the last read returned |

| Status bit | Meaning |
| :--- | :--- |
| 0 busy | the previous command has not finished: `word` and `data` are not valid yet |
| 1 error | the controller did not answer the previous command |
| 2 initialized | the SDRAM finished its power-up sequence |
| 3 overrun | a command arrived while busy and was dropped (cleared by the next accepted command) |

The command goes out when the shift ends. The status of a command is up to date only a
few JTAG clocks after it was sent, so the first shift after a command may still show
busy; the next one does not.

## 3. Commands

| op | Name | Effect |
| ---: | :--- | :--- |
| 0 | status | sends nothing, only reads the status |
| 1 | read | reads the word at `addr` |
| 2 | write | writes `data` to the word at `addr`, bytes by `be` |
| 3 | fill | writes `data` (all bytes) to `count` words from `addr` |
| 4 | set count | `count` $=$ `data[24:0]`, up to $2^{24}$ words, the whole SDRAM (it starts at 1) |
| 5 | read next | reads the word after the one accessed last |
| 6 | write next | writes `data` to the word after the one accessed last, bytes by `be` |

A fill runs by itself on the controller clock, so zeroing a range does not need one shift
per word: at the controller's rate of about 15 clocks per word the whole 64 MB take about two
seconds (an estimate; the platform's documentation has the measurement on the board).

## 4. A read, step by step

1. Load instruction 1 (once).
2. Shift a command with op 1 and the word address.
3. Shift op 0 until the status shows busy $= 0$ (normally the second shift).
4. The shift that finds busy $= 0$ carries the word accessed last and the data read.

A write is the same without step 4. For a block, op 5 and op 6 continue from the last
word, so the host sends only the data.

## 5. The arbiter

The core's bridge is master A and the debug master is master B. When both wait the
arbiter alternates, so a core access waits for at most one debug access (about 13
controller clocks). With a long fill running, the core's accesses took at most 7 core
cycles at a 56 ns core clock, against 5 with no debug traffic.

## 6. Limits

The throughput is that of the JTAG cable: one word per command, a few milliseconds each,
so reading a kilobyte takes about a second. A fill is the exception because it runs in
the board. A cache between the core and the SDRAM must write through (or be flushed) for
the host to read what the core wrote.
