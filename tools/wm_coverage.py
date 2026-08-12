#!/usr/bin/env python3
"""Find which routines the land-mass phase actually executes.

Static reachability is useless for scoping this port. Walking calls and
branches from `$23D3` reaches 7,924 of the program's 8,152 instructions — 97% —
because `$1900` does `JMP $2473` -> `JMP $20A3`, re-entering the World Maker's
init. One error/restart path makes essentially everything reachable, so "what
does the land-mass phase depend on" cannot be answered by reading the call
graph.

Measure it instead. VICE checkpoints count hits without halting (`stop=False`),
so putting one on every `JSR` target and running the phase gives exactly the set
of routines that ran. Routine granularity is all that is needed to scope a port,
which keeps this to a couple of hundred checkpoints rather than per-instruction
tracing.

The phase is isolated by arming the probes only after execution reaches `$212A`,
so the World Maker's init does not pollute the result.

Requires vice-mcp (a VICE fork with MCP built in, not Homebrew VICE).
"""
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402
from wm_config import boot, wait_hit, ENTRY, LANDMASS_DONE  # noqa: E402
from wm_deterministic import apply_patches  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PHASE_START = 0x212A


def jsr_targets():
    txt = open(f"{ROOT}/local/game3.disasm.lst").read()
    return sorted({int(a, 16) for a in re.findall(r"JSR \$([0-9A-F]{4})", txt)})


def clear():
    for cp in call("vice_checkpoint_list")["checkpoints"]:
        call("vice_checkpoint_delete", checkpoint_num=cp["checkpoint_num"])


def main():
    code = open(f"{ROOT}/local/game3.bin", "rb").read()
    seed = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0x1234
    config = int(sys.argv[2]) if len(sys.argv) > 2 else 0

    boot(code)
    apply_patches(seed, config)

    # Stop at the phase entry so the init's calls are not counted.
    clear()
    num = call("vice_checkpoint_add", start=f"${PHASE_START:04X}",
               exec=True, stop=True)["checkpoint_num"]
    call("vice_keyboard_type", text=f"SYS {ENTRY}\n")
    if not wait_hit(num, timeout=180):
        raise SystemExit("never reached the land-mass phase entry")
    clear()

    targets = jsr_targets()
    print(f"arming {len(targets)} probes", flush=True)
    probe = {}
    for addr in targets:
        r = call("vice_checkpoint_add", start=f"${addr:04X}", exec=True, stop=False)
        probe[r["checkpoint_num"]] = addr
    done = call("vice_checkpoint_add", start=f"${LANDMASS_DONE:04X}",
                exec=True, stop=True)["checkpoint_num"]

    t0 = time.time()
    call("vice_execution_run")
    if not wait_hit(done, timeout=900):
        raise SystemExit("phase never finished with probes armed")
    print(f"phase completed in {time.time() - t0:.0f}s", flush=True)

    hits = {}
    for cp in call("vice_checkpoint_list")["checkpoints"]:
        a = probe.get(cp["checkpoint_num"])
        if a is not None and cp["hit_count"] > 0:
            hits[a] = cp["hit_count"]
    clear()

    print(f"\n{len(hits)} of {len(targets)} routines executed\n")
    for a, n in sorted(hits.items(), key=lambda kv: -kv[1]):
        print(f"  ${a:04X}  x{n}")

    out = f"{ROOT}/local/wm_coverage.json"
    with open(out, "w") as f:
        json.dump({"seed": seed, "config": config,
                   "executed": {f"${a:04X}": n for a, n in sorted(hits.items())},
                   "notExecuted": [f"${a:04X}" for a in targets if a not in hits]},
                  f, indent=1)
    print(f"\n-> {os.path.relpath(out, ROOT)}")


if __name__ == "__main__":
    main()
