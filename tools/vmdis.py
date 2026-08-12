#!/usr/bin/env python3
"""Disassemble the bytecode program embedded in the $C000 loader.

The loader is a threaded bytecode VM used as copy protection. `JSR $C482` is
followed inline by bytecode; the dispatcher steals its own return address to
find it. See NOTES.md for how the dispatcher and obfuscation were recovered.

Registers, in the VM's terms:

    $26/$27 + Y   bytecode program counter
    $22/$23       16-bit pointer register, loaded by the operand fetch
    $28           8-bit accumulator
    $2C/$2D       working pointer used by the decrypt instruction
    $C63B/$C63C   X and Y passed to native calls

Operands are masked: pointers are `low ^ $41`, `high ^ $CE`; immediates `^ $8B`.
"""
import sys

LOAD = 0xC000
PTR_LO_MASK, PTR_HI_MASK, IMM_MASK = 0x41, 0xCE, 0x8B

# opcode -> (mnemonic, operand kind)
#   ptr = two masked bytes forming an address
#   imm = one masked byte
#   none
OPS = {
    0x00: ("JMP",       "ptr"),
    0x01: ("AND",       "imm"),
    0x02: ("SYS",       "ptr"),   # call native code, A=acc, X/Y from $C63B/C
    0x03: ("JZ",        "ptr"),
    0x04: ("LDI",       "imm"),
    0x05: ("LDA",       "ptr"),   # acc = [addr]
    0x06: ("CALL",      "ptr"),
    0x07: ("STA",       "ptr"),   # [addr] = acc
    0x08: ("SUBI",      "imm"),
    0x09: ("JMPIND",    "ptr"),   # jump to native code at addr
    0x0A: ("RET",       "none"),
    0x0B: ("LDAX",      "ptr"),   # acc = [addr + acc]
    0x0C: ("ASL",       "none"),
    0x0D: ("INC",       "ptr"),   # [addr] += 1; acc = result
    0x0E: ("ADD",       "ptr"),   # acc += [addr]
    0x0F: ("DECRYPT2",  "none"),  # decrypt 2 bytes at ($2C), key = $2D ^ $7F
    0x10: ("JNZ",       "ptr"),
    0x11: ("SUB",       "ptr"),   # acc -= [addr]
    0x12: ("JPL",       "ptr"),   # jump if acc positive
    0x13: ("SETXY",     "ptr"),   # $C63B/$C63C = addr, used by the next SYS
}


def disassemble(data, jsr_site, limit=400, ystart=4):
    """Walk the bytecode following a `JSR $C482` at `jsr_site`.

    The dispatcher sets its pointer to the JSR's return address (site + 2) and
    starts at Y = 4, so the bytecode begins six bytes after the JSR. Empirically
    that is the only alignment giving long runs of valid opcodes.
    """
    out = []
    pc = (jsr_site + 2) - LOAD + ystart
    seen = set()
    for _ in range(limit):
        if pc in seen or pc >= len(data):
            break
        seen.add(pc)
        addr = LOAD + pc
        op = data[pc]
        entry = OPS.get(op)
        if entry is None:
            out.append((addr, f".byte ${op:02X}   ; not a valid opcode — end of stream?"))
            break
        name, kind = entry
        pc += 1
        if kind == "ptr":
            lo = data[pc] ^ PTR_LO_MASK
            hi = data[pc + 1] ^ PTR_HI_MASK
            pc += 2
            out.append((addr, f"{name:9s} ${hi << 8 | lo:04X}"))
        elif kind == "imm":
            imm = data[pc] ^ IMM_MASK
            pc += 1
            out.append((addr, f"{name:9s} #${imm:02X}"))
        else:
            out.append((addr, name))
        if name in ("JMP", "RET", "JMPIND"):
            out.append((addr, "   ; --- flow ends here ---"))
            break
    return out


def disassemble_at(data, addr, limit=400):
    """Disassemble bytecode that begins exactly at `addr`."""
    return disassemble(data, addr - 2 - 4, limit=limit)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "local/loader.bin"
    start = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0xC02D
    data = open(path, "rb").read()
    if "--at" in sys.argv:
        print(f"; bytecode at ${start:04X}")
        rows = disassemble_at(data, start)
    else:
        print(f"; bytecode following JSR $C482 at ${start:04X}")
        rows = disassemble(data, start)
    for addr, text in rows:
        print(f"  ${addr:04X}  {text}")


if __name__ == "__main__":
    main()
