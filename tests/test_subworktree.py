"""Real Git/Worktrunk tests for overseer-subworktree; all repositories and config are temporary."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_worktree_operation import WINDOWS, find_worktrunk


SCRIPT = Path(__file__).resolve().parents[1] / "omp" / "skills" / "overseer-subworktree" / "overseer-subworktree"
WT = find_worktrunk()
# Windows runs the script with Git for Windows' Bash (Git\cmd\git.exe -> Git\bin\bash.exe), as omp does.
GIT = shutil.which("git")
SCRIPT_ARGV = [Path(GIT).resolve().parents[1] / "bin" / "bash.exe", SCRIPT] if WINDOWS and GIT else [SCRIPT]


@unittest.skipUnless(WT, "Worktrunk must be installed")
class SubworktreeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="overseer-subworktree-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo space é's"
        self.repo.mkdir()
        home = self.root / "home"
        config = home / ".config" / "worktrunk"
        config.mkdir(parents=True)
        self.env = {
            **{key: value for key, value in os.environ.items() if not key.startswith(("GIT_", "WORKTRUNK_"))},
            "HOME": str(home),
            # The script finds Worktrunk on PATH, as git-wt on Windows.
            "PATH": os.pathsep.join((str(Path(WT).parent), os.environ.get("PATH", ""))),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "WORKTRUNK_CONFIG_PATH": str(config / "config.toml"),
            "WORKTRUNK_SYSTEM_CONFIG_PATH": str(config / "system.toml"),
            "WORKTRUNK_PROJECT_CONFIG_PATH": ".config/wt.toml",
            "WORKTRUNK_WORKTREE_PATH": str(self.root / "created-{{ branch | sanitize }}"),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Overseer test",
            "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Overseer test",
            "GIT_COMMITTER_EMAIL": "test@example.invalid",
        }
        self.git("init", "-b", "master")
        (self.repo / "src").mkdir()
        (self.repo / "src" / "app.txt").write_text("base\n")
        self.git("add", ".")
        self.git("commit", "-m", "base")
        self.parent = self.root / "parent é's"
        self.git("worktree", "add", "-b", "feature/lurker", str(self.parent))

    def run_command(self, *args, cwd, check=True, stdin=""):
        result = subprocess.run(
            [str(arg) for arg in args], cwd=cwd, env=self.env,
            input=stdin, capture_output=True, text=True, timeout=60,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def script(self, *args, **options):
        return self.run_command(*SCRIPT_ARGV, *args, **options)

    def git(self, *args, cwd=None):
        return self.run_command("git", *args, cwd=cwd or self.repo).stdout.strip()

    def parent_of(self, branch):
        result = self.run_command(WT, "config", "state", "vars", "get", "--branch=" + branch, "overseer-parent",
                                  cwd=self.repo, check=False)
        return result.stdout.strip() if result.returncode == 0 else ""

    def branches(self):
        return self.git("branch", "--format=%(refname:short)").splitlines()

    def test_records_the_worktree_it_runs_in_as_parent_even_from_a_subdirectory(self):
        result = self.script("fix/caps", cwd=self.parent / "src")
        self.assertEqual(self.parent_of("fix/caps"), "feature/lurker")
        created = Path(result.stdout.strip().splitlines()[-1])
        self.assertTrue(created.is_dir(), result.stdout)
        self.assertEqual(self.git("symbolic-ref", "--short", "HEAD", cwd=created), "fix/caps")
        # The default base is the default branch, not the parent's tip.
        self.assertEqual(self.git("rev-parse", "fix/caps"), self.git("rev-parse", "master"))

    def test_base_option_branches_from_the_given_ref(self):
        (self.parent / "src" / "app.txt").write_text("parent work\n")
        self.git("commit", "-am", "parent work", cwd=self.parent)
        self.script("fix/stacked", "--base", "feature/lurker", cwd=self.parent)
        self.assertEqual(self.git("rev-parse", "fix/stacked"), self.git("rev-parse", "feature/lurker"))
        self.assertEqual(self.parent_of("fix/stacked"), "feature/lurker")

    def test_brief_from_stdin_lands_in_the_private_git_dir_not_the_worktree(self):
        brief = "Fix the cache TTL.\nReport back with overseer_family when the PR is open.\n"
        result = self.script("fix/brief", "--brief", "-", cwd=self.parent, stdin=brief)
        created = Path(result.stdout.strip().splitlines()[-1])
        git_dir = Path(self.git("rev-parse", "--absolute-git-dir", cwd=created))
        self.assertEqual((git_dir / "overseer-brief.md").read_text(), brief)
        self.assertEqual(self.git("status", "--porcelain", cwd=created), "")
        # The parent's private dir stays untouched.
        parent_dir = Path(self.git("rev-parse", "--absolute-git-dir", cwd=self.parent))
        self.assertFalse((parent_dir / "overseer-brief.md").exists())

    def test_empty_or_missing_brief_creates_nothing(self):
        for args, stdin in ((["--brief", "-"], " \n\t\n"), (["--brief", str(self.root / "missing.md")], "")):
            result = self.script("fix/no-brief", *args, cwd=self.parent, check=False, stdin=stdin)
            self.assertNotEqual(result.returncode, 0, args)
            self.assertNotIn("fix/no-brief", self.branches(), args)

    def test_refuses_the_primary_checkout_without_creating_anything(self):
        for cwd in (self.repo, self.repo / "src"):
            result = self.script("fix/under-main", cwd=cwd, check=False)
            self.assertNotEqual(result.returncode, 0, cwd)
            self.assertIn("primary checkout", result.stderr)
            self.assertIn("wt switch --create", result.stderr)
            self.assertNotIn("fix/under-main", self.branches(), cwd)
            self.assertEqual(self.parent_of("fix/under-main"), "")

    def test_refuses_a_detached_parent_without_creating_anything(self):
        self.git("checkout", "--detach", cwd=self.parent)
        result = self.script("fix/orphan", cwd=self.parent, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("detached", result.stderr)
        self.assertNotIn("fix/orphan", self.branches())

    def test_refuses_option_like_branch_names(self):
        result = self.script("--yes", cwd=self.parent, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.branches(), ["feature/lurker", "master"])

    def test_refuses_outside_a_repository(self):
        outside = self.root / "outside"
        outside.mkdir()
        result = self.script("fix/nowhere", cwd=outside, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("fix/nowhere", self.branches())


if __name__ == "__main__":
    unittest.main()
