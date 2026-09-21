# Vivobook Control for Omarchy

An [Omarchy](https://omarchy.org) shell plugin for the ASUS Vivobook S 14 (S5406SA and
siblings). One bar icon opens a dashboard with the laptop's ASUS-specific controls, and every
control is also reachable from keybindings, the Omarchy menu and the command line.

| Control | How it works on Linux |
|---|---|
| Keyboard light (0–3) | `asus::kbd_backlight` LED via `brightnessctl` |
| Keyboard RGB color and effects | HID LampArray reports to the ITE5570 controller (`/dev/hidraw*`), driven by a small user daemon (`vivobook-rgbd`) for breathing/rainbow |
| Performance profile | `power-profiles-daemon` through `omarchy-powerprofiles-set` (quiet / balanced / performance) — CPU temperature shown alongside |
| Battery charge limit (60 / 80 / 100 %) | `charge_control_end_threshold` via a tiny root helper, restored at boot and after resume |
| Copilot key | The key emits `Meta+Shift+F23` (keycode 201). Omarchy binds it to its menu by default; the generated Hyprland file takes the key over and runs the action you pick (default: launch your default Omarchy agent) |
| Touchpad gestures | Generated `hl.gesture(...)` rules: 3-finger swipe ↔ workspaces, 3-finger ↑/↓ actions, 4-finger ↔ move window, pinch to float |
| ASUS edge slides | `vivobook-edged` grabs the touchpad, re-emits it through uinput, and turns single-finger slides on the right edge (brightness), left edge (volume) and top edge (back/forward) into actions |

## Install

```bash
omarchy plugin add https://github.com/leandrooricchio/omarchy-vivobook.git --enable
sudo ~/.config/omarchy/plugins/io.github.leandrooricchio.vivobook/setup.sh
```

The plugin works immediately for the keyboard light, performance profile, Copilot key and
Hyprland gestures. `setup.sh` (one time, with sudo) unlocks the rest. It:

- installs `python-evdev`, `brightnessctl`, `wtype`
- installs `/etc/udev/rules.d/70-vivobook.rules` (uaccess ACLs for the RGB hidraw node, `/dev/uinput` and the touchpad — no group changes, no re-login)
- installs `/usr/local/libexec/vivobook-charge` + `/etc/sudoers.d/vivobook` (only that helper, only 60/80/100) and a boot service that restores the saved limit
- installs a `systemd-sleep` hook so RGB and charge limit come back after resume
- enables the user services `vivobook-rgbd` and `vivobook-apply`, links `~/.local/bin/vivobook-ctl`, renders the Hyprland bindings, adds the menu entries and enables the plugin

Remove everything with `sudo .../uninstall.sh`, then `omarchy plugin remove io.github.leandrooricchio.vivobook`.

## Use

- Click the 󰌌 icon in the bar, or press `Super+Shift+V`, or `omarchy-shell shell toggle io.github.leandrooricchio.vivobook`.
- Right-click the icon to cycle the keyboard light; scroll on it to step it.
- Keyboard navigation inside the panel: `j`/`k` move between rows, `h`/`l` move within a row or adjust the slider, `Enter` activates, `Esc` closes.
- Omarchy menu → Hardware → *Vivobook Control*, *Keyboard RGB Next Color*, *Touchpad Edge Gestures*.

### Command line

```
vivobook-ctl status --json            # everything the panel shows
vivobook-ctl doctor                   # what is unlocked and how to fix what is not
vivobook-ctl kbd up|down|cycle|set N
vivobook-ctl rgb set RRGGBB | effect static|breathing|rainbow|off | auto | next | info
vivobook-ctl profile set quiet|balanced|performance | cycle
vivobook-ctl charge set 60|80|100 | cycle
vivobook-ctl copilot set agent-pick|agent|dashboard|menu | set custom --command "..." | run
vivobook-ctl gestures set workspace3|move4|pinchFloat on|off | set up3|down3 fullscreen|maximized|close|none
vivobook-ctl edge enable|disable|toggle|status | set zonePct|stepPx|right|left|top <value>
```

Shell IPC (usable from keybindings): `omarchy-shell vivobook kbdUp|kbdDown|kbdCycle|rgbNext|profileCycle|chargeCycle|edgeToggle|toggle`.

### Changing the Copilot key

Pick a preset in the panel, or `vivobook-ctl copilot set custom --command "omarchy-launch-browser"`.
The Hyprland bind always runs `vivobook-ctl copilot run`, so no reload is needed after a change.

### Settings

State lives in `~/.config/omarchy/vivobook/config.json`; the generated Hyprland file is
`~/.local/state/omarchy/toggles/hypr/vivobook.lua` (Omarchy loads that directory on every
reload — nothing under `~/.config/hypr` is touched). `showKbdLevelInBar` is a normal bar-widget
setting in `shell.json`.

## Development

```bash
git clone https://github.com/leandrooricchio/omarchy-vivobook ~/Work/omarchy-vivobook
cd ~/Work/omarchy-vivobook
./dev.sh --watch        # rsync into ~/.config/omarchy/plugins/<id> on every save + validate
omarchy plugin enable io.github.leandrooricchio.vivobook --section right --index 0
qs log -p "$OMARCHY_PATH/shell" --tail 50   # QML errors land here
```

If a QML change does not show up, `omarchy restart shell` (the shell occasionally keeps a
cached component after a syntax error).

## Privilege boundary

Nothing in the plugin runs as root at runtime. `setup.sh` is the only privileged step; the
sudoers entry allows exactly one root helper (`vivobook-charge`) that accepts only `60`, `80`,
`100` or `restore`. The RGB controller, uinput and the touchpad node are made accessible to the
logged-in seat user via udev `uaccess` ACLs.

## Hardware notes

- The RGB controller is `0B05:19B6` (ITE5570) on I2C-HID, exposed as a HID LampArray
  (usage page 0x59). `asusctl` does not support Vivobooks, and the WMI LED only carries the
  0–3 brightness. `vivobook-ctl rgb info` prints the lamp count and report ids it detected.
- The fan on this model exposes no curve or PWM control, so the plugin does not show or touch it.
- The Copilot key needs kernel ≥ 6.14 to be reported as `F23`.

## License

MIT
