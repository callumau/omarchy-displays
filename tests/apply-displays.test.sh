#!/bin/bash
# --live-only must move displays but leave monitors.conf alone.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/home/.config/hypr"
printf 'monitor=KEEP_ME\n' > "$tmp/home/.config/hypr/monitors.conf"

cat > "$tmp/bin/hyprctl" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
if args[:3] == ["-j", "monitors", "all"]:
    print(json.dumps([
        {
            "name": "A", "description": "Monitor A", "width": 2560,
            "height": 1440, "refreshRate": 59.951, "x": 0, "y": 0,
            "scale": 1, "transform": 0, "disabled": False, "focused": True
        },
        {
            "name": "B", "description": "Monitor B", "width": 2560,
            "height": 1440, "refreshRate": 59.951, "x": 2560, "y": 0,
            "scale": 1, "transform": 0, "disabled": False, "focused": False
        }
    ]))
    sys.exit(0)

if args[:1] == ["eval"]:
    with open(os.environ["EVAL_LOG"], "a") as log:
        log.write(args[1] + "\n")
    print("ok")
    sys.exit(0)

sys.exit(1)
PY
chmod +x "$tmp/bin/hyprctl"

export PATH="$tmp/bin:$PATH"
export EVAL_LOG="$tmp/eval.log"
export HOME="$tmp/home"

payload='[{"name":"A","identity":"Monitor A","description":"Monitor A","mode":"2560x1440@59.95","position":"2560x0","scale":1,"transform":0,"disabled":false},{"name":"B","identity":"Monitor B","description":"Monitor B","mode":"2560x1440@59.95","position":"0x0","scale":1,"transform":0,"disabled":false}]'

bash "$script_dir/../apply-displays.sh" "$payload" --live-only >/dev/null
test -s "$EVAL_LOG"
grep -q '^monitor=KEEP_ME$' "$HOME/.config/hypr/monitors.conf"
test ! -f "$HOME/.config/omarchy/monitor-presets.json"

: > "$EVAL_LOG"
bash "$script_dir/../apply-displays.sh" "$payload" --remember >/dev/null
test -s "$EVAL_LOG"
grep -q '^monitor=desc:Monitor A' "$HOME/.config/hypr/monitors.conf"
grep -q '^monitor=desc:Monitor B' "$HOME/.config/hypr/monitors.conf"
test -s "$HOME/.config/omarchy/monitor-presets.json"

echo "apply-displays tests passed"
