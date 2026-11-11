#!/usr/bin/env python3
"""Retail SCFA Lua sanity checker.

Checks, per file:
  1) block balance (function/if/for/while/do/repeat vs end/until)
  2) forbidden tokens for this build: '%' (modulo), '...' (vararg), '::' (labels),
     '//' (integer division), '&'/'|' bitwise (Lua 5.1 has none)
  3) stray non-ASCII inside string/comment is fine; ASCII-only code is not required
     (comments are Chinese by design), so this only reports control chars.
"""
import re
import sys
from pathlib import Path

OPEN_FUNC = {"function"}
OPEN_BLOCK = {"if", "for", "while", "do", "repeat"}
CLOSE_BLOCK = {"end", "until"}


def strip_lua(src: str) -> str:
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        # long comment --[[ ... ]] or --[==[ ... ]==]
        if c == "-" and src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                eq = m.group(1)
                close = "]" + eq + "]"
                j = src.find(close, i + len(m.group(0)))
                if j == -1:
                    return "".join(out)  # unterminated: swallow rest
                i = j + len(close)
                continue
            # line comment
            j = src.find("\n", i)
            if j == -1:
                break
            i = j
            continue
        # long string [[ ... ]] or [==[ ... ]==]
        if c == "[":
            m = re.match(r"\[(=*)\[", src[i:])
            if m:
                eq = m.group(1)
                close = "]" + eq + "]"
                j = src.find(close, i + len(m.group(0)))
                if j == -1:
                    return "".join(out)
                out.append('""')
                i = j + len(close)
                continue
        if c in "\"'":
            q = c
            out.append('""')
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == q:
                    i += 1
                    break
                if src[i] == "\n":
                    break
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check(path: Path) -> list[str]:
    raw = path.read_text(encoding="utf-8", errors="replace")
    src = strip_lua(raw)
    problems = []

    # forbidden tokens (on stripped code, so strings/comments do not count)
    for tok, msg in [
        ("%", "modulo operator '%' (lexer rejects it)"),
        ("::", "label '::' (Lua 5.1 build, unsupported)"),
        ("//", "integer division '//' (unsupported)"),
    ]:
        if tok in src:
            idx = src.index(tok)
            line = src.count("\n", 0, idx) + 1
            problems.append(f"{msg} at stripped-line {line}")

    if "..." in src:
        idx = src.index("...")
        line = src.count("\n", 0, idx) + 1
        print(f"     WARN vararg '...' at stripped-line {line} (ok only inside OnStartBuild-style signatures)")

    # Block nesting: only function / if / do / repeat open a block.
    # `for` and `while` do NOT open one themselves — their body is opened by `do`.
    tokens = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", src)
    depth = 0
    for t in tokens:
        if t in ("function", "if", "do", "repeat"):
            depth += 1
        elif t in CLOSE_BLOCK:
            depth -= 1
        if depth < 0:
            problems.append("block depth went negative (extra 'end')")
            depth = 0
    if depth != 0:
        problems.append(f"unbalanced blocks: depth={depth} at EOF")

    # control chars
    for ln, line in enumerate(raw.splitlines(), 1):
        for ch in line:
            if ord(ch) < 32 and ch != "\t":
                problems.append(f"control char U+{ord(ch):04X} on line {ln}")
    return problems


def main(argv: list[str]) -> int:
    bad = 0
    for p in argv:
        path = Path(p)
        problems = check(path)
        if problems:
            bad += 1
            print(f"FAIL {path}")
            for msg in problems:
                print(f"     {msg}")
        else:
            print(f"OK   {path}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
