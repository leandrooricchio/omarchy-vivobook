#!/bin/bash
# One-time system setup for Vivobook Control. Run with sudo:
#   sudo ~/.config/omarchy/plugins/io.github.leandrooricchio.vivobook/setup.sh
#
# The Omarchy plugin installer never runs code or sudo, so the pieces that need
# root live here: udev access rules (keyboard RGB, uinput, touchpad), the charge
# limit helper + sudoers entry, a resume hook, and the user services.
set -euo pipefail

PLUGIN_ID="io.github.leandrooricchio.vivobook"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi
TARGET_USER="${SUDO_USER:-}"
if [[ -z $TARGET_USER || $TARGET_USER == root ]]; then
  echo "setup.sh must be run via sudo from your own user (SUDO_USER unset)" >&2
  exit 1
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_UID="$(id -u "$TARGET_USER")"
PLUGIN_DIR="$TARGET_HOME/.config/omarchy/plugins/$PLUGIN_ID"

# sudo resets the environment, so rebuild what the user session commands need:
# Omarchy's bin dir, the user bus, and the running Hyprland instance.
HYPR_SIG="$(ls -1 "/run/user/$TARGET_UID/hypr" 2>/dev/null | head -n1)"
as_user() {
  sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" XDG_RUNTIME_DIR="/run/user/$TARGET_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus" \
    HYPRLAND_INSTANCE_SIGNATURE="$HYPR_SIG" OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}" \
    PATH="$TARGET_HOME/.local/bin:${OMARCHY_PATH:-/usr/share/omarchy}/bin:$PATH" "$@"
}

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

family="$(cat /sys/class/dmi/id/product_family 2>/dev/null || true)"
if [[ $family != *Vivobook* ]]; then
  echo "Warning: this machine reports '$family', not a Vivobook. Continuing anyway." >&2
fi

if [[ ! -d $PLUGIN_DIR ]]; then
  echo "Plugin not found at $PLUGIN_DIR. Install it first:" >&2
  echo "  omarchy plugin add <git-url> --enable   (or ./dev.sh from a checkout)" >&2
  exit 1
fi

step "Installing packages"
pacman -S --needed --noconfirm python-evdev brightnessctl wtype

step "Installing udev rules"
install -Dm644 "$SRC/system/70-vivobook.rules" /etc/udev/rules.d/70-vivobook.rules
udevadm control --reload
udevadm trigger --subsystem-match=hidraw --subsystem-match=misc --subsystem-match=input --action=change

step "Installing charge limit helper"
install -Dm755 "$SRC/system/vivobook-charge" /usr/local/libexec/vivobook-charge
printf '%s ALL=(root) NOPASSWD: /usr/local/libexec/vivobook-charge\n' "$TARGET_USER" >/etc/sudoers.d/vivobook
chmod 0440 /etc/sudoers.d/vivobook
visudo -cf /etc/sudoers.d/vivobook >/dev/null
install -Dm644 "$SRC/system/vivobook-charge.service" /etc/systemd/system/vivobook-charge.service
systemctl daemon-reload
systemctl enable vivobook-charge.service >/dev/null 2>&1 || true
current_limit="$(cat /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/dev/null || echo 100)"
if [[ ! -f /etc/vivobook/charge-limit ]]; then
  case "$current_limit" in 60|80|100) /usr/local/libexec/vivobook-charge "$current_limit" ;; esac
fi

step "Installing resume hook"
install -Dm755 "$SRC/system/vivobook-sleep" /usr/lib/systemd/system-sleep/vivobook

step "Installing user services"
as_user install -Dm644 "$SRC/system/vivobook-rgbd.service" "$TARGET_HOME/.config/systemd/user/vivobook-rgbd.service"
as_user install -Dm644 "$SRC/system/vivobook-apply.service" "$TARGET_HOME/.config/systemd/user/vivobook-apply.service"
as_user install -Dm644 "$SRC/system/vivobook-edged.service" "$TARGET_HOME/.config/systemd/user/vivobook-edged.service"
as_user systemctl --user daemon-reload
as_user systemctl --user enable --now vivobook-rgbd.service vivobook-apply.service

step "Linking vivobook-ctl into ~/.local/bin"
as_user mkdir -p "$TARGET_HOME/.local/bin"
as_user ln -sfn "$PLUGIN_DIR/bin/vivobook-ctl" "$TARGET_HOME/.local/bin/vivobook-ctl"

step "Rendering Hyprland bindings and gestures"
as_user "$PLUGIN_DIR/bin/vivobook-ctl" render-hypr --no-reload
as_user hyprctl reload >/dev/null 2>&1 || true

step "Adding Omarchy menu entries"
menu="$TARGET_HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
if [[ -f $menu ]] && ! grep -q "vivobook:begin" "$menu"; then
  as_user python3 - "$menu" "$SRC/system/menu.jsonc" <<'PY'
import sys
path, snippet = sys.argv[1], sys.argv[2]
text = open(path).read()
block = "  // vivobook:begin\n" + open(snippet).read().rstrip("\n") + "\n  // vivobook:end\n"
idx = text.rstrip().rfind("}")
if idx < 0:
    sys.exit("menu file has no closing brace")
open(path, "w").write(text[:idx] + block + text[idx:])
PY
fi

step "Enabling the plugin"
as_user omarchy plugin enable "$PLUGIN_ID" --section right >/dev/null 2>&1 || true
as_user omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

step "Done"
as_user "$PLUGIN_DIR/bin/vivobook-ctl" doctor || true
cat <<MSG

Keyboard RGB, charge limit and edge gestures are now unlocked. The bar shows the
Vivobook icon; Super+Shift+V opens the panel. The Copilot key launches your
default agent (change it in the panel).
MSG
