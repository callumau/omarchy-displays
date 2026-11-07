#!/bin/bash
# Apply and persist a monitor layout for the Displays shell plugin.
#
# Usage: apply-displays.sh '<rules-json>' [--remember|--dry-run|--live-only|--commit]
#
# The payload is a JSON array of rules:
#   { name, identity, description, mode, position, scale, transform, disabled }
#
# The script:
#   1. validates the payload,
#   2. rewrites ~/.config/hypr/monitors.conf (read by Omarchy's monitors.lua),
#   3. applies each rule live through Hyprland's Lua hl.monitor API,
#   4. with --remember, saves the layout keyed by the connected monitor set.
#
# --live-only applies the layout without touching monitors.conf or presets.
# The panel uses it to try a layout before the user confirms it, and the preset
# watcher uses it so automatic restores never overwrite user configuration.
#
# --commit writes monitors.conf and the preset without re-applying. The panel
# uses it when the user presses Keep in the post-Apply confirmation prompt.
# Only an explicit Keep (or a manual Apply with --remember) writes config.
#
# --save-trial '<trial-json>' records a pending confirmation so a shell or
# plugin reload mid-trial cannot strand the trial layout: on startup the panel
# resumes the countdown (or reverts immediately if the deadline passed).
# --clear-trial removes that record.

set -euo pipefail

fail() {
  echo "apply-displays: $*" >&2
  exit 2
}

payload="${1:-}"
action="${2:-}"

trial_file="$HOME/.config/omarchy/.monitor-trial.json"

if [[ $action == "--save-trial" || $payload == "--save-trial" ]]; then
  trial_json="$payload"
  if [[ $payload == "--save-trial" ]]; then
    trial_json="$action"
    action="--save-trial"
  fi
  [[ -n ${trial_json:-} && $trial_json != "--save-trial" ]] || fail "missing trial payload"
  jq -e '
    (.pending | type == "array" and length >= 1 and length <= 32)
    and (.previous | type == "array" and length >= 1 and length <= 32)
    and (.deadline | type == "number" and . > 0)
    and (.monitors | type == "array" and length >= 1)
  ' >/dev/null 2>&1 <<<"$trial_json" || fail "invalid trial payload"
  mkdir -p "$(dirname "$trial_file")"
  tmp_trial=$(mktemp "$(dirname "$trial_file")/.monitor-trial.XXXXXX")
  trap 'rm -f "${tmp_trial:-}"' EXIT
  jq -c '.version = 1' <<<"$trial_json" > "$tmp_trial"
  mv "$tmp_trial" "$trial_file"
  echo "ok trial saved"
  exit 0
fi

if [[ $action == "--clear-trial" || $payload == "--clear-trial" ]]; then
  rm -f "$trial_file"
  echo "ok trial cleared"
  exit 0
fi

[[ -n $payload ]] || fail "missing layout payload"
case "$action" in
  ""|--remember|--dry-run|--live-only|--commit) ;;
  *) fail "unknown option: $action" ;;
esac

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# The panel and the preset watcher can both apply at once (for example a
# hotplug while Apply is pressed). Serialize them so the last layout is whole.
if command -v flock >/dev/null 2>&1; then
  mkdir -p "$HOME/.config/omarchy"
  exec 9>"$HOME/.config/omarchy/.monitor-layout.lock"
  flock 9
fi

jq -e . >/dev/null 2>&1 <<<"$payload" || fail "payload is not valid JSON"

VALIDATE_JQ='
def valid_name: type == "string" and test("^[A-Za-z0-9._:-]{1,64}$");
def valid_identity:
  type == "string" and length > 0 and length <= 256 and (test("[[:cntrl:]]") | not);
def valid_description:
  type == "string" and length <= 256 and (test("[[:cntrl:]]") | not);
def valid_mode:
  type == "string" and test("^(preferred|[0-9]{2,5}x[0-9]{2,5}@[0-9]{1,3}(\\.[0-9]+)?)$");
def valid_position:
  type == "string" and test("^(auto|-?[0-9]{1,6}x-?[0-9]{1,6})$");
def valid_rule:
  (.name | valid_name)
  and (.identity | valid_identity)
  and ((.description // "") | valid_description)
  and (
    if .disabled == true then true
    else
      (.mode | valid_mode)
      and (.position | valid_position)
      and (.scale | type == "number" and . >= 0.1 and . <= 10)
      and (.transform | type == "number" and . == floor and . >= 0 and . <= 7)
    end
  );
if (type == "array" and length >= 1 and length <= 32 and all(.[]; valid_rule))
then . else error("invalid monitor layout payload") end
'

jq -e "$VALIDATE_JQ" >/dev/null 2>&1 <<<"$payload" \
  || fail "invalid monitor layout payload"

CONFIG_JQ='
def output_label:
  if ((.description // "") != "" and ((.description | test(",")) | not))
  then "desc:" + .description
  else .name
  end;
.[] |
if .disabled == true then
  "monitor=" + output_label + ",disable"
else
  "monitor=" + output_label + "," + .mode + "," + .position + ","
  + (.scale | tostring) + "," + (.transform | tostring)
end
'

LUA_JQ='
def lua_rule:
  if .disabled == true then
    "hl.monitor({ output = \"" + .name + "\", disabled = true })"
  else
    "hl.monitor({ output = \"" + .name + "\", mode = \"" + .mode
    + "\", position = \"" + .position + "\", scale = " + (.scale | tostring)
    + ", transform = " + (.transform | tostring) + " })"
  end;
sort_by(if .disabled == true then 0 else 1 end) | .[] | lua_rule
'

remember_layout() {
  local presets_dir="$HOME/.config/omarchy"
  local presets="$presets_dir/monitor-presets.json"
  mkdir -p "$presets_dir"

  local entry
  entry=$(jq -c '{
    monitors: ([.[].identity] | sort | unique),
    layout: [.[] | {
      identity: .identity,
      name: .name,
      description: (.description // ""),
      disabled: (.disabled == true),
      mode: (.mode // null),
      position: (.position // null),
      scale: (.scale // null),
      transform: (.transform // null)
    }],
    updated: (now | todate)
  }' <<<"$payload")

  local existing='{"version":1,"presets":[]}'
  if [[ -f $presets ]]; then
    existing=$(cat "$presets")
  fi
  if ! jq -e '.presets | type == "array"' >/dev/null 2>&1 <<<"$existing"; then
    existing='{"version":1,"presets":[]}'
  fi

  presets_tmp=$(mktemp "$presets_dir/.monitor-presets.XXXXXX")
  jq --argjson entry "$entry" '
    .version = 1
    | .presets = (([.presets[]? | select(.monitors != $entry.monitors)] + [$entry])
        | sort_by(.updated) | .[-32:])
  ' <<<"$existing" > "$presets_tmp"
  mv "$presets_tmp" "$presets"
  presets_tmp=""

  if [[ $action == "--commit" ]]; then
    echo "ok committed"
  else
    echo "ok remembered"
  fi
}

conf_dir="$HOME/.config/hypr"
conf="$conf_dir/monitors.conf"

tmp=""
presets_tmp=""
trap 'rm -f "${tmp:-}" "${presets_tmp:-}"' EXIT

if [[ $action != "--live-only" ]]; then
  mkdir -p "$conf_dir"
  tmp=$(mktemp "$conf_dir/.monitors.conf.XXXXXX")

  {
    echo "# Generated by the Displays shell plugin."
    echo "# Confirming a layout with Keep in the panel writes this file."
    echo
    jq -r "$CONFIG_JQ" <<<"$payload"
    echo
    echo "# Fallback for unknown monitors"
    echo "monitor=,preferred,auto,1"
  } > "$tmp"

  if [[ $action == "--dry-run" ]]; then
    cat "$tmp"
    echo
    echo "# live rules"
    jq -r "$LUA_JQ" <<<"$payload"
    exit 0
  fi

  if [[ -f $conf ]]; then
    cp -f "$conf" "$conf.bak"
  fi
  mv "$tmp" "$conf"
  tmp=""
fi

if [[ $action != "--commit" ]]; then
  failures=0
  if command -v python3 >/dev/null 2>&1 && [[ -f $script_dir/apply-order.py ]]; then
    # Moves a display out of the way first when a swap would briefly overlap,
    # so Hyprland does not warn about an incorrect layout in between.
    if ! python3 "$script_dir/apply-order.py" "$payload" >/dev/null; then
      failures=1
    fi
  else
    while IFS= read -r expression; do
      [[ -n $expression ]] || continue
      output=$(hyprctl eval "$expression" 2>&1) || {
        echo "hyprctl eval failed: $output" >&2
        failures=$((failures + 1))
        continue
      }
      if [[ -n $output && $output != "ok" ]]; then
        echo "hyprctl eval: $output" >&2
        failures=$((failures + 1))
      fi
    done < <(jq -r "$LUA_JQ" <<<"$payload")
  fi

  if (( failures > 0 )); then
    if [[ $action == "--live-only" ]]; then
      echo "live monitor update failed" >&2
    else
      echo "layout saved, but the live monitor update failed" >&2
    fi
    exit 1
  fi
fi

if [[ $action == "--remember" || $action == "--commit" ]]; then
  remember_layout
else
  echo "ok"
fi
