import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class SyncUpstreamTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.upstream = self.root / "upstream"
        self.local = self.root / "local"
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith(("GIT_", "SYNC_", "UPSTREAM_")):
                del self.env[key]
        self.env.update(
            GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
            GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.invalid",
            GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.invalid",
            TEST_RESULT="0", BUILD_RESULT="0",
        )
        self.git(self.root, "init", "--initial-branch=main", str(self.upstream))
        (self.upstream / "scripts").mkdir()
        script = Path(os.environ.get("SYNC_SCRIPT_UNDER_TEST",
                      str(Path(__file__).resolve().parents[1] / "scripts/sync-upstream.sh")))
        shutil.copyfile(script, self.upstream / "scripts/sync-upstream.sh")
        for name, variable, marker in [
            ("scripts/run-tests.sh", "TEST_RESULT", "tests-ran"),
            ("build.sh", "BUILD_RESULT", "build-ran"),
        ]:
            path = self.upstream / name
            path.write_text(f'#!/bin/bash\ntouch .git/{marker}\nexit "${{{variable}:-0}}"\n')
            path.chmod(0o755)
        self.git(self.upstream, "add", ".")
        self.git(self.upstream, "commit", "-m", "fixture")
        self.git(self.root, "clone", str(self.upstream), str(self.local))
        (self.local / "custom.txt").write_text("local customization\n")
        self.git(self.local, "add", ".")
        self.git(self.local, "commit", "-m", "customization")
        self.before = self.git(self.local, "rev-parse", "HEAD").stdout.strip()
        (self.upstream / "upstream.txt").write_text("upstream change\n")
        self.git(self.upstream, "add", ".")
        self.git(self.upstream, "commit", "-m", "upstream change")

    def git(self, cwd, *args, check=True):
        return subprocess.run(["git", *args], cwd=cwd, env=self.env,
                              text=True, capture_output=True, check=check)

    def sync(self, *args, **settings):
        return subprocess.run(["/bin/bash", "scripts/sync-upstream.sh", *args],
                              cwd=self.local, env={**self.env, **settings},
                              text=True, capture_output=True)

    def assert_pending(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.local, "rev-parse", "HEAD").stdout.strip(), self.before)
        self.assertEqual(self.git(self.local, "rev-parse", "--verify", "MERGE_HEAD",
                                 check=False).returncode, 0)

    def assert_failed_tests_stop(self, **settings):
        result = self.sync(TEST_RESULT="7", **settings)
        self.assert_pending(result)
        self.assertIn("Validation failed", result.stderr)
        self.assertFalse((self.local / ".git/build-ran").exists())

    def test_failed_tests_never_commit(self):
        self.assert_failed_tests_stop()

    def test_failed_tests_never_start_build(self):
        self.assert_failed_tests_stop(SYNC_BUILD_APP="1")

    def test_failed_tests_with_explicit_sdk(self):
        self.assert_failed_tests_stop(SYNC_SDKROOT="/fixture/sdk")

    def test_failed_tests_with_explicit_sdk_never_start_build(self):
        self.assert_failed_tests_stop(SYNC_SDKROOT="/fixture/sdk", SYNC_BUILD_APP="1")

    def test_failed_build_never_commits(self):
        self.assert_pending(self.sync(SYNC_BUILD_APP="1", BUILD_RESULT="9"))
        self.assertTrue((self.local / ".git/tests-ran").exists())

    def test_continue_rechecks_then_commits(self):
        self.git(self.local, "fetch", "origin")
        self.git(self.local, "merge", "--no-ff", "--no-commit", "origin/main")
        self.assert_pending(self.sync("--continue", TEST_RESULT="7"))
        result = self.sync("--continue")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.git(self.local, "rev-parse", "HEAD").stdout.strip(), self.before)

    def test_successful_tests_and_build_commit(self):
        result = self.sync(SYNC_BUILD_APP="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.local / ".git/build-ran").exists())
        self.assertNotEqual(self.git(self.local, "rev-parse", "HEAD").stdout.strip(), self.before)

    def test_explicit_skip_still_allows_build(self):
        result = self.sync(SYNC_SKIP_TESTS="1", SYNC_BUILD_APP="1", TEST_RESULT="7")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.local / ".git/tests-ran").exists())
        self.assertTrue((self.local / ".git/build-ran").exists())

    def test_up_to_date_failure_is_reported(self):
        self.assertEqual(self.sync().returncode, 0)
        self.assertNotEqual(self.sync(TEST_RESULT="7").returncode, 0)

    def test_failed_validation_can_be_aborted(self):
        self.assert_pending(self.sync(TEST_RESULT="7"))
        self.assertEqual(self.sync("--abort").returncode, 0)
        self.assertEqual(self.git(self.local, "rev-parse", "HEAD").stdout.strip(), self.before)
        self.assertEqual(self.git(self.local, "status", "--porcelain").stdout, "")


if __name__ == "__main__":
    unittest.main()
