# CLAUDE.md

Project instructions for agents working in this repository.

**This is a public repository.** `https://github.com/duanefields/7cities`. Anything committed is
published permanently — history survives deletion. The two rules below exist because of that.

## 1. Never commit without explicit approval

Do not run `git commit`, `git push`, `gh pr create`, or anything else that writes to history or to
the remote unless I ask for it in that turn. "Asked in that turn" means a direct instruction like
"commit this" or "push it" — not general enthusiasm, not a previous commit in the same session, not
the fact that a change is finished and tests pass.

Finishing work and committing work are separate steps. Finish the work, report it, and stop.

This overrides any inclination to be helpful by tidying up at the end of a task.

## 2. Sweep before every commit

When a commit _is_ approved, sweep the staged changes first and report what the sweep found. Do not
sweep the working tree — sweep exactly what is about to be committed:

```bash
git diff --cached
```

Check for all four of these:

**Personal information.** Absolute paths or any other home directory; real names, email addresses,
phone numbers; machine names and serial numbers; screenshots that catch a menu bar, a Finder
sidebar, a browser tab strip, or a desktop. Use `~` or a repo-relative path in code, docs and
comments. Developer's name and email in `git` authorship metadata are fine and expected; their name
and email in file _contents_ are usually not.

**Keys and credentials.** API keys, tokens, `.env` files, anything that looks like a secret even if
it is expired or was never valid. An expired key still tells an attacker the format and the service.

**Copyrighted game material.** This is the one that is easy to get wrong, because the whole project
is built around data nobody may redistribute:

- No game data, ever — no disk images, no extracted assets, no map files, no tile bitmaps, no
  charsets, no sprite data, no game text, no decrypted binaries, no disassembly listings.
- `.gitignore` already covers `d64/`, `docs/`, `local/`, `assets/`, `*.d64`, `*.prg`, `*.bin`,
  `*.lst`, `*.disasm.s`, `*.map`, `original_tiles.json`. **Do not weaken it**, and do not
  `git add -f` past it.
- Copyrighted material can also arrive as _inlined constants_: a table of bytes pasted into a Swift
  or Python source file is game data no matter what extension it lives in. Test fixtures captured
  from the original 6502 are the deliberate exception — they are small, they exist to verify a port,
  and they are already committed.
- Addresses, opcodes, structure descriptions and prose analysis in `NOTES.md` are findings, not
  assets. Those are fine.

**Unrelated files.** Anything staged that does not trace to the change being made. `git add -A` is
how scratch files and captured screenshots get published; prefer naming paths explicitly.

If the sweep finds something, stop and say so rather than committing and fixing afterward — a
follow-up commit does not remove anything from history.

## 3. Conventions

- **Commit messages**: plain-English subject line, no Conventional Commits (`feat:`, `fix:`,
  `chore:`). The _body_ should be rich — what changed, why, and what a future reader needs. The
  history here is meant to read as an account of the investigation.

## 4. Where things live

```text
SevenCitiesCore/    the Swift package — everything real lives here
  SevenCitiesCore   decoding, extraction, simulation; no UI
  ViewerKit         the SpriteKit viewer, shared by the app and the CLI
app/                thin Xcode wrapper — bundle and launch only
tools/              Python research tools; not needed to build or run
NOTES.md            the reverse engineering record, including the wrong turns
TODO.md             what is still missing
```

Read `NOTES.md` before doing reverse engineering work. It records failed approaches as well as
findings, specifically so they are not repeated.
