#!/usr/bin/env python3
"""A 1541 for the interpreter, good enough to run the World Maker.

The land-mass phase is the last thing `sim6502` can run unaided. Two calls past
it the World Maker is inside `$13BC`, debouncing `$DD00` for a drive that is not
there — measured, 60 million steps and 17 million reads of that one address — and
every phase after the land mass is interleaved with disk writes at band
granularity. So the rest of the World Maker needs a drive.

It does **not** need a serial bus. `game3` reimplements the Kernal's IEC routines
by hand, and they are shallow enough to replace wholesale:

    $1243   send a command byte under ATN — LISTEN, TALK, UNLISTEN, UNTALK
    $12E6   send a secondary address
    $12F4   send a data byte
    $126C   send a secondary address that `$C4` already holds
    $1329   receive a byte — it shifts `$DD00` into `$C9` and returns it
    $1305   UNTALK
    $1314   UNLISTEN

Below them sit the line pokes — `$1398`, `$13A1`, `$13AA`, `$13B3`, `$12EB`, the
delay at `$13C6` and the line *reader* at `$13BC` — which are stubbed as well.
`$13BC` returns zero, which is what the one wait that survives (`$10E6`, spinning
while its result is negative) needs to fall through.

Patching all of that to `RTS` and doing the work in Python skips the bit-banging
entirely, and what is left to implement is small, because the World Maker uses
nothing but **direct block access**:

    B-P: 5 0            set the buffer pointer, channel 5, offset 0
    <256 bytes>         the band, on channel $65
    U2: 5 0 22 17       write buffer 5 to track 22, sector 17

No files, no directory, no BAM allocation. Three commands, a 256-byte buffer per
channel, and `00, OK,00,00` on the error channel.

Two more stubs are needed to get that far: `$090C`, which prints "INSERT A
'BLANK' DISK IN DRIVE #1" and waits, and `$1F95`, which opens the drive and sets
`$C2` to a status the caller checks the sign of.

The disk this produces is the real output of the World Maker — a map — so it is
game data and belongs outside the repo.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from d64 import offset, sectors_per_track  # noqa: E402

# The hand-rolled IEC layer, and the two routines above it that talk to a human.
COMMAND = 0x1243        # send a command byte under ATN
SECONDARY = 0x12E6      # send a secondary address
SEND = 0x12F4           # send a data byte
SECONDARY_HELD = 0x126C  # send the secondary address already in $C4
RECEIVE = 0x1329        # receive a byte, the only routine that reads the bus
# The line pokes and delays underneath. Nothing reads their results except the
# wait at $10E6, which needs $13BC to come back non-negative.
LINES = (0x1398, 0x13A1, 0x13AA, 0x13B3, 0x12EB, 0x13C6)
LINE_READ = 0x13BC
UNTALK = 0x1305
UNLISTEN = 0x1314
PROMPT = 0x090C         # "INSERT A 'BLANK' DISK IN DRIVE #1"
OPEN_DRIVE = 0x1F95     # sets $C2, whose sign the caller tests

STATUS = "00, OK,00,00\r"
BLOCKS = 683            # a 35-track d64


class VirtualDrive:
    """A 1541 that understands `B-P`, `U1` and `U2`, and nothing else.

    Deliberately not a DOS. Anything it does not recognize is accepted and
    ignored, and the error channel always reads OK — the point is to let the
    World Maker run, not to be a drive. ``unhandled`` records what went past so a
    command that turns out to matter cannot slip through unnoticed.
    """

    def __init__(self, image=None):
        self.blocks = bytearray(BLOCKS * 256)
        if image:
            data = open(image, "rb").read()
            self.blocks[:len(data)] = data[:len(self.blocks)]
        self.buffers = {}           # channel -> 256 bytes
        self.pointers = {}          # channel -> offset within the buffer
        self.channel = None         # the secondary address in force
        self.listening = False
        self.command = bytearray()  # what has been sent to channel 15
        self.pending = []           # what a TALK will hand back
        self.unhandled = []
        self.written = []           # (track, sector) in order, for the record

    # -- the bus ----------------------------------------------------------

    def _command_byte(self, value):
        if value == 0x3F:                       # UNLISTEN
            self._unlisten()
        elif value == 0x5F:                     # UNTALK
            self.channel = None
        elif 0x20 <= value < 0x40:              # LISTEN
            self.listening = True
        elif 0x40 <= value < 0x60:              # TALK
            self.listening = False
            if not self.pending:
                self.pending = list(STATUS.encode())

    def _secondary(self, value):
        self.channel = value & 0x0F
        if self.channel == 15:
            self.command = bytearray()
        elif self.listening:
            self.buffers.setdefault(self.channel, bytearray(256))

    def _data(self, value):
        if self.channel == 15:
            self.command.append(value)
            return
        if self.channel is None:
            return
        buffer = self.buffers.setdefault(self.channel, bytearray(256))
        pointer = self.pointers.get(self.channel, 0)
        buffer[pointer] = value
        self.pointers[self.channel] = (pointer + 1) & 0xFF

    def _receive(self):
        return self.pending.pop(0) if self.pending else 0x0D

    def _unlisten(self):
        if self.channel == 15 and self.command:
            self._execute(bytes(self.command).decode("latin-1"))
            self.command = bytearray()
        self.channel = None

    # -- the three commands ------------------------------------------------

    def _execute(self, text):
        head = text.upper().lstrip()
        # The arguments start after the colon. Splitting digits out of the whole
        # string instead picks up the `2` in `U2` and shifts every argument by
        # one, which quietly writes the band to track 0.
        arguments = text.split(":", 1)[1] if ":" in text else text[2:]
        digits = [int(n) for n in
                  "".join(c if c.isdigit() else " " for c in arguments).split()]
        if head.startswith("B-P") and len(digits) >= 2:
            channel, pointer = digits[0], digits[1]
            self.buffers.setdefault(channel, bytearray(256))
            self.pointers[channel] = pointer & 0xFF
        elif head.startswith("U1") and len(digits) >= 4:
            channel, _, track, sector = digits[:4]
            self.buffers[channel] = bytearray(self._block(track, sector))
            self.pointers[channel] = 0
        elif head.startswith("U2") and len(digits) >= 4:
            channel, _, track, sector = digits[:4]
            buffer = self.buffers.setdefault(channel, bytearray(256))
            start = offset(track, sector)
            self.blocks[start:start + 256] = buffer
            self.written.append((track, sector))
        else:
            self.unhandled.append(text)
        self.pending = list(STATUS.encode())

    def _block(self, track, sector):
        if not 1 <= track <= 35 or sector >= sectors_per_track(track):
            return bytes(256)
        start = offset(track, sector)
        return self.blocks[start:start + 256]

    # -- plugging into the interpreter -------------------------------------

    def attach(self, cpu):
        """Replace the IEC layer with this drive.

        Each intercepted routine becomes an `RTS`, and the work happens in the
        trace hook that fires as that `RTS` is about to execute. `chain` keeps
        whatever hook was already installed.
        """
        for address in (COMMAND, SECONDARY, SECONDARY_HELD, SEND, RECEIVE,
                        UNTALK, UNLISTEN, PROMPT) + LINES:
            cpu.mem[address] = 0x60                         # RTS
        for i, byte in enumerate([0xA9, 0x00, 0x60]):       # LDA #$00 / RTS
            cpu.mem[LINE_READ + i] = byte
        # $1F95 has to leave a non-negative status in $C2.
        for i, byte in enumerate([0xA9, 0x00, 0x85, 0xC2, 0x60]):
            cpu.mem[OPEN_DRIVE + i] = byte

        chain = cpu.trace

        def hook(pc, op):
            if pc == COMMAND:
                self._command_byte(cpu.a)
            elif pc == SECONDARY:
                self._secondary(cpu.a)
            elif pc == SECONDARY_HELD:
                self._secondary(cpu.rd(0xC4))
            elif pc == SEND:
                self._data(cpu.a)
            elif pc == RECEIVE:
                cpu.a = self._receive()
                cpu.p = (cpu.p & ~0x82) | (0x02 if cpu.a == 0 else 0) \
                    | (cpu.a & 0x80)
            elif pc == UNTALK:
                self.channel = None
            elif pc == UNLISTEN:
                self._unlisten()
            if chain:
                chain(pc, op)

        cpu.trace = hook
