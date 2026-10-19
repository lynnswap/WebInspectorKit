import json
import os
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


WATCHDOG = Path(__file__).resolve().parents[3] / "Scripts/ci-xcodebuild-watchdog.sh"


class StartupDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.diagnostics = self.directory / "startup"
        self.control_read, self.control_write = os.pipe()
        self.events_read, self.events_write = os.pipe()
        for fd in (self.control_read, self.control_write, self.events_read, self.events_write):
            self.addCleanup(os.close, fd)
        self.executable("mktemp", "import os\nprint(os.environ['TEST_RAW_LOG'])\n")
        self.executable("stat", "import os, sys\nprint(os.stat(sys.argv[-1]).st_size)\n")
        self.executable("sudo", "raise SystemExit(1)\n")
        self.executable("ps", "print('123 1 00:01 S 0.0 CoreSimulator testmanagerd installd')\n")
        self.executable("sample", """import json, os, signal, sys
os.write(int(os.environ['TEST_EVENTS_FD']), (json.dumps({
    'pid': os.getpid(), 'target': int(sys.argv[1]), 'duration': sys.argv[2],
}) + '\\n').encode())
print('fake xcodebuild stack', flush=True)
if os.environ['TEST_SAMPLE_MODE'] == 'block':
    signal.pause()
raise SystemExit(int(os.environ['TEST_SAMPLE_EXIT']))
""")
        self.command = self.executable("test-command", """import os
print('Command line invocation:', flush=True)
while True:
    instruction = os.read(int(os.environ['TEST_CONTROL_FD']), 1)
    if instruction == b'T':
        print("Test Suite 'All tests' started", flush=True)
    elif instruction in (b'X', b''):
        raise SystemExit(int(os.environ['TEST_COMMAND_EXIT']))
""")

    def executable(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n{body}")
        path.chmod(0o755)
        return path

    def start(self, *, diagnostics=True, sample_mode="block", sample_exit=0, command_exit=0,
              stall_seconds=30):
        environment = dict(os.environ,
                           PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                           TEST_RAW_LOG=str(self.directory / "raw.log"),
                           TEST_CONTROL_FD=str(self.control_read),
                           TEST_EVENTS_FD=str(self.events_write),
                           TEST_SAMPLE_MODE=sample_mode,
                           TEST_SAMPLE_EXIT=str(sample_exit),
                           TEST_COMMAND_EXIT=str(command_exit),
                           STALL_SECONDS=str(stall_seconds), POLL_SECONDS="1",
                           RESUME_RECHECK_SECONDS="0", SAMPLE_SECONDS="1",
                           WATCHDOG_SIMULATOR_UDID="",
                           WATCHDOG_DIAGNOSTICS_DIR=str(self.diagnostics) if diagnostics else "",
                           WATCHDOG_STARTUP_SAMPLE_INTERVAL_SECONDS="1")
        process = subprocess.Popen(["bash", str(WATCHDOG), str(self.command)],
                                   env=environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT,
                                   pass_fds=(self.control_read, self.events_write),
                                   start_new_session=True, text=True)
        self.addCleanup(self.clean_process, process)
        return process

    @staticmethod
    def clean_process(process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=5)

    def sample_event(self):
        ready, _, _ = select.select([self.events_read], [], [], 8)
        self.assertTrue(ready, "startup sample did not start")
        return json.loads(os.read(self.events_read, 4096))

    def wait_for_timeline(self, event):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            path = self.diagnostics / "timeline.tsv"
            if path.exists() and f"\t{event}\t" in path.read_text():
                return path.read_text()
            time.sleep(0.05)
        self.fail(f"missing startup timeline event: {event}")

    def test_sampling_targets_command_and_stops_when_tests_start(self):
        process = self.start()
        sample = self.sample_event()
        self.assertEqual(sample["duration"], "1")
        timeline = self.wait_for_timeline("sample_started")
        self.assertIn(f"pid={sample['target']} ", timeline)
        self.assertRegex(timeline, r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\t\d+\tcommand_started")
        os.write(self.control_write, b"T")
        self.wait_for_timeline("sample_stopped")
        with self.assertRaises(ProcessLookupError):
            os.kill(sample["pid"], 0)
        ready, _, _ = select.select([self.events_read], [], [], 2)
        self.assertFalse(ready, "sampling continued after tests started")
        os.write(self.control_write, b"X")
        output, _ = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, output)
        self.assertIn("Test Suite 'All tests' started", output)
        self.assertIn("CoreSimulator testmanagerd installd",
                      (self.diagnostics / "processes-000000.txt").read_text())
        self.assertIn("fake xcodebuild stack", next(self.diagnostics.glob("sample-*.txt")).read_text())

    def test_sample_failure_warns_and_preserves_command_failure(self):
        process = self.start(sample_mode="exit", sample_exit=7, command_exit=17)
        self.sample_event()
        self.wait_for_timeline("sample_finished")
        os.write(self.control_write, b"X")
        output, _ = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 17, output)
        self.assertIn("::warning::Startup diagnostics: sample exited with status 7", output)
        self.assertIn("\tcommand_finished\tstatus=17", (self.diagnostics / "timeline.tsv").read_text())

    def test_disabled_diagnostics_preserves_output_and_exit_status(self):
        process = self.start(diagnostics=False, command_exit=17)
        os.write(self.control_write, b"X")
        output, _ = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 17, output)
        self.assertIn("Command line invocation:", output)
        self.assertFalse(self.diagnostics.exists())

    def test_command_exit_reaps_an_active_sample(self):
        process = self.start(command_exit=17)
        sample = self.sample_event()
        os.write(self.control_write, b"X")
        output, _ = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 17, output)
        with self.assertRaises(ProcessLookupError):
            os.kill(sample["pid"], 0)
        self.assertIn("\twatchdog_exit\tstatus=17", (self.diagnostics / "timeline.tsv").read_text())

    def test_diagnostics_do_not_reset_stall_detection(self):
        process = self.start(sample_mode="exit", stall_seconds=2)
        output, _ = process.communicate(timeout=8)
        self.assertEqual(process.returncode, 70, output)
        self.assertIn("::error::xcodebuild produced no output for 2s", output)


if __name__ == "__main__":
    unittest.main()
