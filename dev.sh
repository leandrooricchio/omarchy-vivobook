#!/bin/bash
# Sync this checkout into the live Omarchy plugin directory.
# Symlinks are rejected by `omarchy plugin validate`, so a copy is used.
#   ./dev.sh          sync once and validate
#   ./dev.sh --watch  keep syncing on every save (shell hot-reloads QML)
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$SRC/manifest.json")"
DEST="$HOME/.config/omarchy/plugins/$ID"

sync() {
  mkdir -p "$DEST"
  rsync -a --delete --exclude .git --exclude dev.sh --exclude __pycache__ "$SRC/" "$DEST/"
  omarchy plugin validate "$DEST" && echo "synced -> $DEST"
}

sync
if [[ ${1:-} == "--watch" ]]; then
  echo "watching $SRC (Ctrl-C to stop)"
  inotifywait -m -r -q -e close_write,create,delete,move --exclude '(\.git|__pycache__|\.swp$)' "$SRC" |
    while read -r _; do sync; done
fi
