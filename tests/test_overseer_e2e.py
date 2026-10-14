"""Interactive native Tern E2E tests. No user repositories or sessions are used."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

from test_worktree_operation import find_worktrunk


PLUGIN = Path(__file__).resolve().parents[1]
WINDOWS = os.name == "nt"
SUPPORTED = WINDOWS or sys.platform == "darwin"
ROLE = '[data-role="overseer.{}"]'
FAILURE_MARKER = "OVERSEER_E2E_EXPECTED_FAILURE"


def find_tern():
    override = os.environ.get("OVERSEER_E2E_TERN")
    if override:
        return str(Path(override).expanduser().resolve())
    executable = shutil.which("tern")
    if executable:
        path = Path(executable).resolve()
        # The Windows .com CLI shim is not the long-lived GUI process.
        if WINDOWS and path.with_suffix(".exe").is_file():
            path = path.with_suffix(".exe")
        return str(path)
    candidate = (
        Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "Tern" / "tern.exe"
        if WINDOWS else Path("/Applications/Tern.app/Contents/MacOS/tern")
    )
    return str(candidate) if candidate.is_file() else None


@unittest.skipUnless(SUPPORTED, "Native E2E supports Windows and macOS")
class OverseerE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tern = find_tern()
        cls.wt = find_worktrunk()
        missing = []
        if not cls.tern or not Path(cls.tern).is_file():
            missing.append("Tern (or OVERSEER_E2E_TERN pointing to its executable)")
        if not cls.wt:
            missing.append("Worktrunk (git-wt.exe on Windows, wt on macOS)")
        if not shutil.which("git"):
            missing.append("Git")
        cls.driver_shell = shutil.which("powershell.exe") if WINDOWS else "/usr/bin/osascript"
        if not cls.driver_shell or not Path(cls.driver_shell).is_file():
            missing.append("Windows PowerShell" if WINDOWS else "osascript")
        if missing:
            raise RuntimeError("E2E prerequisites missing: " + "; ".join(missing))
        console = Path(cls.tern).with_suffix(".com")
        cls.cli = str(console) if WINDOWS and console.is_file() else cls.tern

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="oe2e-")
        self.root = Path(self.temp.name).resolve()
        self.processes = []
        self.app = None
        self.command_history = []
        self.output = None
        self.addCleanup(self.cleanup_app)
        self.home = self.root / "home"
        self.config = self.root / "config"
        self.repo = self.root / "repo space é's $literal"
        self.logs = self.root / "logs"
        for directory in (self.home / "code", self.config, self.repo, self.logs):
            directory.mkdir(parents=True)
        wt_config = self.home / ".config" / "worktrunk"
        wt_config.mkdir(parents=True)
        self.daemon_socket = (
            "\\\\.\\pipe\\overseer-e2e-" + uuid.uuid4().hex
            if WINDOWS else str(self.root / "daemon.sock")
        )
        self.env = {
            **{key: value for key, value in os.environ.items()
               if not key.startswith(("GIT_", "WORKTRUNK_", "TERN_", "STENCIL_", "XDG_"))
               and key not in ("GH_TOKEN", "GITHUB_TOKEN", "LINEAR_API_KEY")},
            "HOME": str(self.home),
            "USERPROFILE": str(self.home),
            "APPDATA": str(self.home / "AppData" / "Roaming"),
            "LOCALAPPDATA": str(self.home / "AppData" / "Local"),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_CACHE_HOME": str(self.home / ".cache"),
            "XDG_DATA_HOME": str(self.home / ".local" / "share"),
            "TERN_CONFIG_DIR": str(self.config),
            "TERN_DAEMON_SOCKET": self.daemon_socket,
            "STENCIL_LOG_DIR": str(self.logs),
            "WORKTRUNK_CONFIG_PATH": str(wt_config / "config.toml"),
            "WORKTRUNK_SYSTEM_CONFIG_PATH": str(wt_config / "system.toml"),
            "WORKTRUNK_PROJECT_CONFIG_PATH": ".config/wt.toml",
            "WORKTRUNK_WORKTREE_PATH": self.root.as_posix() + "/created-{{ branch | sanitize }}",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Overseer E2E",
            "GIT_AUTHOR_EMAIL": "e2e@example.invalid",
            "GIT_COMMITTER_NAME": "Overseer E2E",
            "GIT_COMMITTER_EMAIL": "e2e@example.invalid",
        }
        # Use discovered real binaries even after replacing HOME and APPDATA.
        self.env["PATH"] = os.pathsep.join((str(Path(self.wt).parent), str(Path(self.tern).parent), self.env.get("PATH", "")))
        for key in ("APPDATA", "LOCALAPPDATA", "XDG_CACHE_HOME", "XDG_DATA_HOME"):
            Path(self.env[key]).mkdir(parents=True, exist_ok=True)
        self.kv_file = self.config / "plugin-data" / "overseer" / "kv.json"
        self.kv_file.parent.mkdir(parents=True)
        # Only initial panel visibility is configured. Projects enter through the picker.
        self.kv_file.write_text(json.dumps({"panel-open": True}), encoding="utf-8")
        try:
            self.git("init", "-b", "main")
            (self.repo / "tracked.txt").write_text("selected base\n", encoding="utf-8")
            self.git("add", ".")
            self.git("commit", "-m", "selected base")
            self.base_commit = self.git("rev-parse", "HEAD")
            self.run_command(self.cli, "plugin", "link", str(PLUGIN))
            self.output = (self.root / "process-output.log").open("wb")
            self.start_process([self.tern, "daemon", "--socket", self.daemon_socket])
            self.wait_for("isolated daemon endpoint", self.daemon_ready, timeout=30)
            self.start_window()
        except Exception:
            self.capture_failure()
            raise

    def run_command(self, *args, check=True, timeout=30, cwd=None):
        result = subprocess.run(
            [str(arg) for arg in args], cwd=cwd or self.root, env=self.env,
            stdin=subprocess.DEVNULL, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=timeout,
        )
        self.command_history.append({"argv": [str(arg) for arg in args], "status": result.returncode,
                                     "stdout": result.stdout, "stderr": result.stderr})
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def git(self, *args, cwd=None):
        return self.run_command("git", "-C", cwd or self.repo, *args).stdout.strip()

    def start_process(self, args):
        process = subprocess.Popen(
            args, cwd=self.root, env=self.env, stdin=subprocess.DEVNULL,
            stdout=self.output, stderr=subprocess.STDOUT, start_new_session=not WINDOWS,
        )
        self.processes.append(process)
        return process

    def daemon_ready(self):
        if self.processes[0].poll() is not None:
            raise AssertionError("Isolated Tern daemon exited before becoming ready")
        if WINDOWS:
            import ctypes
            return bool(ctypes.windll.kernel32.WaitNamedPipeW(self.daemon_socket, 1))
        return Path(self.daemon_socket).exists()

    def start_window(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            self.control = str(reservation.getsockname()[1])
        self.app = self.start_process([self.tern, "--control", self.control, "--dir", str(self.home)])

        def connected():
            if self.app.poll() is not None:
                raise AssertionError("Native Tern window exited before its control endpoint opened")
            with socket.socket() as probe:
                probe.settimeout(0.2)
                return probe.connect_ex(("127.0.0.1", int(self.control))) == 0

        self.wait_for("native Tern control endpoint", connected, timeout=45)
        # Decline this isolated window's first-run tool-management questions.
        # They can hold the first frame; stats/ready are not readiness probes.
        self.dismiss_startup_questions()
        # Offline account fixture, scoped to this test window; no real OAuth login.
        self.ctl("account signed-in", "overseer-e2e")
        def panel_ready():
            self.dismiss_startup_questions()
            return self.nodes("navigator")
        self.wait_for("Projects panel", panel_ready)

    def dismiss_startup_questions(self):
        for dialog in self.ctl_json("system").get("dialogs", []):
            if dialog.get("kind") == "message" and dialog.get("type") == "question" and dialog.get("cancel") is not None:
                self.ctl("dialog", dialog["id"], "button", dialog["cancel"])

    def ctl(self, command, *args, check=True, timeout=15):
        def token(value):
            text = str(value)
            # Scenario keywords and numbers are bare tokens; only literal text
            # needing protection uses the protocol's quoted-string syntax.
            return text if re.fullmatch(r"[A-Za-z0-9_./:+-]+", text) else json.dumps(text, ensure_ascii=False)
        # Control tree/dump accept raw CSS, unlike scenario quoted-string arguments.
        line = " ".join((command, *(str(arg) for arg in args))) if command in ("tree", "dump") else " ".join((command, *(token(arg) for arg in args)))
        result = self.run_command(self.cli, "ctl", "--control", self.control, line, check=False, timeout=timeout)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def ctl_json(self, command, *args):
        return json.loads(self.ctl(command, *args).stdout)

    def nodes(self, role):
        return self.ctl_json("tree", ROLE.format(role)).get("nodes", [])

    def state(self):
        return self.ctl_json("state")

    def kv(self):
        try:
            return json.loads(self.kv_file.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def wait_for(self, description, predicate, timeout=45):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.1)  # Bounded condition wait, never a fixed settling delay.
        self.fail("Timed out waiting for " + description)

    def click(self, node, right=False):
        x, y, width, height = node["rect"]
        args = [x + width / 2, y + height / 2]
        if right:
            args.append("right")
        self.ctl("click", *args)

    def button(self, title):
        return self.wait_for(
            "button " + title,
            lambda: next((node for node in self.ctl_json("tree", "button").get("nodes", [])
                          if node.get("title") == title), None),
        )

    def native_picker(self, action, folder=""):
        if WINDOWS:
            args = [self.driver_shell, "-NoLogo", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass",
                    "-File", str(PLUGIN / "tests" / "e2e_picker_windows.ps1"),
                    "-OwnerPid", str(self.app.pid), "-Action", action, "-TimeoutSeconds", "20"]
            if folder:
                args.extend(("-Folder", str(folder)))
        else:
            args = [self.driver_shell, str(PLUGIN / "tests" / "e2e_picker_macos.applescript"),
                    str(self.app.pid), action, str(folder), "20"]
        self.run_command(*args, timeout=30)

    def add_project(self):
        self.click(self.button("Add an existing Git repository"))
        self.native_picker("select", self.repo)
        self.wait_for("selected repository's primary checkout", lambda: self.row("main"))
        projects = self.kv().get("projects", [])
        self.assertEqual([Path(project["path"]).resolve() for project in projects], [self.repo])
        self.assertEqual(projects[0]["base"], "main")

    def row(self, branch):
        return next((node for node in self.nodes("worktreeRow")
                     if node.get("title", "").split("\n", 1)[0] == branch), None)

    def create(self, branch, display_name):
        self.click(self.button("New worktree from main"))
        self.wait_for("creation form", lambda: self.nodes("field"))
        fields = self.nodes("field")
        self.click(fields[0])
        self.ctl("type", branch)
        self.ctl("key", "Tab")
        self.ctl("type", display_name)
        self.click(self.wait_for("creation submit", lambda: next(iter(self.nodes("primaryButton")), None)))

    def jobs_for(self, branch):
        return {key: value for key, value in self.kv().get("jobs", {}).items() if value.get("branch") == branch}

    def completed_creation(self, branch, display_name):
        def completed():
            row = self.row(branch)
            return row if row and display_name in row.get("text", "") and not self.jobs_for(branch) else None
        row = self.wait_for("created worktree and completed setup", completed)
        path = Path(row["title"].split("\n")[1]).resolve()
        self.assertTrue(path.is_dir())
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=path), self.base_commit)
        self.assertEqual(self.git("branch", "--show-current", cwd=path), branch)
        self.assertEqual((path / "tracked.txt").read_text(encoding="utf-8"), "selected base\n")
        return path

    def lua(self, code):
        self.ctl("carly lua", code)
        last = self.state().get("carly", {}).get("last_tool", {})
        self.assertFalse(last.get("error"), last)
        self.ctl("carly close")
        return last.get("result")

    def open_created(self, branch, path):
        self.click(self.wait_for("created row", lambda: self.row(branch)))
        self.wait_for("new checkout's session directory", lambda: self.focused_at(path))
        # Check the real shell, not just the directory configured on its pane.
        self.ctl("run", "git branch --show-current")
        self.ctl("expect", branch, timeout=30)

    def focused_at(self, path):
        state = self.state()
        cwd = state.get("focused", {}).get("cwd", "")
        return state if cwd and Path(cwd).resolve() == path else None

    def choose_row_menu(self, branch, action):
        self.click(self.wait_for("worktree row", lambda: self.row(branch)), right=True)

        def menu_item():
            candidates = [node for node in self.ctl_json("tree", "*").get("nodes", [])
                          if node.get("text") == action and node.get("rect", [0, 0, 0, 0])[2] > 0]
            return min(candidates, key=lambda node: node["rect"][2] * node["rect"][3]) if candidates else None

        self.click(self.wait_for("row menu action " + action, menu_item))

    def request_delete(self, branch):
        self.choose_row_menu(branch, "Delete worktree")
        self.click(self.wait_for("delete confirmation", lambda: next(iter(self.nodes("dangerButton")), None)))

    def test_add_cancel_and_persist_after_restart(self):
        self.click(self.button("Add an existing Git repository"))
        self.native_picker("cancel")
        self.assertEqual(self.kv().get("projects", []), [])
        self.add_project()
        self.ctl("quit")
        self.stop_process(self.app)
        self.start_window()
        self.wait_for("persisted project's worktree after restart", lambda: self.row("main"))
        self.assertEqual(Path(self.kv()["projects"][0]["path"]).resolve(), self.repo)

    def test_add_create_and_open_worktree_session(self):
        self.add_project()
        branch, display = "feature/é'$literal;create", "E2E Unicode creation"
        self.create(branch, display)
        path = self.completed_creation(branch, display)
        self.open_created(branch, path)
        self.assertFalse(self.nodes("error"))

    def test_failed_creation_keeps_error_output_and_clears_job(self):
        release = self.repo / ".git" / "e2e-release"
        hook = ('while [ ! -e "$(git rev-parse --git-common-dir)/e2e-release" ]; '
                "do sleep 0.05; done; printf '\\n" + FAILURE_MARKER + "\\n'; exit 23")
        (self.repo / ".config").mkdir()
        (self.repo / ".config" / "wt.toml").write_text("pre-start = " + json.dumps(hook) + "\n", encoding="utf-8")
        self.git("add", ".config/wt.toml")
        self.git("commit", "-m", "isolated failing hook")
        self.git("remote", "add", "origin", "https://overseer-e2e.invalid/fixture.git")
        # Explicitly trust this one generated fixture command in the isolated home.
        # The plugin's Worktrunk invocation still retains its approval checks.
        self.run_command(self.wt, "-C", self.repo, "config", "approvals", "add", "--yes")
        self.addCleanup(lambda: release.touch(exist_ok=True))
        self.add_project()
        branch = "feature/failed-creation"
        self.create(branch, "Expected failed setup")
        jobs = self.wait_for("running creation job", lambda: self.jobs_for(branch))
        pane = next(iter(jobs.values()))["pane"]
        release.touch()
        self.wait_for("failed job completion", lambda: not self.jobs_for(branch))
        self.lua("cx.layout:focus(" + str(pane) + "); return true")
        self.ctl("expect", FAILURE_MARKER, timeout=30)

    def test_safe_removal_updates_ui_and_preserves_branch(self):
        self.add_project()
        branch, display = "feature/remove-me", "Disposable checkout"
        self.create(branch, display)
        path = self.completed_creation(branch, display)
        self.request_delete(branch)
        self.wait_for("worktree directory removed", lambda: not path.exists())
        self.wait_for("removed checkout absent from Projects", lambda: self.row(branch) is None)
        self.assertEqual(self.git("rev-parse", "refs/heads/" + branch), self.base_commit)
        self.assertTrue(self.repo.is_dir())
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_dirty_worktree_refusal_preserves_files(self):
        self.add_project()
        branch, display = "feature/keep-dirty", "Protected edits"
        self.create(branch, display)
        path = self.completed_creation(branch, display)
        (path / "tracked.txt").write_text("uncommitted user changes\n", encoding="utf-8")
        self.request_delete(branch)
        # Rejection clears the confirmation and leaves data intact; its toast is transient.
        self.wait_for("unsafe deletion request resolved", lambda: not self.nodes("confirmation"))
        self.assertEqual((path / "tracked.txt").read_text(encoding="utf-8"), "uncommitted user changes\n")
        self.assertEqual(self.git("rev-parse", "refs/heads/" + branch), self.base_commit)
        self.assertIsNotNone(self.row(branch))
        self.assertFalse(self.kv().get("jobs", {}))

    def test_automatic_refresh_discovers_external_worktree(self):
        self.add_project()
        branch = "feature/external-refresh"
        path = self.root / "externally created é's $literal"
        self.git("worktree", "add", "-b", branch, str(path), "main")
        # No refresh button, plugin reload, navigation or other mutation follows.
        row = self.wait_for("automatic worktree refresh", lambda: self.row(branch), timeout=45)
        self.assertEqual(Path(row["title"].split("\n")[1]).resolve(), path)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=path), self.base_commit)

    def tearDown(self):
        result = self._outcome.result
        if any(test is self for test, _traceback in (*result.failures, *result.errors)):
            self.capture_failure()

    def capture_failure(self):
        default_artifacts = Path(tempfile.gettempdir()) / "overseer-e2e-artifacts"
        destination_root = Path(os.environ.get("OVERSEER_E2E_ARTIFACTS", str(default_artifacts)))
        destination = destination_root / (self._testMethodName + "-" + uuid.uuid4().hex[:8])
        destination.mkdir(parents=True)
        for command in ("state", "tree", "menus", "system"):
            if self.app is None or self.app.poll() is not None:
                break
            try:
                result = self.ctl(command, check=False, timeout=5)
                (destination / (command + ".json")).write_text(result.stdout or result.stderr, encoding="utf-8")
            except (OSError, subprocess.TimeoutExpired):
                pass
        if self.app is not None and self.app.poll() is None:
            try:
                self.run_command(self.cli, "ctl", "--control", self.control, "shot failure", check=False, timeout=10, cwd=destination)
            except (OSError, subprocess.TimeoutExpired):
                pass
        shots = self.root / "target" / "shots"
        if shots.is_dir():
            shutil.copytree(shots, destination / "screenshots", dirs_exist_ok=True)
        (destination / "commands.json").write_text(json.dumps(self.command_history, indent=2, ensure_ascii=False), encoding="utf-8")
        for file in (self.kv_file, self.root / "process-output.log"):
            if file.is_file():
                shutil.copy2(file, destination / file.name)
        if self.logs.is_dir():
            shutil.copytree(self.logs, destination / "logs", dirs_exist_ok=True)
        print("\nE2E failure diagnostics: " + str(destination), file=sys.stderr)

    def stop_process(self, process):
        if process.poll() is not None:
            return
        if WINDOWS:
            # Only the isolated root PID and its descendants; never taskkill /IM tern.exe.
            self.run_command("taskkill.exe", "/PID", process.pid, "/T", "/F", check=False, timeout=10)
        else:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                return
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            if not WINDOWS:
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            process.wait(timeout=5)

    def cleanup_app(self):
        if self.app is not None and self.app.poll() is None:
            try:
                self.ctl("quit", check=False, timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                pass
        for process in reversed(self.processes):
            self.stop_process(process)
        if self.output:
            self.output.close()
        self.temp.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=2)
