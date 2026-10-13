#!/usr/bin/env python3
"""Fix wakelock_plus Android Pigeon codegen: missing package + bare imports.
Safe to run repeatedly. Targets the version resolved in pub-cache.
"""
from __future__ import annotations
import re
from pathlib import Path
import glob

def patch_version(root: Path) -> None:
    base = root / 'android/src/main/kotlin/dev/fluttercommunity/plus/wakelock'
    if not base.exists():
        return
    gen = base / 'WakelockPlusMessages.g.kt'
    if gen.exists():
        t = gen.read_text()
        lines = []
        seen = False
        for l in t.splitlines(True):
            if l.startswith('package '):
                if seen:
                    continue
                seen = True
                lines.append('package dev.fluttercommunity.plus.wakelock\n')
                continue
            lines.append(l)
        if not seen:
            lines.insert(0, 'package dev.fluttercommunity.plus.wakelock\n\n')
        gen.write_text(''.join(lines))
    for name in ('Wakelock.kt', 'WakelockPlusPlugin.kt'):
        p = base / name
        if not p.exists():
            continue
        t = p.read_text()
        t = t.replace('import IsEnabledMessage\n', '')
        t = t.replace('import ToggleMessage\n', '')
        t = t.replace('import WakelockPlusApi\n', '')
        p.write_text(t)
    print(f'patched {root.name}')

def main() -> None:
    roots = sorted(Path.home().glob('.pub-cache/hosted/pub.dev/wakelock_plus-*'))
    if not roots:
        print('no wakelock_plus in pub-cache')
        return
    for r in roots:
        patch_version(r)

if __name__ == '__main__':
    main()
