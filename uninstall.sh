#!/bin/bash
# Thin wrapper: root only ever runs the root-owned uninstaller that setup.sh installed.
# Prefer calling it directly: sudo /usr/local/libexec/vivobook/uninstall
set -euo pipefail
target=/usr/local/libexec/vivobook/uninstall
if [[ ! -x $target ]]; then
  echo "$target not found. Re-run setup.sh once to install it (it is root-owned), then uninstall." >&2
  exit 1
fi
exec "$target" "$@"
