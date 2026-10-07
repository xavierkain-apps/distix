#!/usr/bin/env python3
"""Extrait les chaînes L("…") sans interpolation de l'app vers fr.lproj/Localizable.strings.

Les chaînes avec interpolation (\\(…)) restent externalisées par String(localized:)
et seront extraites par Xcode (catalogue de chaînes) au moment de traduire.
"""
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent / "app" / "Sources" / "DistiX"
keys = set()
for f in root.glob("*.swift"):
    for m in re.finditer(r'L\("((?:[^"\\]|\\.)*)"\)', f.read_text()):
        if "\\(" not in m.group(1):
            keys.add(m.group(1))
out = root / "Resources" / "fr.lproj" / "Localizable.strings"
out.parent.mkdir(parents=True, exist_ok=True)
lines = ["/* Généré par scripts/extract-strings.py : ne pas modifier à la main. */", ""]
lines += [f'"{k}" = "{k}";' for k in sorted(keys)]
out.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"{len(keys)} chaînes -> {out}")
