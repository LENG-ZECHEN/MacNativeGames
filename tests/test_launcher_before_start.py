"""The single-process launcher grants only its before-start child permission to ignore its PID."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(sys.platform == 'darwin', 'Foundation requires macOS')
class BeforeStart(unittest.TestCase):
    def test_pid_permission_is_child_only_and_cancellation_is_preserved(self):
        text = (ROOT / 'games/totk/app/launcher.m').read_text()
        start = text.index('static int run_before_start(')
        end = text.index('\n/* Save picker:', start)
        function = text[start:end]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); hook = root / 'before-start'; result = root / 'child-pid'
            hook.write_text('#!/bin/sh\nprintf "%s" "$TOTK_BEFORE_START_PID" > "$1/child-pid"\nexit "${TEST_HOOK_STATUS:-0}"\n')
            hook.chmod(0o755)
            source = root / 'probe.m'; exe = root / 'probe'
            source.write_text('#import <Foundation/Foundation.h>\n#include <spawn.h>\n#include <sys/wait.h>\n#include <unistd.h>\n#include <errno.h>\n' + function + '\nint main(int n,char **v){@autoreleasepool{if(n!=3)return 2;int ok=run_before_start(@(v[1]),@(v[1]));printf("%ld",(long)getpid());return getenv("TOTK_BEFORE_START_PID")||ok!=atoi(v[2]);}}\n')
            subprocess.run(['xcrun','clang','-std=c11','-fobjc-arc',str(source),'-framework','Foundation','-o',str(exe)],check=True,capture_output=True,timeout=30)
            env = dict(os.environ)
            env.pop('TOTK_PROFILE_DIR',None); env.pop('TOTK_BEFORE_START_PID',None)
            for status in ('0','1'):
                run = subprocess.run([str(exe),str(root),'1' if status=='0' else '0'],env=dict(env,TEST_HOOK_STATUS=status),capture_output=True,text=True,timeout=10)
                self.assertEqual(run.returncode,0,run.stderr)
                self.assertEqual(result.read_text(),run.stdout)
            result.unlink()
            run = subprocess.run([str(exe),str(root),'1'],env=dict(env,TOTK_PROFILE_DIR=str(root/'test-profile')),capture_output=True,text=True,timeout=10)
            self.assertEqual(run.returncode,0,run.stderr)
            self.assertFalse(result.exists())
