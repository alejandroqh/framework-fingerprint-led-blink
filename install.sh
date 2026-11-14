#!/usr/bin/env bash
# Installer for framework-fingerprint-led-blink (Fedora / Arch / Debian, Ubuntu; others: deps by hand).
#   ./install.sh             install / update and start the service
#   ./install.sh --uninstall stop, disable and remove everything
set -euo pipefail

NAME=framework-fingerprint-led-blink
BIN=/usr/local/sbin/$NAME
UNIT=/etc/systemd/system/$NAME.service
RULE=/etc/udev/rules.d/90-$NAME.rules
SYSUSERS=/etc/sysusers.d/$NAME.conf
GROUP=fprint-led
# Power-button LED: white on most models, multicolor on older Framework 13.
LED=/sys/class/leds/chromeos:white:power
[[ -e $LED/trigger ]] || LED=/sys/class/leds/chromeos:multicolor:power
LED_FILES=(trigger brightness multi_intensity)
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

# Re-run as root if needed.
if [[ $EUID -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

do_uninstall() {
    info "Stopping and disabling $NAME"
    systemctl disable --now "$NAME.service" 2>/dev/null || true
    rm -f "$BIN" "$UNIT" "$RULE" "$SYSUSERS"
    systemctl daemon-reload
    udevadm control --reload 2>/dev/null || true
    if [[ -e $LED/trigger ]]; then
        local f
        for f in "${LED_FILES[@]}"; do
            [[ -e $LED/$f ]] || continue
            chown root:root "$LED/$f" || true
            chmod 0644 "$LED/$f" || true
        done
        echo chromeos-auto > "$LED/trigger" || true
    fi
    groupdel "$GROUP" 2>/dev/null || true
    info "Removed. The power LED is back under EC control."
}

do_install() {
    if [[ ! -e $LED/trigger ]]; then
        die "No chromeos:white:power or chromeos:multicolor:power LED found. This needs a Framework laptop with the cros_ec LED driver (leds_cros_ec)."
    fi

    local pkgs=()

    if command -v dnf >/dev/null; then
        # Fedora and derivatives
        command -v gdbus        >/dev/null || pkgs+=(glib2)
        command -v python3      >/dev/null || pkgs+=(python3)
        rpm -q fprintd >/dev/null 2>&1     || pkgs+=(fprintd fprintd-pam)
        if ((${#pkgs[@]})); then
            info "Installing dependencies: ${pkgs[*]}"
            dnf install -y "${pkgs[@]}"
        fi
    elif command -v pacman >/dev/null; then
        # Arch, CachyOS and derivatives (--needed skips what is already installed)
        info "Installing dependencies: glib2 python fprintd"
        pacman -S --needed --noconfirm glib2 python fprintd
    elif command -v apt-get >/dev/null; then
        # Debian, Ubuntu and derivatives
        command -v gdbus        >/dev/null || pkgs+=(libglib2.0-bin)
        command -v python3      >/dev/null || pkgs+=(python3)
        dpkg -s fprintd >/dev/null 2>&1    || pkgs+=(fprintd libpam-fprintd)
        if ((${#pkgs[@]})); then
            info "Installing dependencies: ${pkgs[*]}"
            apt-get install -y "${pkgs[@]}"
        fi
    else
        warn "No dnf, pacman or apt-get found; skipping dependency installation."
        warn "Make sure fprintd, gdbus (glib2) and python3 are installed."
        for cmd in fprintd-verify gdbus python3; do
            command -v "$cmd" >/dev/null || warn "missing: $cmd"
        done
    fi

    info "Granting group $GROUP write access to the LED (udev rule)"
    install -D -m 0644 "$SRC_DIR/packaging/sysusers.conf" "$SYSUSERS"
    install -D -m 0644 "$SRC_DIR/packaging/90-$NAME.rules" "$RULE"
    command -v restorecon >/dev/null && restorecon "$SYSUSERS" "$RULE" || true
    systemd-sysusers "$SYSUSERS"
    udevadm control --reload
    udevadm trigger --action=change "$LED"
    udevadm settle
    local f
    info "Using LED $LED"
    for f in "${LED_FILES[@]}"; do
        [[ -e $LED/$f ]] || continue
        if [[ $(stat -c %G "$LED/$f") != "$GROUP" ]] || [[ ! -w $LED/$f ]] \
           || (( ( 8#$(stat -c %a "$LED/$f") & 8#020 ) == 0 )); then
            die "udev rule did not apply to $LED/$f (expected group $GROUP, g+w)."
        fi
    done

    info "Installing $BIN and $UNIT"
    install -m 0755 "$SRC_DIR/$NAME" "$BIN"
    install -m 0644 "$SRC_DIR/$NAME.service" "$UNIT"
    command -v restorecon >/dev/null && restorecon "$BIN" "$UNIT" || true

    systemctl daemon-reload
    systemctl enable "$NAME.service"
    systemctl restart "$NAME.service"

    # A crash-looping service still reads "active" right after a restart, so
    # check that the same process outlasts RestartSec=2.
    local pid
    pid=$(systemctl show -P MainPID "$NAME.service")
    sleep 3
    if [[ $pid != 0 && $(systemctl show -P MainPID "$NAME.service") == "$pid" ]]; then
        info "Done. The power button LED will blink while fprintd waits for a finger."
        info "Test it with:  sudo -k; sudo true"
    else
        systemctl status "$NAME.service" --no-pager || true
        die "Service is not staying up; see: journalctl -u $NAME -b"
    fi
}

case "${1:-}" in
    --uninstall|-u) do_uninstall ;;
    ""|--install)   do_install ;;
    *)              die "unknown option: $1 (use --help)" ;;
esac
