#!/bin/bash
# Load gate: proves the widget actually instantiates in the running Omarchy shell.
#
# The unit tests here cover Model.js math and the helper scripts; none of them can
# catch a QML error that makes Quickshell drop the whole bar widget at load time
# (e.g. assigning a read-only property such as `implicitHeight` on a Loader).
# A plugin-directory hot reload does NOT reproduce these: the bar only reports
# "Plugin widget ... failed" on a fresh shell start. So this syncs the working
# tree into the installed plugin dir, restarts the Omarchy shell, and fails if the
# shell logged a load failure for this plugin.
#
# Run before tagging a release. Requires a live Omarchy session; the bar blinks.

set -euo pipefail

ID="io.github.callumau.displays"
SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$HOME/.config/omarchy/plugins/$ID"

[[ -d "$TARGET" ]] || { echo "load-check: plugin not installed at $TARGET" >&2; exit 1; }

# Sync the working tree (minus .git) over the installed copy.
tar -C "$SOURCE" --exclude=.git -cf - . | tar -C "$TARGET" -xf -

START="$(date '+%Y-%m-%d %H:%M:%S')"
omarchy restart shell >/dev/null 2>&1
sleep 15

# Capture once: piping journalctl into `grep -q` would SIGPIPE it, and pipefail
# would then report "no match" for a successful match.
LOG="$(journalctl --user --since "$START" --no-pager 2>/dev/null || true)"

if grep -qE "Plugin (widget|service) $ID failed" <<<"$LOG"; then
  echo "load-check: FAILED — the shell rejected this plugin:" >&2
  grep -E "Plugin (widget|service) $ID failed" <<<"$LOG" >&2
  exit 1
fi

if ! grep -q "$ID" <<<"$LOG"; then
  echo "load-check: no shell activity for $ID — is the Omarchy shell running?" >&2
  exit 1
fi

echo "load-check: widget loaded cleanly"
