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

# Confirming a trial (--commit) writes config and preset but makes no live calls.
printf 'monitor=KEEP_ME\n' > "$HOME/.config/hypr/monitors.conf"
rm -f "$HOME/.config/omarchy/monitor-presets.json"
: > "$EVAL_LOG"
bash "$script_dir/../apply-displays.sh" "$payload" --commit >/dev/null
test ! -s "$EVAL_LOG"
grep -q '^monitor=desc:Monitor A' "$HOME/.config/hypr/monitors.conf"
test -s "$HOME/.config/omarchy/monitor-presets.json"

# Trial persistence survives a reload: save, re-read, then clear.
trial='{"pending":[{"name":"A"}],"previous":[{"name":"A"}],"deadline":1893456000000,"monitors":["A"]}'
bash "$script_dir/../apply-displays.sh" "$trial" --save-trial >/dev/null
test -s "$HOME/.config/omarchy/.monitor-trial.json"
grep -q '"deadline":1893456000000' "$HOME/.config/omarchy/.monitor-trial.json"
bash "$script_dir/../apply-displays.sh" --clear-trial >/dev/null
test ! -e "$HOME/.config/omarchy/.monitor-trial.json"

# Bad trial payloads are refused.
if bash "$script_dir/../apply-displays.sh" '{"pending":[]}' --save-trial >/dev/null 2>&1; then
  echo "bad trial payload was accepted" >&2
  exit 1
fi

# Rules that would break monitors.conf or the generated Lua are refused before
# monitors.conf is written and before anything reaches the live layout.
conf="$HOME/.config/hypr/monitors.conf"
cp "$conf" "$tmp/monitors.conf.before"
reject() {
  local payload="$1" field="$2" err
  : > "$EVAL_LOG"
  if err=$(bash "$script_dir/../apply-displays.sh" "$payload" --remember 2>&1 >/dev/null); then
    echo "accepted invalid payload ($field): $payload" >&2
    exit 1
  fi
  grep -q "invalid $field" <<<"$err" || {
    echo "failure did not name $field: $err" >&2
    exit 1
  }
  test ! -s "$EVAL_LOG"
  cmp -s "$conf" "$tmp/monitors.conf.before" || {
    echo "monitors.conf changed while rejecting $field" >&2
    exit 1
  }
}

reject '[{"name":"DP-1\", disabled = true --","identity":"Hostile","description":"Hostile","mode":"2560x1440@59.95","position":"0x0","scale":1,"transform":0,"disabled":false}]' name
reject '[{"name":"DP 1","identity":"Hostile","description":"Hostile","mode":"2560x1440@59.95","position":"0x0","scale":1,"transform":0,"disabled":false}]' name
reject '[{"name":"DP-1","identity":"Hostile","description":"Dell \"wide\" panel","mode":"2560x1440@59.95","position":"0x0","scale":1,"transform":0,"disabled":false}]' description

# apply-order.py cannot apply these, so they must fail before the config write.
reject '[{"name":"DP-1","identity":"Hostile","description":"Hostile","mode":"preferred","position":"0x0","scale":1,"transform":0,"disabled":false}]' mode
reject '[{"name":"DP-1","identity":"Hostile","description":"Hostile","mode":"2560x1440@59.95","position":"auto","scale":1,"transform":0,"disabled":false}]' position

echo "apply-displays tests passed"
