#!/usr/bin/env python3
"""A 6502 interpreter, for stepping the World Maker outside the emulator.

Why this exists: the coastline walker is a backtracking search with three
separate self-modifications and a stack-discarding non-local exit. Transcribing
it to Swift and comparing the finished 12,800-byte mask gives exactly one bit of
feedback — "the walk went somewhere else" — with no way to localize a fault.
Running the original here instead makes every intermediate state observable, so a
port can be diffed against it step by step.

It also replaces most emulator round-trips. Driving VICE over MCP has cost a
bricked machine, two silently raced bisects and a stalled watchpoint in a single
session; this is in-process, deterministic, and cannot wedge.

Scope: official NMOS opcodes, binary arithmetic, no interrupts and no I/O. That
is enough for the generation code, which is pure computation over RAM once the
seed is pinned. Unknown opcodes raise rather than being skipped — silently
ignoring one would produce plausible, wrong output, which is the failure mode
this tool exists to avoid. Decimal mode likewise raises if it is ever entered.

Self-test: `python3 tools/sim6502.py --check` runs the original's multiply,
divide and LFSR against the fixtures captured from the real 6502 in
`SevenCitiesCore/Tests/.../Fixtures`. The interpreter is not to be trusted for
anything until that passes.
"""
import json
import os
import sys

N, V, B, D, I, Z, C = 0x80, 0x40, 0x10, 0x08, 0x04, 0x02, 0x01


class Halt(Exception):
    """Raised when execution returns to the sentinel address."""


class Sim6502:
    SENTINEL = 0xFFF0

    def __init__(self, memory=None):
        self.mem = bytearray(0x10000) if memory is None else bytearray(memory)
        self.a = self.x = self.y = 0
        self.sp = 0xFD
        self.pc = 0
        self.p = 0x24
        self.cycles = 0
        self.trace = None            # callable(pc, opcode) or None
        self.io_read = None          # callable(addr) -> int | None, for $D000-$DFFF
        self.stops = set()           # PCs at which run_until() halts

    # -- memory -----------------------------------------------------------
    def load(self, addr, data):
        self.mem[addr:addr + len(data)] = data

    def rd(self, a):
        a &= 0xFFFF
        if 0xD000 <= a < 0xE000 and self.io_read is not None:
            v = self.io_read(a)
            if v is not None:
                return v
        return self.mem[a]

    def wr(self, a, v):
        self.mem[a & 0xFFFF] = v & 0xFF

    def rdw(self, a):
        return self.rd(a) | (self.rd(a + 1) << 8)

    # -- flags ------------------------------------------------------------
    def _set(self, mask, on):
        self.p = (self.p | mask) if on else (self.p & ~mask & 0xFF)

    def _nz(self, v):
        v &= 0xFF
        self._set(Z, v == 0)
        self._set(N, v & 0x80)
        return v

    # -- stack ------------------------------------------------------------
    def push(self, v):
        self.wr(0x100 + self.sp, v)
        self.sp = (self.sp - 1) & 0xFF

    def pop(self):
        self.sp = (self.sp + 1) & 0xFF
        return self.rd(0x100 + self.sp)

    # -- addressing -------------------------------------------------------
    def _imm(self):
        a = self.pc
        self.pc += 1
        return a

    def _zp(self):
        return self.rd(self._imm())

    def _zpx(self):
        return (self.rd(self._imm()) + self.x) & 0xFF

    def _zpy(self):
        return (self.rd(self._imm()) + self.y) & 0xFF

    def _abs(self):
        a = self.rdw(self.pc)
        self.pc += 2
        return a

    def _absx(self):
        return (self._abs() + self.x) & 0xFFFF

    def _absy(self):
        return (self._abs() + self.y) & 0xFFFF

    def _indx(self):
        p = (self.rd(self._imm()) + self.x) & 0xFF
        return self.rd(p) | (self.rd((p + 1) & 0xFF) << 8)

    def _indy(self):
        p = self.rd(self._imm())
        base = self.rd(p) | (self.rd((p + 1) & 0xFF) << 8)
        return (base + self.y) & 0xFFFF

    # -- operations -------------------------------------------------------
    def _adc(self, m):
        if self.p & D:
            raise NotImplementedError("decimal mode entered; not supported")
        c = 1 if self.p & C else 0
        t = self.a + m + c
        self._set(C, t > 0xFF)
        self._set(V, (~(self.a ^ m) & (self.a ^ t) & 0x80) != 0)
        self.a = self._nz(t)

    def _sbc(self, m):
        self._adc(m ^ 0xFF)

    def _cmp(self, reg, m):
        t = (reg - m) & 0x1FF
        self._set(C, reg >= m)
        self._nz(t & 0xFF)

    def _branch(self, take):
        off = self.rd(self._imm())
        if take:
            if off & 0x80:
                off -= 0x100
            self.pc = (self.pc + off) & 0xFFFF

    def step(self):
        if self.pc == self.SENTINEL:
            raise Halt()
        pc0 = self.pc
        op = self.rd(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        if self.trace:
            self.trace(pc0, op)
        self.cycles += 1
        self._exec(op, pc0)

    def _exec(self, op, pc0):
        m = self  # brevity

        # --- loads / stores
        if op == 0xA9: m.a = m._nz(m.rd(m._imm()))
        elif op == 0xA5: m.a = m._nz(m.rd(m._zp()))
        elif op == 0xB5: m.a = m._nz(m.rd(m._zpx()))
        elif op == 0xAD: m.a = m._nz(m.rd(m._abs()))
        elif op == 0xBD: m.a = m._nz(m.rd(m._absx()))
        elif op == 0xB9: m.a = m._nz(m.rd(m._absy()))
        elif op == 0xA1: m.a = m._nz(m.rd(m._indx()))
        elif op == 0xB1: m.a = m._nz(m.rd(m._indy()))
        elif op == 0xA2: m.x = m._nz(m.rd(m._imm()))
        elif op == 0xA6: m.x = m._nz(m.rd(m._zp()))
        elif op == 0xB6: m.x = m._nz(m.rd(m._zpy()))
        elif op == 0xAE: m.x = m._nz(m.rd(m._abs()))
        elif op == 0xBE: m.x = m._nz(m.rd(m._absy()))
        elif op == 0xA0: m.y = m._nz(m.rd(m._imm()))
        elif op == 0xA4: m.y = m._nz(m.rd(m._zp()))
        elif op == 0xB4: m.y = m._nz(m.rd(m._zpx()))
        elif op == 0xAC: m.y = m._nz(m.rd(m._abs()))
        elif op == 0xBC: m.y = m._nz(m.rd(m._absx()))
        elif op == 0x85: m.wr(m._zp(), m.a)
        elif op == 0x95: m.wr(m._zpx(), m.a)
        elif op == 0x8D: m.wr(m._abs(), m.a)
        elif op == 0x9D: m.wr(m._absx(), m.a)
        elif op == 0x99: m.wr(m._absy(), m.a)
        elif op == 0x81: m.wr(m._indx(), m.a)
        elif op == 0x91: m.wr(m._indy(), m.a)
        elif op == 0x86: m.wr(m._zp(), m.x)
        elif op == 0x96: m.wr(m._zpy(), m.x)
        elif op == 0x8E: m.wr(m._abs(), m.x)
        elif op == 0x84: m.wr(m._zp(), m.y)
        elif op == 0x94: m.wr(m._zpx(), m.y)
        elif op == 0x8C: m.wr(m._abs(), m.y)

        # --- transfers
        elif op == 0xAA: m.x = m._nz(m.a)
        elif op == 0xA8: m.y = m._nz(m.a)
        elif op == 0x8A: m.a = m._nz(m.x)
        elif op == 0x98: m.a = m._nz(m.y)
        elif op == 0xBA: m.x = m._nz(m.sp)
        elif op == 0x9A: m.sp = m.x

        # --- stack
        elif op == 0x48: m.push(m.a)
        elif op == 0x68: m.a = m._nz(m.pop())
        elif op == 0x08: m.push(m.p | B | 0x20)
        elif op == 0x28: m.p = (m.pop() | 0x20) & ~B & 0xFF

        # --- logic
        elif op == 0x29: m.a = m._nz(m.a & m.rd(m._imm()))
        elif op == 0x25: m.a = m._nz(m.a & m.rd(m._zp()))
        elif op == 0x35: m.a = m._nz(m.a & m.rd(m._zpx()))
        elif op == 0x2D: m.a = m._nz(m.a & m.rd(m._abs()))
        elif op == 0x3D: m.a = m._nz(m.a & m.rd(m._absx()))
        elif op == 0x39: m.a = m._nz(m.a & m.rd(m._absy()))
        elif op == 0x21: m.a = m._nz(m.a & m.rd(m._indx()))
        elif op == 0x31: m.a = m._nz(m.a & m.rd(m._indy()))
        elif op == 0x09: m.a = m._nz(m.a | m.rd(m._imm()))
        elif op == 0x05: m.a = m._nz(m.a | m.rd(m._zp()))
        elif op == 0x15: m.a = m._nz(m.a | m.rd(m._zpx()))
        elif op == 0x0D: m.a = m._nz(m.a | m.rd(m._abs()))
        elif op == 0x1D: m.a = m._nz(m.a | m.rd(m._absx()))
        elif op == 0x19: m.a = m._nz(m.a | m.rd(m._absy()))
        elif op == 0x01: m.a = m._nz(m.a | m.rd(m._indx()))
        elif op == 0x11: m.a = m._nz(m.a | m.rd(m._indy()))
        elif op == 0x49: m.a = m._nz(m.a ^ m.rd(m._imm()))
        elif op == 0x45: m.a = m._nz(m.a ^ m.rd(m._zp()))
        elif op == 0x55: m.a = m._nz(m.a ^ m.rd(m._zpx()))
        elif op == 0x4D: m.a = m._nz(m.a ^ m.rd(m._abs()))
        elif op == 0x5D: m.a = m._nz(m.a ^ m.rd(m._absx()))
        elif op == 0x59: m.a = m._nz(m.a ^ m.rd(m._absy()))
        elif op == 0x41: m.a = m._nz(m.a ^ m.rd(m._indx()))
        elif op == 0x51: m.a = m._nz(m.a ^ m.rd(m._indy()))

        # --- arithmetic
        elif op == 0x69: m._adc(m.rd(m._imm()))
        elif op == 0x65: m._adc(m.rd(m._zp()))
        elif op == 0x75: m._adc(m.rd(m._zpx()))
        elif op == 0x6D: m._adc(m.rd(m._abs()))
        elif op == 0x7D: m._adc(m.rd(m._absx()))
        elif op == 0x79: m._adc(m.rd(m._absy()))
        elif op == 0x61: m._adc(m.rd(m._indx()))
        elif op == 0x71: m._adc(m.rd(m._indy()))
        elif op == 0xE9: m._sbc(m.rd(m._imm()))
        elif op == 0xE5: m._sbc(m.rd(m._zp()))
        elif op == 0xF5: m._sbc(m.rd(m._zpx()))
        elif op == 0xED: m._sbc(m.rd(m._abs()))
        elif op == 0xFD: m._sbc(m.rd(m._absx()))
        elif op == 0xF9: m._sbc(m.rd(m._absy()))
        elif op == 0xE1: m._sbc(m.rd(m._indx()))
        elif op == 0xF1: m._sbc(m.rd(m._indy()))

        # --- compares
        elif op == 0xC9: m._cmp(m.a, m.rd(m._imm()))
        elif op == 0xC5: m._cmp(m.a, m.rd(m._zp()))
        elif op == 0xD5: m._cmp(m.a, m.rd(m._zpx()))
        elif op == 0xCD: m._cmp(m.a, m.rd(m._abs()))
        elif op == 0xDD: m._cmp(m.a, m.rd(m._absx()))
        elif op == 0xD9: m._cmp(m.a, m.rd(m._absy()))
        elif op == 0xC1: m._cmp(m.a, m.rd(m._indx()))
        elif op == 0xD1: m._cmp(m.a, m.rd(m._indy()))
        elif op == 0xE0: m._cmp(m.x, m.rd(m._imm()))
        elif op == 0xE4: m._cmp(m.x, m.rd(m._zp()))
        elif op == 0xEC: m._cmp(m.x, m.rd(m._abs()))
        elif op == 0xC0: m._cmp(m.y, m.rd(m._imm()))
        elif op == 0xC4: m._cmp(m.y, m.rd(m._zp()))
        elif op == 0xCC: m._cmp(m.y, m.rd(m._abs()))

        # --- inc / dec
        elif op == 0xE6: a = m._zp(); m.wr(a, m._nz(m.rd(a) + 1))
        elif op == 0xF6: a = m._zpx(); m.wr(a, m._nz(m.rd(a) + 1))
        elif op == 0xEE: a = m._abs(); m.wr(a, m._nz(m.rd(a) + 1))
        elif op == 0xFE: a = m._absx(); m.wr(a, m._nz(m.rd(a) + 1))
        elif op == 0xC6: a = m._zp(); m.wr(a, m._nz(m.rd(a) - 1))
        elif op == 0xD6: a = m._zpx(); m.wr(a, m._nz(m.rd(a) - 1))
        elif op == 0xCE: a = m._abs(); m.wr(a, m._nz(m.rd(a) - 1))
        elif op == 0xDE: a = m._absx(); m.wr(a, m._nz(m.rd(a) - 1))
        elif op == 0xE8: m.x = m._nz(m.x + 1)
        elif op == 0xC8: m.y = m._nz(m.y + 1)
        elif op == 0xCA: m.x = m._nz(m.x - 1)
        elif op == 0x88: m.y = m._nz(m.y - 1)

        # --- shifts (accumulator then memory)
        elif op == 0x0A:
            m._set(C, m.a & 0x80); m.a = m._nz(m.a << 1)
        elif op == 0x4A:
            m._set(C, m.a & 0x01); m.a = m._nz(m.a >> 1)
        elif op == 0x2A:
            c = 1 if m.p & C else 0
            m._set(C, m.a & 0x80); m.a = m._nz((m.a << 1) | c)
        elif op == 0x6A:
            c = 0x80 if m.p & C else 0
            m._set(C, m.a & 0x01); m.a = m._nz((m.a >> 1) | c)
        elif op in (0x06, 0x16, 0x0E, 0x1E):
            a = {0x06: m._zp, 0x16: m._zpx, 0x0E: m._abs, 0x1E: m._absx}[op]()
            v = m.rd(a); m._set(C, v & 0x80); m.wr(a, m._nz(v << 1))
        elif op in (0x46, 0x56, 0x4E, 0x5E):
            a = {0x46: m._zp, 0x56: m._zpx, 0x4E: m._abs, 0x5E: m._absx}[op]()
            v = m.rd(a); m._set(C, v & 0x01); m.wr(a, m._nz(v >> 1))
        elif op in (0x26, 0x36, 0x2E, 0x3E):
            a = {0x26: m._zp, 0x36: m._zpx, 0x2E: m._abs, 0x3E: m._absx}[op]()
            v = m.rd(a); c = 1 if m.p & C else 0
            m._set(C, v & 0x80); m.wr(a, m._nz((v << 1) | c))
        elif op in (0x66, 0x76, 0x6E, 0x7E):
            a = {0x66: m._zp, 0x76: m._zpx, 0x6E: m._abs, 0x7E: m._absx}[op]()
            v = m.rd(a); c = 0x80 if m.p & C else 0
            m._set(C, v & 0x01); m.wr(a, m._nz((v >> 1) | c))

        # --- bit
        elif op in (0x24, 0x2C):
            v = m.rd(m._zp() if op == 0x24 else m._abs())
            m._set(Z, (m.a & v) == 0)
            m._set(N, v & 0x80)
            m._set(V, v & 0x40)

        # --- jumps / calls
        elif op == 0x4C: m.pc = m._abs()
        elif op == 0x6C:
            p = m._abs()
            # The NMOS indirect-JMP page-boundary bug, preserved deliberately.
            hi = (p & 0xFF00) | ((p + 1) & 0xFF)
            m.pc = m.rd(p) | (m.rd(hi) << 8)
        elif op == 0x20:
            t = m._abs()
            r = (m.pc - 1) & 0xFFFF
            m.push(r >> 8); m.push(r & 0xFF)
            m.pc = t
        elif op == 0x60:
            lo = m.pop(); hi = m.pop()
            m.pc = ((hi << 8) | lo) + 1 & 0xFFFF
        elif op == 0x40:
            m.p = (m.pop() | 0x20) & ~B & 0xFF
            lo = m.pop(); hi = m.pop()
            m.pc = (hi << 8) | lo

        # --- branches
        elif op == 0xD0: m._branch(not (m.p & Z))
        elif op == 0xF0: m._branch(bool(m.p & Z))
        elif op == 0x90: m._branch(not (m.p & C))
        elif op == 0xB0: m._branch(bool(m.p & C))
        elif op == 0x10: m._branch(not (m.p & N))
        elif op == 0x30: m._branch(bool(m.p & N))
        elif op == 0x50: m._branch(not (m.p & V))
        elif op == 0x70: m._branch(bool(m.p & V))

        # --- flags / misc
        elif op == 0x18: m._set(C, False)
        elif op == 0x38: m._set(C, True)
        elif op == 0x58: m._set(I, False)
        elif op == 0x78: m._set(I, True)
        elif op == 0xB8: m._set(V, False)
        elif op == 0xD8: m._set(D, False)
        elif op == 0xF8: m._set(D, True)
        elif op == 0xEA: pass
        else:
            raise NotImplementedError(
                f"unimplemented opcode ${op:02X} at ${pc0:04X}")

    # -- driving ----------------------------------------------------------
    def run_until(self, stops, start=None, max_steps=200_000_000):
        """Run until the PC reaches one of `stops`. Returns (pc, steps).

        Used to drive whole phases, where there is no single routine to call and
        the interesting boundaries are addresses rather than returns.
        """
        if start is not None:
            self.pc = start
        stops = set(stops)
        n = 0
        while n < max_steps:
            if self.pc in stops:
                return self.pc, n
            self.step()
            n += 1
        raise SystemExit(f"ran {max_steps} steps without reaching {stops}")

    def call(self, addr, max_steps=50_000_000):
        """JSR to `addr` and run until it returns. Returns steps executed."""
        self.push((self.SENTINEL - 1) >> 8)
        self.push((self.SENTINEL - 1) & 0xFF)
        self.pc = addr
        n = 0
        try:
            while n < max_steps:
                self.step()
                n += 1
        except Halt:
            return n
        raise SystemExit(f"ran {max_steps} steps without returning from ${addr:04X}")


# -- self-test ------------------------------------------------------------

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/Fixtures"


def _game3():
    return open(f"{ROOT}/local/game3.bin", "rb").read()


def check():
    """Run the original's routines against fixtures captured from real hardware.

    These fixtures were produced by executing the same 6502 code inside VICE, so
    agreeing with them is evidence about this interpreter rather than about the
    routines.
    """
    code = _game3()
    failures = 0

    # LFSR at $0AE2: A holds the next value, $CD/$CF the state.
    ref = json.load(open(f"{FIX}/rng_reference.json"))
    for seq in ref["sequences"]:
        cpu = Sim6502()
        cpu.load(0x0800, code)
        cpu.wr(0xCD, seq["seed_cd"])
        cpu.wr(0xCF, seq["seed_cf"])
        for i, want in enumerate(seq["values"]):
            cpu.call(0x0AE2)
            if cpu.a != want:
                print(f"  LFSR seed ${seq['seed_cd']:02X}{seq['seed_cf']:02X} "
                      f"step {i}: expected ${want:02X}, got ${cpu.a:02X}")
                failures += 1
                break
    print(f"  LFSR: {len(ref['sequences'])} sequences checked")

    # Each fixture entry fixes one operand and sweeps the other over 0...255.
    ref = json.load(open(f"{FIX}/arith_reference.json"))
    mul, div = ref["multiply"], ref["divide"]

    checked = 0
    for case in mul:                       # $0A51: A x Y, low in A, high in Y
        for i, (lo, hi) in enumerate(zip(case["low"], case["high"])):
            cpu = Sim6502(); cpu.load(0x0800, code)
            cpu.a, cpu.y = i, case["multiplier"]
            cpu.call(0x0A51)
            checked += 1
            if cpu.a != lo or cpu.y != hi:
                print(f"  MUL {i}x{case['multiplier']}: expected {lo}/{hi}, "
                      f"got {cpu.a}/{cpu.y}")
                failures += 1
                break

    for case in div:                       # $0A6E: (Y:A) / X, quotient in A
        for i, (q, r) in enumerate(zip(case["quotient"], case["remainder"])):
            cpu = Sim6502(); cpu.load(0x0800, code)
            cpu.a, cpu.y, cpu.x = i, case["high"], case["divisor"]
            cpu.call(0x0A6E)
            checked += 1
            if cpu.a != q or cpu.y != r:
                print(f"  DIV ({case['high']}:{i})/{case['divisor']}: expected "
                      f"{q} rem {r}, got {cpu.a} rem {cpu.y}")
                failures += 1
                break
    print(f"  arithmetic: {checked} multiply/divide cases checked")

    print("PASS — interpreter agrees with the real 6502" if not failures
          else f"FAIL — {failures} disagreements")
    return failures == 0


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(0 if check() else 1)
    print(__doc__)
