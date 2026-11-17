#!/usr/bin/env python3
"""gen_icons.py: translate src/draw_icons.inc into mac/icons_data.c.

The Windows toolbar icons are small "programs" assembled from .byte/.long directives
(see the comment at the top of draw_icons.inc): a kind, a point count, a stroke width,
an alpha, then float coordinates written as their bit patterns. This reads that file and
writes the same programs as C arrays, so the macOS toolbar shows the same glyphs without
a hand transcription.

Run from the repository root (the output is committed, so building needs no Python):

    python3 mac/tools/gen_icons.py
"""
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "src" / "draw_icons.inc"
OUT = ROOT / "mac" / "icons_data.c"

# the order of the IC_ enum in mac/icons.h
ORDER = [
    ("rect", "rect"), ("ellipse", "ellipse"), ("line", "line"), ("arrow", "arrow"),
    ("pen", "pen"), ("marker", "marker"), ("mosaic", None), ("text", "text"),
    ("number", "number"), ("undo", "undo"), ("redo", "redo"), ("pin", "pin"),
    ("save", "save"), ("close", "close"), ("ok", "ok"), ("ocr", "ocr"),
    ("ocrcopy", "ocrcopy"), ("long", "long"),
]


def f32(bits):
    return struct.unpack("<f", struct.pack("<I", bits & 0xFFFFFFFF))[0]


def parse(text):
    """-> {name: [ (kind, n, width, alpha, coords) ... ] }"""
    progs = {}
    lines = text.replace("\\\n", "").splitlines()
    label = None
    i = 0
    # strip comments first, keeping the labels and directives
    clean = []
    for line in lines:
        line = line.split("/*")[0] if "/*" in line and "*/" in line else line
        clean.append(line)
    i = 0
    while i < len(clean):
        line = clean[i].strip()
        m = re.match(r"^\.Lic_([A-Za-z0-9_]+):\s*$", line)
        if m:
            label = m.group(1)
            progs.setdefault(label, [])
            i += 1
            continue
        m = re.match(r"^\.Lic_([A-Za-z0-9_]+):\s+\.long\s+(.*)$", line)
        if m:
            label = m.group(1)
            vals = [int(v, 16) for v in re.findall(r"0x[0-9A-Fa-f]+", m.group(2))]
            progs[label] = [("grid", [f32(v) for v in vals])]
            i += 1
            continue
        if label and line.startswith(".byte"):
            nums = [int(v.strip()) for v in line[5:].split(",")]
            kind = nums[0]
            if kind == 0:
                progs[label].append((0, 0, 0, 0, []))
                i += 1
                continue
            n, width, alpha = nums[1], nums[2], nums[3]
            nvals = 2 * n if kind != 3 else 4
            coords = []
            i += 1
            while len(coords) < nvals and i < len(clean):
                m2 = re.match(r"^\.long\s+(.*)$", clean[i].strip())
                if not m2:
                    break
                vals = [int(v, 16) for v in re.findall(r"0x[0-9A-Fa-f]+", m2.group(1))]
                coords.extend(f32(v) for v in vals)
                i += 1
            progs[label].append((kind, n, width, alpha, coords[:nvals]))
            continue
        i += 1
    return progs


def emit(progs):
    out = []
    out.append("/* Generated from src/draw_icons.inc by mac/tools/gen_icons.py. Do not edit. */")
    out.append('#include "icons.h"')
    out.append("")
    names = []
    for enum_name, prog in ORDER:
        if prog is None:
            names.append("NULL")
            continue
        ops = progs[prog]
        rows = []
        for kind, n, width, alpha, coords in ops:
            vals = ", ".join(f"{v:#.9g}f" if v != int(v) else f"{int(v)}.0f" for v in coords)
            if not vals:
                vals = "0"
            rows.append(f"    {{{kind}, {n}, {width}, {alpha}, {{{vals}}}}},")
        out.append(f"static const DcIconOp icon_{prog}[] = {{")
        out.extend(rows)
        out.append("};")
        out.append("")
        names.append(f"icon_{prog}")
    out.append("const DcIconOp *const dc_icons[IC_COUNT] = {")
    out.append("    " + ", ".join(names) + ",")
    out.append("};")
    out.append("")
    OUT.write_text("\n".join(out))
    print(f"wrote {OUT} ({len(names)} icons)")


if __name__ == "__main__":
    emit(parse(SRC.read_text()))
