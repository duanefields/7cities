#!/usr/bin/env python3
"""Recursive-descent 6502 disassembler.

Follows control flow from entry points so code and data are separated by
reachability rather than guesswork, which is what da65 gets wrong on these
binaries. Emits a listing plus a code/data map.
"""
import sys

# addressing modes: (name, operand length)
IMP, ACC, IMM, ZP, ZPX, ZPY, ABS, ABX, ABY, IND, IZX, IZY, REL = range(13)
SIZE = {IMP: 0, ACC: 0, IMM: 1, ZP: 1, ZPX: 1, ZPY: 1, ABS: 2, ABX: 2,
        ABY: 2, IND: 2, IZX: 1, IZY: 1, REL: 1}

OPS = {}


def _d(spec):
    t = spec.split()
    for k in range(0, len(t), 3):
        op, mn, am = t[k:k + 3]
        OPS[int(op, 16)] = (mn, globals()[am])


_d("""
00 BRK IMP  01 ORA IZX  05 ORA ZP   06 ASL ZP   08 PHP IMP  09 ORA IMM
0A ASL ACC  0D ORA ABS  0E ASL ABS  10 BPL REL  11 ORA IZY  15 ORA ZPX
16 ASL ZPX  18 CLC IMP  19 ORA ABY  1D ORA ABX  1E ASL ABX  20 JSR ABS
21 AND IZX  24 BIT ZP   25 AND ZP   26 ROL ZP   28 PLP IMP  29 AND IMM
2A ROL ACC  2C BIT ABS  2D AND ABS  2E ROL ABS  30 BMI REL  31 AND IZY
35 AND ZPX  36 ROL ZPX  38 SEC IMP  39 AND ABY  3D AND ABX  3E ROL ABX
40 RTI IMP  41 EOR IZX  45 EOR ZP   46 LSR ZP   48 PHA IMP  49 EOR IMM
4A LSR ACC  4C JMP ABS  4D EOR ABS  4E LSR ABS  50 BVC REL  51 EOR IZY
55 EOR ZPX  56 LSR ZPX  58 CLI IMP  59 EOR ABY  5D EOR ABX  5E LSR ABX
60 RTS IMP  61 ADC IZX  65 ADC ZP   66 ROR ZP   68 PLA IMP  69 ADC IMM
6A ROR ACC  6C JMP IND  6D ADC ABS  6E ROR ABS  70 BVS REL  71 ADC IZY
75 ADC ZPX  76 ROR ZPX  78 SEI IMP  79 ADC ABY  7D ADC ABX  7E ROR ABX
81 STA IZX  84 STY ZP   85 STA ZP   86 STX ZP   88 DEY IMP  8A TXA IMP
8C STY ABS  8D STA ABS  8E STX ABS  90 BCC REL  91 STA IZY  94 STY ZPX
95 STA ZPX  96 STX ZPY  98 TYA IMP  99 STA ABY  9A TXS IMP  9D STA ABX
A0 LDY IMM  A1 LDA IZX  A2 LDX IMM  A4 LDY ZP   A5 LDA ZP   A6 LDX ZP
A8 TAY IMP  A9 LDA IMM  AA TAX IMP  AC LDY ABS  AD LDA ABS  AE LDX ABS
B0 BCS REL  B1 LDA IZY  B4 LDY ZPX  B5 LDA ZPX  B6 LDX ZPY  B8 CLV IMP
B9 LDA ABY  BA TSX IMP  BC LDY ABX  BD LDA ABX  BE LDX ABY  C0 CPY IMM
C1 CMP IZX  C4 CPY ZP   C5 CMP ZP   C6 DEC ZP   C8 INY IMP  C9 CMP IMM
CA DEX IMP  CC CPY ABS  CD CMP ABS  CE DEC ABS  D0 BNE REL  D1 CMP IZY
D5 CMP ZPX  D6 DEC ZPX  D8 CLD IMP  D9 CMP ABY  DD CMP ABX  DE DEC ABX
E0 CPX IMM  E1 SBC IZX  E4 CPX ZP   E5 SBC ZP   E6 INC ZP   E8 INX IMP
E9 SBC IMM  EA NOP IMP  EC CPX ABS  ED SBC ABS  EE INC ABS  F0 BEQ REL
F1 SBC IZY  F5 SBC ZPX  F6 INC ZPX  F8 SED IMP  F9 SBC ABY  FD SBC ABX
FE INC ABX
""")

TERMINAL = {"RTS", "RTI", "JMP", "BRK"}


class Dis:
    def __init__(self, data, load):
        self.d, self.load = data, load
        self.code = set()        # addresses that begin an instruction
        self.calls = {}          # target -> set of callers
        self.labels = set()

    def at(self, a):
        return self.d[a - self.load]

    def valid(self, a):
        return self.load <= a < self.load + len(self.d)

    def trace(self, entry):
        stack = [entry]
        while stack:
            pc = stack.pop()
            while True:
                if not self.valid(pc) or pc in self.code:
                    break
                op = self.at(pc)
                if op not in OPS:
                    break                    # invalid opcode: stop, likely data
                mn, am = OPS[op]
                n = SIZE[am]
                if not self.valid(pc + n):
                    break
                self.code.add(pc)
                for k in range(1, n + 1):
                    self.code.discard(pc + k)  # operand bytes are not starts
                operand = 0
                if n == 1:
                    operand = self.at(pc + 1)
                elif n == 2:
                    operand = self.at(pc + 1) | (self.at(pc + 2) << 8)
                nxt = pc + 1 + n
                if am == REL:
                    tgt = nxt + (operand - 256 if operand > 127 else operand)
                    self.labels.add(tgt)
                    stack.append(tgt)
                elif mn == "JSR":
                    self.labels.add(operand)
                    self.calls.setdefault(operand, set()).add(pc)
                    stack.append(operand)
                elif mn == "JMP" and am == ABS:
                    self.labels.add(operand)
                    stack.append(operand)
                    break
                if mn in TERMINAL:
                    break
                pc = nxt

    def listing(self, lo=None, hi=None):
        lo = lo if lo is not None else self.load
        hi = hi if hi is not None else self.load + len(self.d)
        out, a = [], lo
        while a < hi:
            if a in self.code:
                mn, am = OPS[self.at(a)]
                n = SIZE[am]
                o = 0
                if n == 1:
                    o = self.at(a + 1)
                elif n == 2:
                    o = self.at(a + 1) | (self.at(a + 2) << 8)
                txt = {
                    IMP: "", ACC: "A", IMM: f"#${o:02X}",
                    ZP: f"${o:02X}", ZPX: f"${o:02X},X", ZPY: f"${o:02X},Y",
                    ABS: f"${o:04X}", ABX: f"${o:04X},X", ABY: f"${o:04X},Y",
                    IND: f"(${o:04X})", IZX: f"(${o:02X},X)", IZY: f"(${o:02X}),Y",
                    REL: f"${a + 2 + (o - 256 if o > 127 else o):04X}",
                }[am]
                lbl = f"L{a:04X}:" if a in self.labels else "      "
                out.append(f"{lbl} ${a:04X}  {mn} {txt}".rstrip())
                a += 1 + n
            else:
                run = []
                while a < hi and a not in self.code and len(run) < 16:
                    run.append(self.at(a)); a += 1
                out.append(f"       ${a - len(run):04X}  .byte " +
                           " ".join(f"${b:02X}" for b in run))
        return "\n".join(out)


if __name__ == "__main__":
    path, load = sys.argv[1], int(sys.argv[2], 0)
    entries = [int(x, 0) for x in sys.argv[3].split(",")]
    data = open(path, "rb").read()
    dis = Dis(data, load)
    for e in entries:
        dis.trace(e)
    n = len(dis.code)
    print(f"; entries={[hex(e) for e in entries]}  instructions={n} "
          f"code-bytes~{load + len(data) - load}", file=sys.stderr)
    if len(sys.argv) > 4:
        lo, hi = (int(x, 0) for x in sys.argv[4].split("-"))
        print(dis.listing(lo, hi))
    else:
        print(dis.listing())
