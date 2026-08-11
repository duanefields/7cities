#!/usr/bin/env python3
"""Minimal D64 reader: directory listing + file extraction."""
import sys, os

SPT = [(1, 17, 21), (18, 24, 19), (25, 30, 18), (31, 35, 17)]

def sectors_per_track(t):
    for lo, hi, n in SPT:
        if lo <= t <= hi:
            return n
    raise ValueError(f"bad track {t}")

def offset(t, s):
    off = 0
    for tt in range(1, t):
        off += sectors_per_track(tt) * 256
    return off + s * 256

FTYPES = {0: "DEL", 1: "SEQ", 2: "PRG", 3: "USR", 4: "REL"}

PETSCII_STRIP = str.maketrans({0xa0: None})

def petscii(b):
    out = []
    for c in b:
        if c == 0xa0:
            continue
        if 0x41 <= c <= 0x5a:
            out.append(chr(c).lower())
        elif 0xc1 <= c <= 0xda:
            out.append(chr(c - 0x80))
        elif 0x20 <= c <= 0x5f:
            out.append(chr(c))
        else:
            out.append(f"{{{c:02x}}}")
    return "".join(out).rstrip()

class D64:
    def __init__(self, path):
        self.data = open(path, "rb").read()

    def sector(self, t, s):
        o = offset(t, s)
        return self.data[o:o + 256]

    def bam(self):
        return self.sector(18, 0)

    def disk_name(self):
        b = self.bam()
        return petscii(b[0x90:0xa0]), petscii(b[0xa2:0xa4]), petscii(b[0xa5:0xa7])

    def entries(self):
        t, s = 18, 1
        seen = set()
        out = []
        while t != 0 and (t, s) not in seen:
            seen.add((t, s))
            sec = self.sector(t, s)
            for i in range(8):
                e = sec[i * 32:(i + 1) * 32]
                ft = e[2]
                if ft == 0:
                    continue
                out.append({
                    "name": petscii(e[5:0x15]),
                    "type": FTYPES.get(ft & 0x0f, "???"),
                    "closed": bool(ft & 0x80),
                    "locked": bool(ft & 0x40),
                    "track": e[3], "sector": e[4],
                    "blocks": e[0x1e] | (e[0x1f] << 8),
                    "raw_type": ft,
                })
            t, s = sec[0], sec[1]
        return out

    def read_chain(self, t, s):
        out = bytearray()
        seen = set()
        while t != 0:
            if (t, s) in seen:
                break
            seen.add((t, s))
            sec = self.sector(t, s)
            nt, ns = sec[0], sec[1]
            if nt == 0:
                out += sec[2:2 + max(0, ns - 1)]
                break
            out += sec[2:]
            t, s = nt, ns
        return bytes(out)

    def free_map(self):
        """Return set of (t,s) marked allocated in BAM."""
        b = self.bam()
        alloc = set()
        for t in range(1, 36):
            base = 4 + (t - 1) * 4
            bits = b[base + 1] | (b[base + 2] << 8) | (b[base + 3] << 16)
            for s in range(sectors_per_track(t)):
                if not (bits >> s) & 1:
                    alloc.add((t, s))
        return alloc

if __name__ == "__main__":
    for path in sys.argv[1:]:
        d = D64(path)
        name, did, dos = d.disk_name()
        print(f"\n=== {os.path.basename(path)}  '{name}' {did} {dos} ===")
        ents = d.entries()
        for e in ents:
            print(f"{e['blocks']:5d}  \"{e['name']}\"{'':<2} {e['type']}{'<' if e['locked'] else ''}"
                  f"{'' if e['closed'] else '*'}   start t{e['track']}/s{e['sector']} rawtype={e['raw_type']:#04x}")
        alloc = d.free_map()
        print(f"  directory entries: {len(ents)}   BAM-allocated sectors: {len(alloc)} / 683")
