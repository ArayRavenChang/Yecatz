"""Exercise the embedded macOS transaction script using temporary fake app bundles.

Run with Python 3 and bash (macOS or Git for Windows). This checks shell transaction
behavior, while native AppKit/code-signing verification still requires macOS.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
if not BASH and os.name == "nt":
    BASH = str(Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe")


class MacUpdateHelperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="yecatz mac 更新 [test] & ")
        self.base = Path(self.temp.name)
        self.target = self.base / "Yecatz [正式版].app"
        self.stage = self.base / ".Yecatz-update-test"
        self.lock = self.base / ".update-lock"
        self.lock.mkdir()
        self.target.mkdir()
        (self.target / "old.txt").write_text("old")
        self.replacement = self.stage / "unpacked/Yecatz.app"
        self.executable = self.replacement / "Contents/MacOS/Yecatz"
        self.executable.parent.mkdir(parents=True)
        (self.replacement / "new.txt").write_text("new")
        source = (ROOT / "Updates.swift").read_text(encoding="utf-8-sig")
        helper = re.search(r'private static let helper = #"""\n(.*?)\n    """#', source, re.S)
        self.assertIsNotNone(helper)
        script = textwrap.dedent(helper.group(1)) + "\n"
        # Replace the macOS GUI launcher only, so rollback cannot open an application.
        script = script.replace('/usr/bin/open -n "$target" --args --yecatz-update-error "$stage"',
                                'printf "%s\\n" "$target" > "$stage/reopened"')
        self.script = self.base / "install.sh"
        self.script.write_text(script, encoding="utf-8", newline="\n")

    def tearDown(self):
        self.temp.cleanup()

    def run_helper(self, app_script):
        self.executable.write_text("#!/bin/sh\n" + app_script, encoding="utf-8", newline="\n")
        self.executable.chmod(0o755)
        result = subprocess.run(
            [BASH, self.script.as_posix(), self.target.as_posix(), self.stage.as_posix(),
             "99999999", "test-token", self.lock.as_posix()],
            capture_output=True, text=True, timeout=20,
        )
        return result

    def test_success_replaces_and_cleans_old_version(self):
        result = self.run_helper('printf "%s" "$4" > "$2/ready"\nsleep 4\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.target / "new.txt").exists())
        self.assertFalse((self.target / "old.txt").exists())
        self.assertFalse(self.stage.exists())
        self.assertFalse(self.lock.exists())
        time.sleep(1.5)

    def test_launch_failure_restores_original(self):
        result = self.run_helper("exit 1\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.target / "old.txt").exists())
        self.assertTrue((self.stage / "failed.app/new.txt").exists())
        self.assertTrue((self.stage / "failure.txt").exists())
        self.assertTrue((self.stage / "reopened").exists())
        self.assertFalse(self.lock.exists())

    def test_crash_immediately_after_acknowledgment_restores_original(self):
        result = self.run_helper('printf "%s" "$4" > "$2/ready"\nsleep 1\nexit 1\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.target / "old.txt").exists())
        self.assertFalse(self.lock.exists())

    def test_swap_failure_restores_original(self):
        # The replacement disappears after preparation, before the helper runs.
        shutil.rmtree(self.replacement)
        result = subprocess.run(
            [BASH, self.script.as_posix(), self.target.as_posix(), self.stage.as_posix(),
             "99999999", "test-token", self.lock.as_posix()],
            capture_output=True, text=True, timeout=20,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.target / "old.txt").exists())
        self.assertFalse(self.lock.exists())

    def test_initial_rename_failure_reopens_original(self):
        script = self.script.read_text(encoding="utf-8")
        script = script.replace('/bin/mv "$target" "$backup" || exit 1', 'false || exit 1')
        self.script.write_text(script, encoding="utf-8", newline="\n")
        result = self.run_helper("exit 1\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.target / "old.txt").exists())
        self.assertTrue((self.stage / "failure.txt").exists())
        self.assertTrue((self.stage / "reopened").exists())
        self.assertTrue(self.replacement.exists())
        self.assertFalse(self.lock.exists())

    def test_old_process_timeout_preserves_running_original(self):
        script = self.script.read_text(encoding="utf-8")
        script = script.replace("old_pid=$3", "old_pid=$$")
        script = script.replace('[ "$attempts" -ge 60 ]', '[ "$attempts" -ge 2 ]')
        self.script.write_text(script, encoding="utf-8", newline="\n")
        result = self.run_helper("exit 1\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.target / "old.txt").exists())
        self.assertTrue((self.stage / "failure.txt").exists())
        self.assertFalse((self.stage / "reopened").exists())
        self.assertTrue(self.replacement.exists())
        self.assertFalse(self.lock.exists())


if __name__ == "__main__":
    unittest.main()
