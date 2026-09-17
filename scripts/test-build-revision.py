#!/usr/bin/env python3
"""Regression checks for commit attribution; uses disposable, offline repositories."""
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest

module = runpy.run_path(str(Path(__file__).with_name('build-revision.py')))
verify_revision = module['verify_revision']


class BuildRevisionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'source'
        self.repo = Path(self.temp.name) / 'reference'
        self.root.mkdir()
        self.repo.mkdir()
        self.files = {'Package.swift': '// package', 'Sources/App/main.swift': '// app',
                      'assets/branding/mipad2mac-app-icon-v8.png': 'icon',
                      'assets/sponsor/code.png': 'image'}
        for base in (self.root, self.repo):
            for name, data in self.files.items():
                p = base / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(data)
        self.git('init', '-q')
        self.git('remote', 'add', 'origin', 'https://github.com/L245T/mipad2mac.git')
        self.git('add', '--', *self.files)
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.PIPE)

    def test_matching_inputs_use_public_commit(self):
        self.assertEqual(verify_revision(self.root, self.repo), self.git('rev-parse', 'HEAD').decode().strip())

    def test_modified_input_rejected(self):
        (self.root / 'Sources/App/main.swift').write_text('// changed')
        with self.assertRaises(ValueError): verify_revision(self.root, self.repo)

    def test_added_and_missing_inputs_rejected(self):
        p = self.root / 'Sources/App/extra.swift'
        p.write_text('// extra')
        with self.assertRaises(ValueError): verify_revision(self.root, self.repo)
        p.unlink()
        (self.root / 'Sources/App/main.swift').unlink()
        with self.assertRaises(ValueError): verify_revision(self.root, self.repo)

    def test_dirty_reference_rejected(self):
        (self.repo / 'Package.swift').write_text('// changed')
        with self.assertRaises(ValueError): verify_revision(self.root, self.repo)

    def test_untracked_reference_rejected(self):
        (self.repo / 'untracked.txt').write_text('new')
        with self.assertRaises(ValueError): verify_revision(self.root, self.repo)

    def test_unrelated_origin_rejected(self):
        self.git('remote', 'set-url', 'origin', 'https://example.invalid/other.git')
        with self.assertRaises(ValueError): verify_revision(self.root, self.repo)

    def test_symlink_rejected(self):
        p = self.root / 'Package.swift'
        p.unlink()
        p.symlink_to(self.repo / 'Package.swift')
        with self.assertRaises(ValueError): verify_revision(self.root, self.repo)

    def test_build_script_difference_does_not_change_input_identity(self):
        # Local packaging differs intentionally; attribution is scoped to app inputs.
        (self.root / 'scripts').mkdir()
        (self.root / 'scripts/build-app.sh').write_text('# local packaging')
        self.assertTrue(verify_revision(self.root, self.repo))


if __name__ == '__main__':
    unittest.main()
