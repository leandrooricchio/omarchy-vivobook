#!/bin/bash
# One-time system setup for Vivobook Control. Run with sudo:
#   sudo ~/.config/omarchy/plugins/io.github.leandrooricchio.vivobook/setup.sh [--expect SHA256 | --yes]
#
# The Omarchy plugin installer never runs code or sudo, so the pieces that need
# root live here: udev access rules (keyboard RGB, uinput, touchpad), the charge
# limit helper + sudoers entry, a resume hook, and the user services.
#
# The plugin checkout lives in the user's home and is writable by every process
# of that user, so root never installs straight from it. The script first
# snapshots the fixed payload into a root-owned directory, verifies the snapshot
# against SHA256SUMS (and, with --expect, against a digest you got from the
# release page), then re-executes the *snapshot's* copy of itself. Every
# privileged read after that comes from the protected snapshot.
#
#   --expect SHA256  abort unless sha256(SHA256SUMS) equals this digest
#   --yes            skip the interactive confirmation (local development)
#
# Everything is inside main(), invoked on the last line, so bash never re-reads
# a modified script while it runs.
set -euo pipefail

PLUGIN_ID="io.github.leandrooricchio.vivobook"
STAGE_BASE=/var/lib
STAGE_GLOB="$STAGE_BASE/vivobook-setup."

# The complete privileged payload. SHA256SUMS must list exactly these files.
PAYLOAD=(
  manifest.json
  setup.sh
  system/70-vivobook.rules
  system/menu.jsonc
  system/vivobook-apply.service
  system/vivobook-charge
  system/vivobook-charge.service
  system/vivobook-edged.service
  system/vivobook-rgbd.service
  system/vivobook-sleep
  system/vivobook-uninstall
)

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "setup.sh: $*" >&2; exit 1; }

# Copy the payload into a fresh root-owned directory, verify it there, then hand
# over to the snapshot's own setup.sh. Never returns on success.
stage_and_exec() {
  local src="$1" expect="$2" assume_yes="$3" stage rel digest answer
  stage="$(mktemp -d "${STAGE_GLOB}XXXXXX")"
  chmod 0755 "$stage"   # root-owned and not writable by anyone else; the user must be able to read it

  for rel in "${PAYLOAD[@]}" SHA256SUMS; do
    install -d -m0755 -o root -g root "$stage/$(dirname "$rel")"
    # -P: never follow a symlink; the type check below runs on the copy, not the source.
    cp -P --no-preserve=all "$src/$rel" "$stage/$rel" || { rm -rf "$stage"; die "cannot read $rel"; }
    if [[ -L $stage/$rel || ! -f $stage/$rel ]]; then
      rm -rf "$stage"; die "$rel is not a regular file"
    fi
    chown root:root "$stage/$rel"
    chmod 0644 "$stage/$rel"
  done

  if ! diff -q <(printf '%s\n' "${PAYLOAD[@]}" | sort) \
               <(awk '{print $2}' "$stage/SHA256SUMS" | sort) >/dev/null; then
    rm -rf "$stage"; die "SHA256SUMS does not list exactly the setup payload"
  fi
  if ! (cd "$stage" && sha256sum --check --strict --quiet SHA256SUMS); then
    rm -rf "$stage"; die "payload does not match SHA256SUMS; refusing to continue"
  fi

  digest="$(sha256sum "$stage/SHA256SUMS" | awk '{print $1}')"
  if [[ -n $expect ]]; then
    if [[ $digest != "$expect" ]]; then
      rm -rf "$stage"; die "SHA256SUMS digest $digest does not match --expect $expect"
    fi
  elif [[ $assume_yes != 1 ]]; then
    if [[ ! -t 0 ]]; then
      rm -rf "$stage"; die "no terminal to confirm on; pass --expect <sha256> or --yes"
    fi
    echo "Payload digest (sha256 of SHA256SUMS): $digest"
    echo "Compare it with the digest published for this release before continuing."
    read -r -p "Install as root? [y/N] " answer
    [[ $answer == y || $answer == Y ]] || { rm -rf "$stage"; die "aborted"; }
  fi

  exec bash "$stage/setup.sh" --staged "$stage"
}

install_system() {
  local stage="$1"
  STAGE_DIR="$stage"
  trap 'rm -rf "$STAGE_DIR"' EXIT

  [[ $stage == "$STAGE_GLOB"* && $(stat -c '%u:%a' "$stage") == 0:755 \
     && $(readlink -f "${BASH_SOURCE[0]}") == "$stage/setup.sh" ]] \
    || die "invalid staging directory"
  local SRC="$stage"

  TARGET_USER="${SUDO_USER:-}"
  [[ -n $TARGET_USER && $TARGET_USER != root ]] || die "must be run via sudo from your own user (SUDO_USER unset)"
  local TARGET_HOME TARGET_UID PLUGIN_DIR HYPR_SIG
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  TARGET_UID="$(id -u "$TARGET_USER")"
  PLUGIN_DIR="$TARGET_HOME/.config/omarchy/plugins/$PLUGIN_ID"

  # sudo resets the environment, so rebuild what the user session commands need:
  # Omarchy's bin dir, the user bus, and the running Hyprland instance.
  HYPR_SIG="$(ls -1 "/run/user/$TARGET_UID/hypr" 2>/dev/null | head -n1 || true)"
  as_user() {
    sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" XDG_RUNTIME_DIR="/run/user/$TARGET_UID" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus" \
      HYPRLAND_INSTANCE_SIGNATURE="$HYPR_SIG" OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}" \
      PATH="$TARGET_HOME/.local/bin:${OMARCHY_PATH:-/usr/share/omarchy}/bin:$PATH" "$@"
  }

  local family
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
  # /dev/uinput is a static node until the module loads; load it now and at boot
  # so udev actually processes the device and applies the uaccess rule.
  printf 'uinput\n' >/etc/modules-load.d/vivobook.conf
  modprobe uinput || true
  udevadm control --reload
  udevadm trigger --subsystem-match=hidraw --subsystem-match=misc --subsystem-match=input --action=change

  step "Installing charge limit helper"
  install -Dm755 "$SRC/system/vivobook-charge" /usr/local/libexec/vivobook-charge
  # Validate the sudoers entry before it can take effect; a bad file here locks sudo.
  local sudoers_tmp
  sudoers_tmp="$(mktemp "$stage/sudoers.XXXXXX")"
  printf '%s ALL=(root) NOPASSWD: /usr/local/libexec/vivobook-charge\n' "$TARGET_USER" >"$sudoers_tmp"
  visudo -cf "$sudoers_tmp" >/dev/null || die "generated sudoers entry is invalid"
  install -Dm440 "$sudoers_tmp" /etc/sudoers.d/vivobook
  install -Dm644 "$SRC/system/vivobook-charge.service" /etc/systemd/system/vivobook-charge.service
  systemctl daemon-reload
  systemctl enable vivobook-charge.service >/dev/null 2>&1 || true
  local current_limit
  current_limit="$(cat /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/dev/null || echo 100)"
  if [[ ! -f /etc/vivobook/charge-limit ]]; then
    case "$current_limit" in 60|80|100) /usr/local/libexec/vivobook-charge "$current_limit" ;; esac
  fi

  step "Installing resume hook"
  install -Dm755 "$SRC/system/vivobook-sleep" /usr/lib/systemd/system-sleep/vivobook

  step "Installing root-owned uninstaller"
  install -Dm755 "$SRC/system/vivobook-uninstall" /usr/local/libexec/vivobook/uninstall
  install -d -m755 /etc/vivobook
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$SRC/manifest.json" \
    >/etc/vivobook/setup-version

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
  local menu="$TARGET_HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
  if [[ -f $menu ]] && ! grep -q "vivobook:begin" "$menu"; then
    as_user python3 -c '
import sys
path, snippet = sys.argv[1], sys.argv[2]
text = open(path).read()
block = "  // vivobook:begin\n" + snippet.rstrip("\n") + "\n  // vivobook:end\n"
idx = text.rstrip().rfind("}")
if idx < 0:
    sys.exit("menu file has no closing brace")
open(path, "w").write(text[:idx] + block + text[idx:])
' "$menu" "$(<"$SRC/system/menu.jsonc")"
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

To remove everything later: sudo /usr/local/libexec/vivobook/uninstall
MSG
}

main() {
  [[ $EUID -eq 0 ]] || die "run with sudo: sudo $0"

  if [[ ${1:-} == --staged ]]; then
    install_system "${2:?}"
    return
  fi

  local expect="" assume_yes=0
  while (($#)); do
    case "$1" in
      --expect) expect="${2:?--expect needs a sha256 digest}"; shift 2 ;;
      --yes) assume_yes=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ -z $expect || $expect =~ ^[0-9a-f]{64}$ ]] || die "--expect must be a lowercase sha256 hex digest"

  local src
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  stage_and_exec "$src" "$expect" "$assume_yes"
}

main "$@"
