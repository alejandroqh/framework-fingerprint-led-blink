# framework-fingerprint-led-blink

Blink the **power-button LED** of a Framework laptop while the fingerprint
reader is waiting for your finger.

<p align="center">
  <img src="docs/demo.gif" alt="Framework Laptop 16 power button blinking while waiting for a fingerprint" width="360">
  <br><sub>Framework Laptop 16 waiting for a fingerprint during <code>sudo</code> (2× speed)</sub>
</p>

On Framework laptops (13 and 16) the fingerprint reader lives inside the power
button, but nothing tells you when it is actually expecting a touch (sudo,
lock screen, KWallet, polkit…). Neither fprintd, the BIOS, nor the desktop
offer a setting for this, so this small service adds the visual cue.

## How it works

- An unprivileged, sandboxed systemd service runs
  `gdbus monitor --system --dest net.reactivated.Fprint`, which only receives
  signals sent by fprintd itself.
- fprintd's device property `finger-needed` turns `true` exactly while the
  sensor is waiting for a finger. Then the service takes over the LED
  `/sys/class/leds/chromeos:white:power` (exposed by the `leds_cros_ec`
  kernel driver) and blinks it: 0.25 s on / 0.25 s off.
- When `finger-needed` turns `false` (match, no match, cancel, timeout) or
  fprintd goes away, it stops and hands the LED back to the embedded
  controller (`chromeos-auto` trigger).
- Safety nets: blinking never lasts more than 60 s, and the LED is restored
  when the service stops (including `ExecStopPost`).

Nothing in fprintd, libfprint, PAM or the sensor firmware is modified.

## Install

```bash
git clone https://github.com/alejandroqh/framework-fingerprint-led-blink.git
cd framework-fingerprint-led-blink
./install.sh
```

The installer asks for sudo, installs missing dependencies, copies the files,
restores SELinux labels (where present) and enables the service.

| Distro | Dependencies installed |
|---|---|
| Fedora and derivatives (`dnf`) | `glib2` (for `gdbus`), `python3`, `fprintd`, `fprintd-pam` |
| Arch, CachyOS and derivatives (`pacman`) | `glib2`, `python`, `fprintd` |
| Others | none: install `fprintd`, `gdbus` (glib2) and `python3` yourself first |

Requires fprintd 1.92 or newer (for the `finger-needed` property) and systemd.

Upgrading from an earlier version: pull and re-run `./install.sh`.

Test it:

```bash
sudo -k; sudo true     # watch the power button before touching it
```

Uninstall:

```bash
./install.sh --uninstall
```

### Installed files

| File | Purpose |
|---|---|
| `/usr/local/sbin/framework-fingerprint-led-blink` | the watcher (Python, stdlib only) |
| `/etc/systemd/system/framework-fingerprint-led-blink.service` | systemd unit (unprivileged, sandboxed) |
| `/etc/udev/rules.d/90-framework-fingerprint-led-blink.rules` | gives group `fprint-led` write access to the LED's `trigger` and `brightness` only |
| `/etc/sysusers.d/framework-fingerprint-led-blink.conf` | creates the `fprint-led` group |

## Security

The first version ran as root, watched fprintd method calls with `dbus-monitor`
and trusted any matching message on the bus. As reported on r/framework, any
local user could start the blinking with a fake `VerifyStart` call, or stop it
during a real prompt with a spoofed `VerifyStatus` signal. It also ran as root
with almost no sandbox, as pointed out by
[u/Kotentopf](https://www.reddit.com/user/Kotentopf). Thanks for the security
review!

Current design:

- **No spoofing.** Only signals whose sender is the real owner of
  `net.reactivated.Fprint` are received (the bus stamps the sender; it can't
  be forged), and only fprintd's own `finger-needed` state is used. A rejected
  `VerifyStart` never sets it.
- **No root.** The service runs as a throwaway `DynamicUser` with no
  capabilities. The udev rule lets it write two files: the LED's `trigger` and
  `brightness`.
- **Sandboxed.** Read-only filesystem, no network, private `/tmp` and `/dev`,
  syscall filter, `NoNewPrivileges`, `MemoryDenyWriteExecute` and more.
  `systemd-analyze security framework-fingerprint-led-blink` rates it
  **0.6 SAFE**.

Verified on the reference system: the fake `VerifyStart`, spoofed
`VerifyStatus` and spoofed `PropertiesChanged` signals (exact fprintd format)
from an unprivileged user have no effect, while real prompts still blink.

Accepted limit: a user logged in at the machine can make it blink by starting
a real fingerprint verification, because then fprintd really is waiting.

### Tuning

Edit the constants at the top of `framework-fingerprint-led-blink` (`ON_S`, `OFF_S`,
`MAX_BLINK_S`, `LED`) and re-run `./install.sh`.

## Tested on

### Community reports

Thanks to everyone who tested it after the
[r/framework post](https://www.reddit.com/r/framework/comments/1xr9mlb/made_the_fw16_power_button_blink_while_the/)!

| Laptop | Distro | Install method | Reported by |
|---|---|---|---|
| Framework Laptop 16 (Ryzen AI 9 HX 370) | Fedora 45 | `install.sh` | maintainer (reference system below) |
| Framework Laptop 13 (Ryzen AI 300) | Fedora 45 | `install.sh` | [u/countChaiula](https://www.reddit.com/user/countChaiula) |
| Framework Laptop 13 (Ryzen 5 7640U) | Arch Linux | manual | [u/newenglandpolarbear](https://www.reddit.com/user/newenglandpolarbear) |
| Framework Laptop 13 (Core Ultra 5 125H) | Arch Linux | manual | [u/X_m7](https://www.reddit.com/user/X_m7) |
| Framework laptop | CachyOS | `install.sh` with the `dnf` line commented out, deps installed by hand | [u/CRRogue](https://www.reddit.com/user/CRRogue) |

So far it works on the **Laptop 16** and the **Laptop 13 (AMD and Intel)**.
Native Arch and CachyOS support in the installer was contributed by
[@JoshCodeStuff](https://github.com/JoshCodeStuff) in
[#2](https://github.com/alejandroqh/framework-fingerprint-led-blink/pull/2);
the Arch and CachyOS reports above predate it.

Tested it on another model or distro? Open an issue or PR to add it here.

### Reference system

Developed and tested on 2026-11-08; secured version tested on 2026-11-09.

#### Software

| Component | Version |
|---|---|
| Fedora | **45** (Forty Five) |
| Kernel | 7.2.15-300.fc45.x86_64 |
| fprintd / fprintd-pam | 1.94.5-6.fc45 |
| libfprint | 1.94.100-1.fc45 |
| PAM | 1.7.2-4.fc45 |
| systemd | 262.1-1.fc45 |
| dbus-broker | 37-9.fc45 |
| glib2 (`gdbus`) | 2.90.1-1.fc45 |
| Python | 3.15.0-1.fc45 |
| Desktop | KDE Plasma 6.8.2 (Wayland) |
| SELinux | enforcing |

#### Hardware

| Component | Details |
|---|---|
| Laptop | Framework Laptop 16 (AMD Ryzen AI 300 Series), board rev. A9 |
| CPU / GPU | AMD Ryzen AI 9 HX 370 w/ Radeon 890M |
| BIOS | 04.01 (2026-06-12) |
| Fingerprint sensor | Goodix Match-on-Chip, USB `27C6:609C`, firmware `01000334` |
| LED | `chromeos:white:power` (power button, via `leds_cros_ec`) |

## Ports

- **NixOS**: [sophronesis/nix-framework-fingerprint-led-blink](https://github.com/sophronesis/nix-framework-fingerprint-led-blink)
  by [u/Sophronesis0](https://www.reddit.com/user/Sophronesis0) (ported from
  the first, root-based version)

## Troubleshooting

```bash
systemctl status framework-fingerprint-led-blink
journalctl -u framework-fingerprint-led-blink -b
```

If the service fails to start on an unusual Python build, `MemoryDenyWriteExecute`
is the most likely cause; disable it with `sudo systemctl edit
framework-fingerprint-led-blink` and add:

```ini
[Service]
MemoryDenyWriteExecute=no
```

If the LED ever gets stuck, return it to the EC manually:

```bash
echo chromeos-auto | sudo tee /sys/class/leds/chromeos:white:power/trigger
```

## License

Apache License 2.0, see [LICENSE](LICENSE).
