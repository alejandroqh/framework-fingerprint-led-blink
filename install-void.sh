#!/bin/bash
# Install the fingerprint LED watcher as an unprivileged Void Linux runit service.
# Usage: ./install-void.sh [--check|--uninstall]
set -euo pipefail
export PATH=/usr/bin:/bin

NAME=framework-fingerprint-led-blink
ACCOUNT=fprint-led
BIN=/usr/local/sbin/$NAME
SERVICE=/etc/sv/$NAME
ENABLED=/var/service/$NAME
SUPERVISE=/run/runit/supervise.$NAME
RULE=/etc/udev/rules.d/90-$NAME.rules
LOG=/var/log/$NAME
SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LED=/sys/class/leds/chromeos:white:power
[[ -e $LED/trigger ]] || LED=/sys/class/leds/chromeos:multicolor:power

die() { printf '%s\n' "$*" >&2; exit 1; }

case "${1:-}" in
    -h|--help)
        printf 'Usage: %s [--check|--uninstall]\n' "$0"
        printf 'No argument: install/update and enable the runit service.\n'
        printf '%s\n' '--check: read-only dependency and LED checks; no root required.'
        exit 0 ;;
    ''|--install|--check|--uninstall) ;;
    *) die "Unknown option: $1 (use --help)" ;;
esac
(( $# <= 1 )) || die 'Expected at most one option.'

preflight() {
    [[ -d /etc/sv && -d /var/service ]] || die 'Void runit service directories not found.'
    local cmd
    for cmd in python3 fprintd-verify chpst setpriv sv svlogd udevadm groupadd useradd; do
        command -v "$cmd" >/dev/null || die "Missing command: $cmd"
    done
    python3 -I -c 'from jeepney.io.blocking import open_dbus_connection' 2>/dev/null ||
        die 'Missing Python module: jeepney (install python3-jeepney).'
    [[ -e $LED/trigger ]] || die 'No supported Framework power-button LED found.'
    grep -qw chromeos-auto "$LED/trigger" || die 'LED lacks the chromeos-auto trigger.'
    [[ -e /var/service/dbus/run ]] || die 'Enable the dbus runit service first.'
    printf 'Dependencies available; LED: %s\n' "$LED"
}

if [[ ${1:-} == --check ]]; then
    preflight
    exit 0
fi

if (( EUID != 0 )); then
    if command -v doas >/dev/null; then
        exec doas "$SRC_DIR/install-void.sh" "$@"
    fi
    exec sudo -- "$SRC_DIR/install-void.sh" "$@"
fi

# Refuse to replace another service registered under this name.
if [[ -e $ENABLED || -L $ENABLED ]]; then
    [[ -L $ENABLED && $(readlink -f "$ENABLED") == "$SERVICE" ]] ||
        die "Unexpected service at $ENABLED; leaving it alone."
fi

# Stop and disable the service, then wait for runsvdir (which rescans about
# every 5s) to reap its runsv, so $SERVICE can be safely modified or removed.
disable_service() {
    [[ -L $ENABLED ]] || return 0
    sv -w 10 down "$ENABLED" || true
    rm -- "$ENABLED"
    for _ in {1..50}; do
        sv status "$SERVICE" >/dev/null 2>&1 || return 0
        sleep 0.2
    done
    die "runsv for $NAME did not exit; leaving $SERVICE alone."
}

if [[ ${1:-} == --uninstall ]]; then
    disable_service
    rm -rf -- "$SERVICE" "$SUPERVISE" "$SUPERVISE-log"
    rm -f -- "$BIN" "$RULE"
    udevadm control --reload
    if [[ -e $LED/trigger ]]; then
        printf '%s\n' chromeos-auto > "$LED/trigger"
        for attr in trigger brightness multi_intensity; do
            [[ -e $LED/$attr ]] || continue
            chown root:root "$LED/$attr"
            chmod 0644 "$LED/$attr"
        done
        # Reapply other installed rules, including brightnessctl's input group.
        udevadm trigger --action=add "$LED"
        udevadm settle
    fi
    printf 'Removed. LED restored; logs and the locked service account retained.\n'
    exit 0
fi

preflight

getent group "$ACCOUNT" >/dev/null || groupadd --system "$ACCOUNT"
getent passwd "$ACCOUNT" >/dev/null ||
    useradd --system --gid "$ACCOUNT" --home-dir /nonexistent \
        --no-create-home --shell /sbin/nologin "$ACCOUNT"

install -D -m 0755 "$SRC_DIR/$NAME" "$BIN"
install -D -m 0755 "$SRC_DIR/packaging/runit/run" "$SERVICE/run"
install -D -m 0755 "$SRC_DIR/packaging/runit/finish" "$SERVICE/finish"
install -D -m 0755 "$SRC_DIR/packaging/runit/log/run" "$SERVICE/log/run"
install -d -m 0700 "$LOG"
install -D -m 0644 "$SRC_DIR/packaging/90-$NAME.rules" "$RULE"
udevadm control --reload
udevadm trigger --action=change "$LED"
udevadm settle
for attr in trigger brightness multi_intensity; do
    [[ -e $LED/$attr ]] || continue
    chpst -u "$ACCOUNT:$ACCOUNT" test -w "$LED/$attr" ||
        die "udev did not grant $ACCOUNT write access to $LED/$attr"
done

# Keep runit's supervision state on tmpfs, like Void's own services; runsv
# recreates the link targets at boot. Earlier installs used real directories,
# which can only be replaced while runsv is not running.
if [[ -d $SERVICE/supervise && ! -L $SERVICE/supervise ]] ||
   [[ -d $SERVICE/log/supervise && ! -L $SERVICE/log/supervise ]]; then
    disable_service
    rm -rf -- "$SERVICE/supervise" "$SERVICE/log/supervise"
fi
[[ -L $SERVICE/supervise ]] || ln -s "$SUPERVISE" "$SERVICE/supervise"
[[ -L $SERVICE/log/supervise ]] || ln -s "$SUPERVISE-log" "$SERVICE/log/supervise"

if [[ -L $ENABLED ]]; then
    sv -w 10 restart "$ENABLED"
else
    ln -s "$SERVICE" "$ENABLED"
    # runsv starts the service as soon as runsvdir discovers it.
    for _ in {1..50}; do
        sv status "$ENABLED" >/dev/null 2>&1 && break
        sleep 0.2
    done
    sv status "$ENABLED" >/dev/null 2>&1 || die "runsvdir did not pick up $ENABLED."
fi

# Outlast finish's 2s back-off, so a crash loop shows up as a short uptime.
sleep 3
status=$(sv status "$ENABLED" 2>&1) || true
printf '%s\n' "$status"
up_re='^run: [^;]*\(pid [0-9]+\) ([0-9]+)s'
if [[ ! $status =~ $up_re ]] || (( BASH_REMATCH[1] < 2 )); then
    die "Service is not staying up; see $LOG/current"
fi
printf 'Enabled. Test with: fprintd-verify\nLogs: %s/current\n' "$LOG"
