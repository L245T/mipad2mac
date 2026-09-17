#!/usr/bin/env python3
"""Export an explicit public-source allowlist, without local history or private files."""
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parent.parent
FILES = [
    '.gitignore', 'Package.swift', 'LICENSE', 'README.md', 'CHANGELOG.md',
    'docs/DEVICE.md', 'docs/PUBLISHING.md', 'docs/UI.md', 'assets/branding/README.md',
    'assets/branding/mipad2mac-logo-v8.svg',
    'assets/branding/mipad2mac-app-icon-v8.svg',
    'assets/branding/mipad2mac-app-icon-v8.png',
    'assets/sponsor/wechat.png', 'assets/sponsor/alipay.jpg',
    'scripts/build-app.sh', 'scripts/build-icon.sh', 'scripts/build-dmg.sh',
    'scripts/test.sh', 'scripts/export-source.py', 'scripts/source-revision.py',
]
for folder, suffix in [('Sources', '.swift'), ('Tests', '.swift'), ('Fixtures', '.hex')]:
    FILES.extend(str(p.relative_to(ROOT)) for p in sorted((ROOT / folder).rglob('*' + suffix)))

def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python3 scripts/export-source.py NEW_OUTPUT_DIRECTORY')
    destination = Path(sys.argv[1]).resolve()
    if destination.exists():
        raise SystemExit('Output must not already exist; refusing to overwrite.')
    for name in FILES:
        source = ROOT / name
        if source.is_symlink() or not source.is_file():
            raise SystemExit('Missing or symlink source: ' + name)
    destination.mkdir(parents=True)
    for name in FILES:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, target)
    print(f'Exported {len(FILES)} files to {destination}. Review before publishing.')

if __name__ == '__main__':
    main()
