"""update_runtime.py check_source_commit (user 2026-10-31): an app built from a commit this checkout does not contain is
refused, so updating it cannot take away the fixes of the branch it was built from."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import update_runtime  # noqa: E402
from build_app import BuildError  # noqa: E402


class SourceCommit(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        self.repo = self.dir / 'repo'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.base = self.commit('base')
        self.git('checkout', '-q', '-b', 'side')
        self.side = self.commit('side fix')
        self.git('checkout', '-q', 'main')
        self.later = self.commit('main later')
        self.app = self.dir / 'Game.app'
        (self.app / 'Contents').mkdir(parents=True)

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=t', '-c', 'user.email=t@t', *args],
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, message):
        self.git('commit', '-q', '--allow-empty', '-m', message)
        return self.git('rev-parse', '--short=7', 'HEAD')

    def built_from(self, commit):
        info = {'CFBundleExecutable': 'TOTK'}
        if commit:
            info['MNGSourceCommit'] = commit
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))

    def test_an_older_commit_of_this_branch_is_fine(self):
        self.built_from(self.base)
        update_runtime.check_source_commit(self.app, self.repo)

    def test_a_commit_of_another_branch_is_refused(self):
        self.built_from(self.side)
        with self.assertRaises(BuildError) as e:
            update_runtime.check_source_commit(self.app, self.repo)
        self.assertIn('side', str(e.exception))
        update_runtime.check_source_commit(self.app, self.repo, other_commit=True)

    def test_a_commit_this_checkout_does_not_have_is_refused(self):
        self.built_from('0123abc')
        with self.assertRaises(BuildError):
            update_runtime.check_source_commit(self.app, self.repo)

    def test_an_app_without_a_commit_is_not_checked(self):
        self.built_from(None)
        update_runtime.check_source_commit(self.app, self.repo)


if __name__ == '__main__':
    unittest.main()
