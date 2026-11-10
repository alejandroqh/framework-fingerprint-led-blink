"""Exercise D-Bus signal handling and LED cleanup against a fake bus and a temp LED dir."""
from collections import deque
from collections.abc import Iterable
from contextlib import contextmanager
import importlib.machinery
import importlib.util
from pathlib import Path
import signal
import tempfile
import time
import unittest
from unittest.mock import patch

from jeepney import DBusAddress, HeaderFields, Message, new_error, new_method_return, new_signal


WATCHER = Path(__file__).resolve().parents[1] / "framework-fingerprint-led-blink"
FPRINTD = ":1.452"
DEVICE = "/net/reactivated/Fprint/Device/0"


def signal_from(sender: str, path: str, interface: str, member: str,
                signature: str, body: tuple) -> Message:
    msg = new_signal(DBusAddress(path, interface=interface), member, signature, body)
    msg.header.fields[HeaderFields.sender] = sender  # set by the bus in real life
    return msg


def props(sender: str = FPRINTD, **finger: bool) -> Message:
    """fprintd's PropertiesChanged, e.g. props(needed=False, present=False)."""
    changed = {f"finger-{name}": ("b", value) for name, value in finger.items()}
    return signal_from(sender, DEVICE, "org.freedesktop.DBus.Properties",
                       "PropertiesChanged", "sa{sv}as",
                       ("net.reactivated.Fprint.Device", changed, []))


def owner_changed(new: str, old: str = FPRINTD,
                  sender: str = "org.freedesktop.DBus") -> Message:
    return signal_from(sender, "/org/freedesktop/DBus", "org.freedesktop.DBus",
                       "NameOwnerChanged", "sss", ("net.reactivated.Fprint", old, new))


class FakeBus:
    """Stands in for jeepney's blocking DBusConnection; disconnects after the stream."""

    def __init__(self, stream: Iterable[Message], owner: str | None):
        self.stream = iter(stream)
        self.owner = owner
        self.calls: list[str] = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    @contextmanager
    def filter(self, rule, *, bufsize=1):
        yield deque(maxlen=bufsize)

    def send_and_get_reply(self, msg: Message) -> Message:
        member = msg.header.fields[HeaderFields.member]
        self.calls.append(member)
        if member != "GetNameOwner":
            return new_method_return(msg)
        if self.owner is None:
            return new_error(msg, "org.freedesktop.DBus.Error.NameHasNoOwner")
        return new_method_return(msg, "s", (self.owner,))

    def recv_until_filtered(self, queue) -> Message:
        try:
            return next(self.stream)
        except StopIteration:
            raise ConnectionResetError("bus went away") from None


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

    def assert_never_blinked(self):
        self.assertIsNone(self.watcher.blinker)

    def run_stream(self, stream, exit_code=1, owner: str | None = FPRINTD):
        bus = FakeBus(stream, owner)
        with patch.object(self.watcher.signal, "signal"), \
                patch.object(self.watcher, "open_dbus_connection", return_value=bus):
            with self.assertRaises(SystemExit) as stopped:
                self.watcher.main()
        self.assertEqual(stopped.exception.code, exit_code)
        self.assertEqual(bus.calls, ["AddMatch", "AddMatch", "GetNameOwner"])
        self.assert_trigger("chromeos-auto")

    def test_waiting_starts_and_completion_restores_led(self):
        def stream():
            yield props(needed=True)
            self.assert_trigger("none")
            self.wait_for(lambda: (self.led / "brightness").read_text() == "0")
            yield props(needed=False)
            self.assert_trigger("chromeos-auto")
        self.run_stream(stream())

    def test_finger_touch_stops_blink_before_finger_needed_clears(self):
        # Sequence recorded from fprintd on a match: finger-needed stays true
        # for ~1.4 s after the touch.
        def stream():
            yield props(needed=True)
            self.assert_trigger("none")
            yield props(present=True)
            self.assert_trigger("chromeos-auto")
            yield props(needed=False, present=False)
            self.assert_trigger("chromeos-auto")
        self.run_stream(stream())

    def test_lifted_finger_resumes_blink_while_still_needed(self):
        def stream():
            yield props(needed=True)
            self.assert_trigger("none")
            yield props(present=True)
            self.assert_trigger("chromeos-auto")
            yield props(present=False)
            self.assert_trigger("none")
        self.run_stream(stream())

    def test_finger_present_alone_never_blinks(self):
        def stream():
            yield props(present=True)
            yield props(present=False)
            self.assert_never_blinked()
        self.run_stream(stream())

    def test_signals_from_other_senders_are_ignored(self):
        def stream():
            yield props(sender=":1.99", needed=True)
            self.assert_never_blinked()
        self.run_stream(stream())

    def test_forged_owner_change_is_ignored(self):
        # Only the bus itself may announce a new fprintd.
        def stream():
            yield owner_changed(":1.99", sender=":1.99")
            yield props(sender=":1.99", needed=True)
            self.assert_never_blinked()
            yield props(needed=True)
            self.assert_trigger("none")
        self.run_stream(stream())

    def test_fprintd_started_on_demand_is_followed(self):
        def stream():
            yield props(needed=True)          # no owner yet: cannot be fprintd
            self.assert_never_blinked()
            yield owner_changed(FPRINTD, old="")
            yield props(needed=True)
            self.assert_trigger("none")
        self.run_stream(stream(), owner=None)

    def test_daemon_disappearance_restores_led(self):
        def stream():
            yield props(needed=True)
            self.assert_trigger("none")
            yield owner_changed("")
            self.assert_trigger("chromeos-auto")
            yield props(needed=True)          # stale sender after it left
            self.assertEqual((self.led / "trigger").read_text(), "chromeos-auto")
        self.run_stream(stream())

    def test_bus_disconnect_restores_led(self):
        self.run_stream(iter([props(needed=True)]))

    def test_sigterm_restores_led(self):
        def stream():
            yield props(needed=True)
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


if __name__ == "__main__":
    unittest.main()
