#!/usr/bin/env python3
"""Apply monitor rules without transient overlaps.

A swap (A at 0, B at 2560 -> A at 2560, B at 0) cannot be done in one step
without one display briefly sitting on top of the other. Hyprland warns
"Monitor X overlaps with other monitor(s)" when that happens, even though the
final layout is fine. This helper moves a display out of the way first, then
applies the rules in an order that never overlaps.
"""

import json
import re
import subprocess
import sys
from typing import NoReturn

NAME_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
# A quote, backslash or control character would end the Lua string literal
# that name, mode and position are interpolated into.
LUA_UNSAFE = re.compile(r'["\\\x00-\x1f\x7f]')


def fail(message: str) -> NoReturn:
    print(f"apply-order: {message}", file=sys.stderr)
    sys.exit(2)


def parse_mode(mode):
    if mode == "preferred":
        return None
    try:
        resolution, refresh = str(mode).split("@", 1)
        width, height = resolution.split("x", 1)
        return int(width), int(height), float(refresh)
    except (TypeError, ValueError):
        fail(f"invalid mode: {mode}")


def overlaps(a, b):
    if a is None or b is None:
        return False
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah


def footprint(width, height, scale, transform):
    # Rules and hyprctl both carry the mode's pixel size, so a 90/270 degree
    # rotation swaps the on-screen footprint the overlap math needs.
    # int(x + 0.5) matches Math.round() in Model.js; round() would bank.
    if transform % 2 == 1:
        width, height = height, width
    return max(1, int(width / scale + 0.5)), max(1, int(height / scale + 0.5))


def eval_lua(expression):
    try:
        result = subprocess.run(
            ["hyprctl", "eval", expression],
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        fail(f"hyprctl not found: {exc}")
    output = (result.stdout or "").strip()
    error = (result.stderr or "").strip()
    if result.returncode != 0:
        return False, error or output or f"exit {result.returncode}"
    if output and output != "ok":
        return False, output
    return True, ""


def monitor_rule(name, mode, position, scale, transform):
    return (
        'hl.monitor({ output = "%s", mode = "%s", position = "%s", '
        'scale = %s, transform = %d })'
        % (name, mode, position, scale, transform)
    )


def main():
    if len(sys.argv) < 2:
        fail("missing rules")

    try:
        rules = json.loads(sys.argv[1])
    except (TypeError, ValueError):
        fail("invalid rules JSON")

    if not isinstance(rules, list) or not rules:
        fail("empty rules")

    try:
        raw = subprocess.run(
            ["hyprctl", "-j", "monitors", "all"],
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        fail(f"hyprctl not found: {exc}")
    if raw.returncode != 0:
        fail("cannot read the current monitor layout")
    try:
        monitors = json.loads(raw.stdout or "[]")
    except (TypeError, ValueError):
        fail("invalid monitor JSON")

    current = {}
    for monitor in monitors:
        if isinstance(monitor, dict) and monitor.get("name"):
            current[str(monitor["name"])] = monitor

    targets = []
    for rule in rules:
        if not isinstance(rule, dict) or not rule.get("name"):
            continue
        name = str(rule["name"])
        if not NAME_PATTERN.fullmatch(name):
            fail(f"invalid monitor name: {name!r}")

        if rule.get("disabled") is True:
            targets.append({"name": name, "disabled": True, "rule": rule})
            continue

        mode = str(rule.get("mode", ""))
        position = str(rule.get("position", ""))
        for field, value in (("mode", mode), ("position", position)):
            if LUA_UNSAFE.search(value):
                fail(f"invalid {field}: {value!r}")

        parsed = parse_mode(mode)
        if parsed is None:
            fail(f"preferred mode needs a resolution for {name}")
        mode_width, mode_height, mode_refresh = parsed

        scale_value = rule.get("scale", 1)
        if scale_value is None:
            scale_value = 1
        try:
            scale = float(scale_value)
            position_x, position_y = [
                int(value) for value in position.split("x", 1)
            ]
            transform = int(rule.get("transform", 0) or 0)
        except (TypeError, ValueError):
            fail(f"invalid geometry for {name}")

        if scale <= 0:
            fail(f"invalid scale for {name}")

        width, height = footprint(mode_width, mode_height, scale, transform)

        targets.append(
            {
                "name": name,
                "disabled": False,
                "rule": rule,
                "mode": mode,
                "x": position_x,
                "y": position_y,
                "mode_width": mode_width,
                "mode_height": mode_height,
                "mode_refresh": mode_refresh,
                "w": width,
                "h": height,
                "scale": scale,
                "transform": transform,
            }
        )

    errors = []

    # Disable first: a display that is leaving the layout must not block the
    # others while they move.
    disabled_names = {target["name"] for target in targets if target["disabled"]}
    for target in targets:
        if not target["disabled"]:
            continue
        name = target["name"]
        monitor = current.get(name)
        if monitor and monitor.get("disabled") is True:
            continue
        ok, error = eval_lua(
            'hl.monitor({ output = "%s", disabled = true })' % name
        )
        if ok:
            if monitor:
                monitor["disabled"] = True
        else:
            errors.append(f"{name}: {error}")

    def at_target(target):
        monitor = current.get(target["name"])
        if not monitor or monitor.get("disabled") is True:
            return False
        if int(monitor.get("x", 0)) != target["x"]:
            return False
        if int(monitor.get("y", 0)) != target["y"]:
            return False
        if abs(float(monitor.get("scale", 1)) - target["scale"]) > 0.0001:
            return False
        if int(monitor.get("transform", 0)) != target["transform"]:
            return False
        # hyprctl's width/height are the mode's pixel size whatever the
        # rotation, which is exactly what the rule's mode spells out.
        if int(monitor.get("width", 0)) != target["mode_width"]:
            return False
        if int(monitor.get("height", 0)) != target["mode_height"]:
            return False
        if abs(float(monitor.get("refreshRate", 0)) - target["mode_refresh"]) > 0.005:
            return False
        return True

    enabled = [target for target in targets if not target["disabled"]]
    positions = {}
    pending = []

    for target in enabled:
        monitor = current.get(target["name"])
        if monitor and monitor.get("disabled") is not True:
            scale = float(monitor.get("scale", 1) or 1)
            width, height = footprint(
                int(monitor.get("width", 1)),
                int(monitor.get("height", 1)),
                scale,
                int(monitor.get("transform", 0) or 0),
            )
            positions[target["name"]] = (
                int(monitor.get("x", 0)),
                int(monitor.get("y", 0)),
                width,
                height,
            )
        else:
            positions[target["name"]] = None

        if at_target(target):
            positions[target["name"]] = (
                target["x"],
                target["y"],
                target["w"],
                target["h"],
            )
        else:
            pending.append(target)

    def target_rect(target):
        return (target["x"], target["y"], target["w"], target["h"])

    def safe_now(target):
        rect = target_rect(target)
        for name, other in positions.items():
            if name == target["name"] or other is None:
                continue
            if name in disabled_names:
                continue
            if overlaps(rect, other):
                return False
        return True

    def apply_target(target):
        return eval_lua(
            monitor_rule(
                target["name"],
                target["mode"],
                f'{target["x"]}x{target["y"]}',
                target["scale"],
                target["transform"],
            )
        )

    parked = set()
    guard = 0
    while pending and guard < 10 * len(enabled) + 10:
        guard += 1

        chosen = None
        for target in pending:
            if safe_now(target):
                chosen = target
                break

        if chosen is not None:
            ok, error = apply_target(chosen)
            if not ok:
                errors.append(f"{chosen['name']}: {error}")
            else:
                positions[chosen["name"]] = (
                    chosen["x"],
                    chosen["y"],
                    chosen["w"],
                    chosen["h"],
                )
            pending.remove(chosen)
            continue

        # Every remaining move would land on a monitor that is still in the
        # way. Park one to the right of the entire layout, then continue.
        candidate = next(
            (target for target in pending if target["name"] not in parked), None
        )
        if candidate is None:
            # Everything that can be parked has been parked and no target is
            # clear. The target layout itself overlaps; apply it directly and
            # let Hyprland report it rather than moving displays forever.
            candidate = pending[0]
            ok, error = apply_target(candidate)
            if not ok:
                errors.append(f"{candidate['name']}: {error}")
            pending.remove(candidate)
            continue

        right_edges = [
            rect[0] + rect[2] for rect in positions.values() if rect is not None
        ]
        right_edges += [target["x"] + target["w"] for target in enabled]
        park_x = max(right_edges) + 200

        ok, error = eval_lua(
            monitor_rule(
                candidate["name"],
                candidate["mode"],
                f"{park_x}x0",
                candidate["scale"],
                candidate["transform"],
            )
        )
        if not ok:
            errors.append(f"{candidate['name']}: {error}")
            pending.remove(candidate)
            continue

        positions[candidate["name"]] = (
            park_x,
            0,
            candidate["w"],
            candidate["h"],
        )
        parked.add(candidate["name"])

    if errors:
        for error in errors:
            print(f"apply-order: {error}", file=sys.stderr)
        sys.exit(1)

    print("ok")


if __name__ == "__main__":
    main()
