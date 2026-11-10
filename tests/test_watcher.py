"""Exercise signal handling and process cleanup without a reader or writable sysfs."""
import importlib.machinery
import importlib.util
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch


WATCHER = Path(__file__).resolve().parents[1] / "framework-fingerprint-led-blink"


def needed(value):
    return (
        "/net/reactivated/Fprint/Device/0: "
        "org.freedesktop.DBus.Properties.PropertiesChanged "
        "('net.reactivated.Fprint.Device', {'finger-needed': <"
        + value + ">}, @as [])\n"
    )


class WatcherTests(unittest.TestCase):
    def setUp(self):
        loader = importlib.machinery.SourceFileLoader("watcher", str(WATCHER))
        self.watcher = importlib.util.module_from_spec(
            importlib.util.spec_from_loader(loader.name, loader)
        )
        loader.exec_module(self.watcher)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.led = Path(self.tmp.name)
        (self.led / "trigger").write_text("chromeos-auto")
        (self.led / "brightness").write_text("100")
        self.watcher.LED = str(self.led)
        self.watcher.ON_S = self.watcher.OFF_S = 0.01
        self.addCleanup(self.watcher.stop_blink)

    def wait_for(self, predicate):
        deadline = time.monotonic() + 2
        while not predicate():
            if time.monotonic() > deadline:
                self.fail("watcher did not reach the expected state")
            time.sleep(0.005)

    def assert_trigger(self, value):
        self.wait_for(lambda: (self.led / "trigger").read_text() == value)

    def run_stream(self, stream, exit_code=1):
        with patch.object(self.watcher.signal, "signal"), \
                patch.object(self.watcher.subprocess, "Popen") as popen:
            proc = popen.return_value
            proc.stdout.__iter__.return_value = stream
            proc.poll.return_value = None
            with self.assertRaises(SystemExit) as stopped:
                self.watcher.main()
            self.assertEqual(stopped.exception.code, exit_code)
            proc.terminate.assert_called_once()
            proc.wait.assert_called_once_with(timeout=2)
            proc.stdout.close.assert_called_once()
        self.assert_trigger("chromeos-auto")

    def test_waiting_starts_and_completion_restores_led(self):
        def stream():
            yield needed("true")
            self.assert_trigger("none")
            self.wait_for(lambda: (self.led / "brightness").read_text() == "0")
            yield needed("false")
            self.assert_trigger("chromeos-auto")
        self.run_stream(stream())

    def test_daemon_disappearance_restores_led(self):
        def stream():
            yield needed("true")
            self.assert_trigger("none")
            yield "The name net.reactivated.Fprint does not have an owner\n"
            self.assert_trigger("chromeos-auto")
        self.run_stream(stream())

    def test_unexpected_monitor_exit_restores_led(self):
        self.run_stream(iter([needed("true")]))

    def test_sigterm_restores_led_and_reaps_monitor(self):
        def stream():
            yield needed("true")
            self.assert_trigger("none")
            self.watcher.shutdown(signal.SIGTERM, None)
        self.run_stream(stream(), exit_code=0)

    def test_shutdown_can_interrupt_a_held_lock(self):
        with self.watcher.lock:
            with self.assertRaises(SystemExit):
                self.watcher.shutdown(signal.SIGTERM, None)

    def test_safety_timeout_restores_led(self):
        self.watcher.MAX_BLINK_S = 0.04
        self.watcher.start_blink()
        self.assert_trigger("none")
        self.assert_trigger("chromeos-auto")

    def test_unresponsive_monitor_is_killed_and_reaped(self):
        with patch.object(self.watcher.signal, "signal"), \
                patch.object(self.watcher.subprocess, "Popen") as popen:
            proc = popen.return_value
            proc.stdout.__iter__.return_value = iter([])
            proc.poll.return_value = None
            proc.wait.side_effect = [subprocess.TimeoutExpired("gdbus", 2), 0]
            with self.assertRaises(SystemExit):
                self.watcher.main()
            proc.kill.assert_called_once()
            self.assertEqual(proc.wait.call_count, 2)
        self.assert_trigger("chromeos-auto")


if __name__ == "__main__":
    unittest.main()
