#!/usr/bin/env python3
"""Recursively disassemble the whole bytecode program in the $C000 loader.

`vmdis.py` walks one straight-line run at a time, which meant chasing branch
targets by hand. This follows every branch and call, and also picks up the
native `JSR $C482` sites that re-enter the VM, so a single run yields the
entire program.

Flow rules, recovered from the dispatcher:

    JMP/JZ/JNZ/JPL/CALL  operand is a bytecode address
    JMPIND/SYS           operand is *native* 6502; a `JSR $C482` there starts
                         a new bytecode stream six bytes later
    RET/JMP/JMPIND       end the current run

See NOTES.md for how the opcode table and the operand masks were recovered.
"""
import sys

LOAD = 0xC000
PTR_LO_MASK, PTR_HI_MASK, IMM_MASK = 0x41, 0xCE, 0x8B

OPS = {
    0x00: ("JMP", "ptr"), 0x01: ("AND", "imm"), 0x02: ("SYS", "ptr"),
    0x03: ("JZ", "ptr"), 0x04: ("LDI", "imm"), 0x05: ("LDA", "ptr"),
    0x06: ("CALL", "ptr"), 0x07: ("STA", "ptr"), 0x08: ("SUBI", "imm"),
    0x09: ("JMPIND", "ptr"), 0x0A: ("RET", "none"), 0x0B: ("LDAX", "ptr"),
    0x0C: ("ASL", "none"), 0x0D: ("INC", "ptr"), 0x0E: ("ADD", "ptr"),
    0x0F: ("DECRYPT2", "none"), 0x10: ("JNZ", "ptr"), 0x11: ("SUB", "ptr"),
    0x12: ("JPL", "ptr"), 0x13: ("SETXY", "ptr"),
}

BRANCH = {"JMP", "JZ", "JNZ", "JPL", "CALL"}
ENDS = {"JMP", "RET", "JMPIND"}

KERNAL = {
    0xFFBA: "SETLFS", 0xFFBD: "SETNAM", 0xFFC0: "OPEN", 0xFFC3: "CLOSE",
    0xFFC6: "CHKIN", 0xFFC9: "CHKOUT", 0xFFCC: "CLRCHN", 0xFFCF: "CHRIN",
    0xFFD2: "CHROUT", 0xFFE4: "GETIN", 0xFFE7: "CLALL", 0xFFA8: "CIOUT",
    0xFFAE: "UNLSN", 0xFFB1: "LISTEN", 0xFFB4: "TALK", 0xFFA5: "ACPTR",
    0xFFAB: "UNTLK", 0xFF93: "SECOND", 0xFF96: "TKSA",
}


class Trace:
    def __init__(self, data):
        self.data = data
        self.rows = {}          # addr -> text
        self.runs = []          # entry points actually decoded
        self.pending = []

    def byte(self, addr):
        return self.data[addr - LOAD]

    def add(self, addr, kind="bytecode"):
        if addr not in [a for a, _ in self.pending] and addr not in self.rows:
            self.pending.append((addr, kind))

    def native_scan(self, addr, span=32):
        """Look for `JSR $C482` in native code, which re-enters the VM."""
        found = []
        for a in range(addr, min(addr + span, LOAD + len(self.data) - 3)):
            if (self.byte(a) == 0x20 and self.byte(a + 1) == 0x82
                    and self.byte(a + 2) == 0xC4):
                found.append(a + 2 + 4)     # dispatcher starts at Y=4
        return found

    def run(self, start):
        pc = start
        while True:
            if pc in self.rows or pc >= LOAD + len(self.data):
                return
            op = self.byte(pc)
            entry = OPS.get(op)
            if entry is None:
                self.rows[pc] = f".byte ${op:02X}     ; not an opcode"
                return
            name, kind = entry
            at = pc
            pc += 1
            if kind == "ptr":
                lo = self.byte(pc) ^ PTR_LO_MASK
                hi = self.byte(pc + 1) ^ PTR_HI_MASK
                pc += 2
                tgt = hi << 8 | lo
                note = ""
                if name in ("SYS", "JMPIND"):
                    if tgt in KERNAL:
                        note = f"   ; {KERNAL[tgt]}"
                    elif LOAD <= tgt < LOAD + len(self.data):
                        for s in self.native_scan(tgt):
                            self.add(s)
                            note = f"   ; native, re-enters VM at ${s:04X}"
                elif name in BRANCH:
                    self.add(tgt)
                self.rows[at] = f"{name:8s} ${tgt:04X}{note}"
            elif kind == "imm":
                imm = self.byte(pc) ^ IMM_MASK
                pc += 1
                ch = chr(imm) if 32 <= imm < 127 else ""
                self.rows[at] = f"{name:8s} #${imm:02X}" + (f"   ; '{ch}'" if ch else "")
            else:
                self.rows[at] = name
            if name in ENDS:
                return

    def go(self, entries):
        for e in entries:
            self.add(e)
        while self.pending:
            addr, _ = self.pending.pop(0)
            self.runs.append(addr)
            self.run(addr)

    def listing(self):
        out = []
        prev = None
        for addr in sorted(self.rows):
            if prev is not None and addr != prev:
                out.append("")
            if addr in self.runs:
                out.append(f"; ---- entry ${addr:04X} ----")
            out.append(f"  ${addr:04X}  {self.rows[addr]}")
            prev = addr + 1 + (2 if "$" in self.rows[addr].split()[0:1] else 0)
            prev = None if self.rows[addr].startswith(".byte") else prev
        return "\n".join(out)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "local/loader.bin"
    data = open(path, "rb").read()
    t = Trace(data)
    # $C02D is the first `JSR $C482`; its bytecode begins six bytes later.
    t.go([0xC033])
    print(t.listing())
    print(f"\n; {len(t.rows)} instructions across {len(t.runs)} runs",
          file=sys.stderr)


if __name__ == "__main__":
    main()
