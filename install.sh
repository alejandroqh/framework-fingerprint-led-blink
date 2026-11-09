#!/usr/bin/env bash
# Installer for framework-fingerprint-led-blink on Fedora.
#   ./install.sh             install / update and start the service
#   ./install.sh --uninstall stop, disable and remove everything
set -euo pipefail

NAME=framework-fingerprint-led-blink
BIN=/usr/local/sbin/$NAME
UNIT=/etc/systemd/system/$NAME.service
LED=/sys/class/leds/chromeos:white:power
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
    rm -f "$BIN" "$UNIT"
    systemctl daemon-reload
    [[ -e $LED/trigger ]] && echo chromeos-auto > "$LED/trigger" || true
    info "Removed. The power LED is back under EC control."
}

do_install() {
    if ! grep -qi fedora /etc/os-release; then
        warn "This installer targets Fedora; continuing anyway."
        warn "Please ensure fprintd (fprintd-pam if applicable), dbus-tools, and python 3 are installed."
    fi

    if [[ ! -e $LED/trigger ]]; then
        die "LED $LED not found. This needs a Framework laptop with the cros_ec LED driver (leds_cros_ec)."
    fi

    local pkgs=()

    if command -v dnf >/dev/null; then
        command -v dbus-monitor >/dev/null || pkgs+=(dbus-tools)
        command -v python3      >/dev/null || pkgs+=(python3)
        rpm -q fprintd >/dev/null 2>&1     || pkgs+=(fprintd fprintd-pam)
        if ((${#pkgs[@]})); then
            info "Installing dependencies: ${pkgs[*]}"
            dnf install -y "${pkgs[@]}"
        fi
    elif command -v pacman >/dev/null; then
            info "Installing dependencies: dbus python fprintd"
            pacman -S --needed --noconfirm dbus python fprintd
    fi

    info "Installing $BIN and $UNIT"
    install -m 0755 "$SRC_DIR/$NAME" "$BIN"
    install -m 0644 "$SRC_DIR/$NAME.service" "$UNIT"
    command -v restorecon >/dev/null && restorecon "$BIN" "$UNIT" || true

    systemctl daemon-reload
    systemctl enable "$NAME.service"
    systemctl restart "$NAME.service"

    if systemctl is-active --quiet "$NAME.service"; then
        info "Done. The power button LED will blink while fprintd waits for a finger."
        info "Test it with:  sudo -k; sudo true"
    else
        systemctl status "$NAME.service" --no-pager || true
        die "Service failed to start."
    fi
}

case "${1:-}" in
    --uninstall|-u) do_uninstall ;;
    ""|--install)   do_install ;;
    *)              die "unknown option: $1 (use --help)" ;;
esac
