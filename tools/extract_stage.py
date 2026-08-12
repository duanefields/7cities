#!/usr/bin/env python3
"""Extract a raw loader stage from a disk image, with no emulator.

The EA loader ignores the directory completely. It issues `U1:` block reads and
walks **sectors 0-19 of each track, starting at track 1 sector 0**, storing 256
bytes per sector page-aligned into RAM. Nothing is compressed or encrypted, so
a stage can be lifted straight off the image (see NOTES.md).

Because each load leaves the drive's track/sector digits where it stopped,
successive stages are consecutive runs of the same stream — pass `--skip` to
start further in.

    tools/extract_stage.py d64/7CITIES1.D64 --pages 44 -o local/stage1.bin
    tools/extract_stage.py d64/7CITIES1.D64 --skip 44 --pages 40 --load 0x0800

Text in the stages is stored as C64 screen codes offset by `$20`: subtract $20,
then $01-$1A are A-Z. `--strings` decodes it.
"""
import argparse

SECTORS_PER_TRACK = [21] * 17 + [19] * 7 + [18] * 6 + [17] * 5
SECTORS_READ = 20          # the loader takes sectors 0-19 and skips the rest


def sector_offsets():
    """Physical byte offset of every (track, sector) in a .d64."""
    off, table = 0, {}
    for track in range(1, 36):
        for sec in range(SECTORS_PER_TRACK[track - 1]):
            table[(track, sec)] = off
            off += 256
    return table


def load_order():
    """(track, sector) in the order the loader reads them."""
    return [(t, s) for t in range(1, 36) for s in range(SECTORS_READ)
            if s < SECTORS_PER_TRACK[t - 1]]


def extract(image, skip=0, pages=44):
    table, order = sector_offsets(), load_order()
    out = bytearray()
    for ts in order[skip:skip + pages]:
        off = table[ts]
        out += image[off:off + 256]
    return bytes(out)


def screen_text(data, load):
    """Decode runs of screen-code text, which is stored offset by $20."""
    def ch(v):
        v = (v - 0x20) & 0xFF
        if 1 <= v <= 26:
            return chr(64 + v)
        if v in (0x20, 0xFF):
            return " "
        if 0x30 <= v <= 0x39:
            return chr(v)
        return {0x2C: ",", 0x2E: ".", 0x27: "'", 0x21: "!", 0x3F: "?",
                0x2D: "-"}.get(v)

    runs, cur, start = [], [], 0
    for i, b in enumerate(data):
        c = ch(b)
        if c is None:
            if len(cur) >= 10:
                runs.append((load + start, "".join(cur)))
            cur = []
        else:
            if not cur:
                start = i
            cur.append(c)
    if len(cur) >= 10:
        runs.append((load + start, "".join(cur)))
    # Filler decodes to blanks or one repeated punctuation mark, so require
    # both some substance and some variety.
    return [(a, s) for a, s in runs
            if len(s.strip()) >= 8 and len(set(s.strip())) >= 5]


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("image")
    p.add_argument("--skip", type=int, default=0, help="sectors to skip first")
    p.add_argument("--pages", type=int, default=44, help="sectors to read")
    p.add_argument("--load", type=lambda s: int(s, 0), default=0x0800)
    p.add_argument("-o", "--out")
    p.add_argument("--strings", action="store_true")
    a = p.parse_args()

    data = extract(open(a.image, "rb").read(), a.skip, a.pages)
    end = a.load + len(data) - 1
    print(f"{len(data)} bytes -> ${a.load:04X}-${end:04X} "
          f"({a.pages} sectors, skipping {a.skip})")
    density = (data.count(0x20), data.count(0x60), data.count(0x85))
    print(f"  JSR={density[0]}  RTS={density[1]}  STAzp={density[2]}")

    if a.out:
        open(a.out, "wb").write(data)
        print(f"  wrote {a.out}")
    if a.strings:
        print()
        for addr, s in screen_text(data, a.load):
            print(f"  ${addr:04X}  {s}")


if __name__ == "__main__":
    main()
