#!/usr/bin/env python3
"""Content identity shared by local and public builds; excludes signing and Git metadata."""
import hashlib
from pathlib import Path


def input_paths(root):
    files = [root / 'Package.swift']
    files += sorted((root / 'Sources').rglob('*.swift'))
    files += [root / 'assets/branding/mipad2mac-app-icon-v8.png']
    files += sorted((root / 'assets/sponsor').glob('*'))
    return sorted(files)


def source_revision(root):
    digest = hashlib.sha256()
    for path in input_paths(root):
        name = path.relative_to(root).as_posix().encode()
        data = path.read_bytes()
        digest.update(len(name).to_bytes(8, 'big') + name)
        digest.update(len(data).to_bytes(8, 'big') + data)
    return digest.hexdigest()[:12]


if __name__ == '__main__':
    print(source_revision(Path(__file__).resolve().parent.parent))
