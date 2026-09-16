#!/usr/bin/env python3
"""Content identity shared by local and public builds; excludes signing and Git metadata."""
import hashlib
from pathlib import Path
root = Path(__file__).resolve().parent.parent
files = [root / 'Package.swift']
files += sorted((root / 'Sources').rglob('*.swift'))
files += [root / 'assets/branding/mipad2mac-app-icon-v8.png']
files += sorted((root / 'assets/sponsor').glob('*'))
digest = hashlib.sha256()
for path in sorted(files):
    name = path.relative_to(root).as_posix().encode()
    data = path.read_bytes()
    digest.update(len(name).to_bytes(8, 'big') + name)
    digest.update(len(data).to_bytes(8, 'big') + data)
print(digest.hexdigest()[:12])
