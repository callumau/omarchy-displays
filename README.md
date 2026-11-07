# Displays for Omarchy

A monitor layout panel for the [Omarchy](https://omarchy.org/) shell. It extends
the built-in **Display** widget with a **Layout** tab for arranging screens,
choosing resolution and refresh rate, setting a primary display, and restoring
a saved layout whenever the same set of monitors is connected again.

Built with Quickshell/QML, Hyprland's Lua monitor API, and a small Python helper
for safe swaps.

## Features

- **Drag to arrange** displays on a visual canvas, with edge and origin snapping.
- **Auto** packs displays left to right; **Swap** reverses the order (the
  quickest fix when left and right are inverted).
- **Primary** moves the selected display to `0,0` and packs the rest to its
  right. The star marks the display at the origin.
- **Resolution** and **refresh rate** per display, read from Hyprland's
  available modes.
- **Apply** tests the layout live. A 15-second **Keep this layout?** prompt
  follows; if you do not confirm, the previous layout is restored
  automatically. Confirming writes the config and saves a preset for the exact
  set of connected displays.
- **Reload/Revert** re-reads the live layout or discards unsaved edits.
- **Automatic restore**: plugging a monitor back in restores the best matching
  saved layout without opening the panel.
- **No transient overlap warnings**: swapping two displays parks one out of the
  way first, so Hyprland never sees an in-between overlapping layout.

## Install

```bash
omarchy plugin add https://github.com/callumau/omarchy-displays.git --enable
```

The plugin installs as `io.github.callumau.displays`. `omarchy plugin add`
validates the manifest, copies the plugin into
`~/.config/omarchy/plugins/io.github.callumau.displays`, and enables it.

Manual install:

```bash
git clone https://github.com/callumau/omarchy-displays.git \
  ~/.config/omarchy/plugins/io.github.callumau.displays
omarchy plugin enable io.github.callumau.displays --section right
```

The plugin replaces the built-in `omarchy.monitor` widget while it is enabled.
Removing it restores the built-in widget.

## Usage

Open it from the monitor icon in the bar, with `Super + Ctrl + D`, or directly
on the Layout tab:

```bash
omarchy-shell io.github.callumau.displays.panel layout
```

### Display tab

The original brightness, text size, scale, and enable/disable controls remain.

### Layout tab

- Drag the display rectangles to arrange them.
- **Auto** packs enabled displays left to right in their current order.
- **Swap** reverses that order.
- **Primary** puts the selected display at `0,0`.
- Pick a **resolution** and **refresh rate** for the selected display.
- **Apply** tries the layout live. Confirm with **Keep** within 15 seconds, or
  it automatically restores the previous layout. Only **Keep** writes
  `monitors.conf` and saves the preset. The pending confirmation is recorded
  on disk, so even a shell restart mid-trial brings the prompt back (or
  reverts immediately if the countdown already expired) instead of stranding
  the trial layout.

> Hyprland has no separate "primary output" flag. Primary here means the
> display placed at the origin, `0,0`, which is how most apps and games pick
> their main output.

## Presets

Pressing **Keep** after an Apply saves the layout in:

```
~/.config/omarchy/monitor-presets.json
```

Presets are keyed by the monitors' EDID descriptions, not their connector
names, so a dock renaming `DP-7` to `DP-9` does not invalidate a saved layout.

A small service watches the connected monitor set. When displays are plugged
in or removed it picks the saved preset with the largest match and restores it.
Monitors the preset has never seen are packed to the right of the saved
arrangement, so a saved `A+B` layout still works when a third display appears.

Neither a trial Apply nor an automatic restore rewrites `monitors.conf`; only
an explicit **Keep** writes configuration. Saving a preset is the consent for
that layout to be restored when the same monitor set is connected again.

The file is plain JSON, capped at 32 entries (oldest dropped). Delete an entry
to forget that layout.

## Files

| Path | Purpose |
|------|---------|
| `Panel.qml` | Bar widget and Display/Layout panel |
| `Service.qml` | Watches monitor changes and restores presets |
| `Model.js` | Pure parsing, overlap, and preset-matching helpers |
| `apply-displays.sh` | Validates a layout, writes config, applies it live |
| `apply-order.py` | Orders swaps to avoid transient overlaps |
| `i18n/en.json` | Plugin-owned strings |
| `~/.config/hypr/monitors.conf` | Generated rules read by `monitors.lua` |
| `~/.config/hypr/monitors.conf.bak` | Previous generated file |
| `~/.config/omarchy/monitor-presets.json` | Saved layouts per monitor set |

The plugin never writes under `/usr/share/omarchy/`.

## Requirements

- Omarchy with the Quickshell shell (`omarchy-shell`)
- Hyprland with the Lua config provider
- `jq` and `hyprctl`
- Python 3 is optional: without it, layouts still apply, but swaps use a simple
  sequential order and may briefly overlap.

## Development

Validate the plugin folder with Omarchy itself:

```bash
omarchy plugin validate .
```

Run the local checks:

```bash
bash -n apply-displays.sh
python3 -m py_compile apply-order.py
node tests/model.test.js
bash tests/apply-order.test.sh
bash tests/apply-displays.test.sh
```

The shell and Python tests use a fake `hyprctl`, so they do not touch the
running compositor.

## Uninstall

```bash
omarchy plugin remove io.github.callumau.displays
```

This restores the built-in `omarchy.monitor` widget. Removal deletes only the
plugin folder; your own configuration files are left untouched on purpose:
`~/.config/hypr/monitors.conf` (plus its `.bak`), and
`~/.config/omarchy/monitor-presets.json`. Delete those manually if you want a
fully stock setup again.

## License

MIT. See [LICENSE](LICENSE).
