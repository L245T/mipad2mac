#!/usr/bin/env python3
"""Associate packaged inputs with a verified public Git commit, without changing source."""
import os
from pathlib import Path
import runpy
import subprocess
import sys

input_paths = runpy.run_path(str(Path(__file__).with_name('source-revision.py')))['input_paths']
PUBLIC_ORIGINS = {
    'git@github.com:L245T/mipad2mac.git',
    'https://github.com/L245T/mipad2mac.git',
    'https://github.com/L245T/mipad2mac',
    'ssh://git@github.com/L245T/mipad2mac.git',
}


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.PIPE)


def verify_revision(root, reference):
    if git(reference, 'remote', 'get-url', 'origin').decode().strip() not in PUBLIC_ORIGINS:
        raise ValueError('参考仓库不是项目公开仓库')
    if git(reference, 'status', '--porcelain', '--untracked-files=normal').strip():
        raise ValueError('参考仓库存在未提交文件')
    commit = git(reference, 'rev-parse', 'HEAD').decode().strip()
    tree = git(reference, 'ls-tree', '-r', '--name-only', '-z', commit).decode().split('\0')
    expected = {name for name in tree if name == 'Package.swift'
                or (name.startswith('Sources/') and name.endswith('.swift'))
                or name == 'assets/branding/mipad2mac-app-icon-v8.png'
                or (name.startswith('assets/sponsor/') and name.count('/') == 2)}
    paths = input_paths(root)
    actual = {p.relative_to(root).as_posix() for p in paths}
    if expected != actual:
        raise ValueError('打包输入文件清单与公开提交不一致')
    for path in paths:
        name = path.relative_to(root).as_posix()
        if path.is_symlink() or path.read_bytes() != git(reference, 'show', f'{commit}:{name}'):
            raise ValueError(f'打包输入与公开提交不一致：{name}')
    return commit


def main():
    root = Path(__file__).resolve().parent.parent
    reference = Path(os.environ.get('MIPAD_REVISION_REPO', str(root))).resolve()
    try:
        print(verify_revision(root, reference))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        # Do not print Git stderr: it can contain local paths or remote configuration.
        reason = str(error) if isinstance(error, ValueError) else '无法读取公开参考仓库'
        print(f'提交编号未关联：{reason}。本次为本地测试构建。', file=sys.stderr)
        if os.environ.get('MIPAD_REQUIRE_GIT_REVISION') == '1':
            return 1
        print('')
    return 0


if __name__ == '__main__':
    sys.exit(main())
