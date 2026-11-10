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
  sensor is waiting for a finger. Then the service takes over the power-button
  LED (exposed by the `leds_cros_ec` kernel driver) and blinks it white:
  0.25 s off / 0.25 s on, starting dark so the change is visible at once.
  - `chromeos:white:power` on most models.
  - `chromeos:multicolor:power` on older Framework 13 (Intel 11th–13th gen),
    picked automatically. Its default color is red, so the service switches
    it to the white channel while blinking and restores the original colors
    afterwards.
- As soon as a finger touches the sensor (`finger-present` turns `true`), or
  when `finger-needed` turns `false` (match, no match, cancel, timeout), or
  fprintd goes away, it stops and hands the LED back to the embedded
  controller (`chromeos-auto` trigger). Blinking resumes if the finger is
  lifted while the sensor still wants one (e.g. a bad scan).
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

### Void Linux (runit)

Use the separate runit installer on Void:

```bash
./install-void.sh --check
./install-void.sh
fprintd-verify
```

The installer uses `doas` when available, otherwise `sudo`. Dependencies must
already be installed: `python3`, `glib` (for `gdbus`), `fprintd`, `runit`,
`util-linux` (for `setpriv`), `shadow`, and `eudev`. It does not change PAM or
fingerprint enrollment.

The watcher runs as a dedicated, non-login `fprint-led` system user with
`no_new_privs`, using the same udev rule and fprintd signals as the systemd
version. Runit does not apply the additional systemd sandbox listed below.
The service lives in `/etc/sv/framework-fingerprint-led-blink` and is enabled
through `/var/service`. Its `finish` hook restores firmware LED control even
after a forced watcher exit. The watcher also stops its `gdbus` child on normal
shutdown. Logs rotate in `/var/log/framework-fingerprint-led-blink`.

```bash
doas sv status framework-fingerprint-led-blink
doas tail -f /var/log/framework-fingerprint-led-blink/current
./install-void.sh --uninstall
```

Uninstall retains logs and the locked service account. Re-run the installer to
update an existing installation. `--check` is read-only; it checks dependencies
and the LED interface, but does not perform a physical blink test.

The existing systemd installation instructions continue below.

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
| `/etc/udev/rules.d/90-framework-fingerprint-led-blink.rules` | gives group `fprint-led` write access to the LED's `trigger`, `brightness` and `multi_intensity` only |
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
  be forged), and only fprintd's own `finger-needed` state can start blinking
  (`finger-present` can only stop it). A rejected `VerifyStart` never sets it.
- **No root.** The service runs as a throwaway `DynamicUser` with no
  capabilities. The udev rule lets it write only the LED's `trigger`,
  `brightness` and `multi_intensity` (color) files.
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
Support for older Framework 13 models with a `chromeos:multicolor:power` LED
was contributed by
[u/catastrophic-success](https://www.reddit.com/user/catastrophic-success),
who reported the LED and provided its details (Framework 13 DIY Intel i5,
Manjaro). The multicolor code path was tested on the same kind of LED;
confirmation on one of those laptops is welcome.
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
echo chromeos-auto | sudo tee /sys/class/leds/chromeos:*:power/trigger
```

## License

Apache License 2.0, see [LICENSE](LICENSE).
