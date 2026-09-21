#!/bin/bash
# Reverse setup.sh. Run with sudo. Leaves ~/.config/omarchy/vivobook/config.json in place.
set -euo pipefail

PLUGIN_ID="io.github.leandrooricchio.vivobook"
if [[ $EUID -ne 0 ]]; then echo "Run with sudo: sudo $0" >&2; exit 1; fi
TARGET_USER="${SUDO_USER:-}"
[[ -n $TARGET_USER && $TARGET_USER != root ]] || { echo "SUDO_USER unset" >&2; exit 1; }
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_UID="$(id -u "$TARGET_USER")"
as_user() {
  sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" XDG_RUNTIME_DIR="/run/user/$TARGET_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus" PATH="$TARGET_HOME/.local/bin:$PATH" "$@"
}

as_user systemctl --user disable --now vivobook-rgbd.service vivobook-apply.service vivobook-edged.service 2>/dev/null || true
rm -f "$TARGET_HOME/.config/systemd/user/vivobook-"{rgbd,apply,edged}.service
as_user systemctl --user daemon-reload || true

systemctl disable --now vivobook-charge.service 2>/dev/null || true
rm -f /etc/systemd/system/vivobook-charge.service /etc/sudoers.d/vivobook /usr/local/libexec/vivobook-charge
rm -rf /etc/vivobook
rm -f /usr/lib/systemd/system-sleep/vivobook /etc/udev/rules.d/70-vivobook.rules
systemctl daemon-reload
udevadm control --reload

rm -f "$TARGET_HOME/.local/bin/vivobook-ctl"
rm -f "$TARGET_HOME/.local/state/omarchy/toggles/hypr/vivobook.lua"
menu="$TARGET_HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
[[ -f $menu ]] && as_user sed -i '/\/\/ vivobook:begin/,/\/\/ vivobook:end/d' "$menu"
as_user hyprctl reload >/dev/null 2>&1 || true
as_user omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true

echo "Removed system integration. To delete the plugin itself: omarchy plugin remove $PLUGIN_ID"
