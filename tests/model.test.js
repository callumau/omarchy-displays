const assert = require("node:assert")
const Model = require("../Model.js")

const monitors = Model.parseMonitors(JSON.stringify([
  {
    name: "DP-7",
    description: "Dell Inc. DELL S2721DGF DHSBW13",
    width: 2560,
    height: 1440,
    x: 2560,
    y: 0,
    scale: 1,
    refreshRate: 59.951,
    transform: 0,
    disabled: false,
    focused: true,
    availableModes: [
      "2560x1440@59.95Hz",
      "2560x1440@120.00Hz",
      "1920x1080@60.00Hz"
    ]
  },
  {
    name: "DP-11",
    description: "Dell Inc. DELL S2721DGF 75K7DH3",
    width: 2560,
    height: 1440,
    x: 0,
    y: 0,
    scale: 1,
    refreshRate: 59.951,
    transform: 0,
    disabled: false,
    focused: false,
    availableModes: ["2560x1440@143.91Hz", "2560x1440@59.95Hz"]
  },
  {
    name: "eDP-1",
    description: "BOE 0x0BCA",
    width: 2256,
    height: 1504,
    x: 5120,
    y: 0,
    scale: 2,
    refreshRate: 59.999,
    transform: 0,
    disabled: true,
    focused: false,
    availableModes: ["2256x1504@60.00Hz"]
  }
]))

assert.equal(monitors.length, 3)
assert.equal(monitors[0].identity, "Dell Inc. DELL S2721DGF DHSBW13")
assert.equal(monitors[0].pendingResolution, "2560x1440")
assert.equal(monitors[0].pendingRefresh, "59.95")
assert.equal(monitors[2].logicalWidth, 1128)
assert.deepEqual(Model.comboMonitors(monitors), [
  "BOE 0x0BCA",
  "Dell Inc. DELL S2721DGF 75K7DH3",
  "Dell Inc. DELL S2721DGF DHSBW13"
])
assert.deepEqual(Model.resolutionsFor(monitors[0].availableModes), [
  "2560x1440",
  "1920x1080"
])
assert.deepEqual(Model.refreshRatesFor(monitors[0].availableModes, "2560x1440"), [
  "120",
  "59.95"
])
assert.equal(Model.nearestRefresh(monitors[0].availableModes, "2560x1440", 60), "59.95")
assert.equal(Model.anyOverlap(monitors), false)

// Pending resolution changes enlarge the target rectangle even before Apply.
const wider = Object.assign({}, monitors[0], { x: 2000, layoutWidth: 3200 })
assert.equal(Model.overlaps(wider, monitors[1]), true)
assert.equal(Model.overlaps(monitors[0], monitors[1]), false)

const preset = {
  monitors: [
    "Dell Inc. DELL S2721DGF 75K7DH3",
    "Dell Inc. DELL S2721DGF DHSBW13"
  ],
  layout: [
    {
      identity: "Dell Inc. DELL S2721DGF 75K7DH3",
      name: "DP-11",
      disabled: false,
      mode: "2560x1440@59.95",
      position: "0x0",
      scale: 1,
      transform: 0
    },
    {
      identity: "Dell Inc. DELL S2721DGF DHSBW13",
      name: "DP-7",
      disabled: false,
      mode: "2560x1440@59.95",
      position: "2560x0",
      scale: 1,
      transform: 0
    }
  ],
  updated: "2026-01-01T00:00:00Z"
}

assert.equal(Model.bestPreset([preset], monitors), preset)
assert.equal(Model.layoutMatchesPreset(preset, monitors), true)

const rules = Model.presetRules(preset, monitors)
assert.equal(rules.length, 3)
assert.equal(rules.find(rule => rule.name === "DP-7").position, "2560x0")
assert.equal(rules.find(rule => rule.name === "DP-11").position, "0x0")
assert.equal(rules.find(rule => rule.name === "eDP-1").disabled, true)

// A monitor the preset has never seen packs to the right of the saved layout.
const extra = monitors.concat([{
  name: "HDMI-A-1",
  description: "New Panel",
  identity: "New Panel",
  enabled: true,
  pendingResolution: "1920x1080",
  pendingRefresh: "60",
  scale: 1,
  transform: 0,
  layoutWidth: 1920,
  layoutHeight: 1080,
  x: 9000,
  y: 0
}])
const extraRules = Model.presetRules(preset, extra)
assert.equal(extraRules.find(rule => rule.name === "HDMI-A-1").position, "5120x0")

// A preset whose target mode is wider than the current one reserves the new width.
const widePreset = {
  monitors: ["Dell Inc. DELL S2721DGF 75K7DH3"],
  layout: [{
    identity: "Dell Inc. DELL S2721DGF 75K7DH3",
    name: "DP-11",
    disabled: false,
    mode: "3840x2160@60",
    position: "0x0",
    scale: 1,
    transform: 0
  }]
}
const wideRules = Model.presetRules(widePreset, [monitors[1], extra[3]])
assert.equal(wideRules.find(rule => rule.name === "HDMI-A-1").position, "3840x0")

// Bad input is ignored rather than displayed or applied.
assert.deepEqual(Model.parseMonitors("not json"), [])
assert.deepEqual(Model.parseMonitors(JSON.stringify([
  { name: "<img src=x>", width: 1, height: 1 }
])), [])
assert.equal(Model.parseModeString("2560x1440@59.95").refresh, "59.95")
assert.equal(Model.parseModeString("2560x1440@59.95Hz").refresh, "59.95")

// Overlap uses the target (pending) size.
const a = { x: 0, y: 0, enabled: true, layoutWidth: 3000, layoutHeight: 1440 }
const b = { x: 2560, y: 0, enabled: true, layoutWidth: 2560, layoutHeight: 1440 }
assert.equal(Model.overlaps(a, b), true)
b.x = 3000
assert.equal(Model.overlaps(a, b), false)
assert.equal(Model.freePosition([a, b], "other").x, 5560)

// hyprctl reports the mode's pixel size, so a 90 degree rotation swaps the
// footprint: a portrait panel beside a landscape one is adjacent, not
// overlapping.
const rotated = Model.parseMonitors(JSON.stringify([
  {
    name: "DP-1",
    description: "Portrait",
    width: 2560,
    height: 1440,
    x: 0,
    y: 0,
    scale: 1,
    refreshRate: 60,
    transform: 1
  },
  {
    name: "DP-2",
    description: "Landscape",
    width: 2560,
    height: 1440,
    x: 1440,
    y: 0,
    scale: 1,
    refreshRate: 60,
    transform: 0
  }
]))
assert.equal(rotated[0].layoutWidth, 1440)
assert.equal(rotated[0].layoutHeight, 2560)
assert.equal(Model.anyOverlap(rotated), false)

// Packing an unseen monitor beside a rotated preset entry reserves its narrow
// side.
const portraitPreset = {
  monitors: ["Portrait"],
  layout: [{
    identity: "Portrait",
    name: "DP-1",
    disabled: false,
    mode: "2560x1440@60",
    position: "0x0",
    scale: 1,
    transform: 1
  }],
  updated: "2026-01-01T00:00:00Z"
}
const unseen = {
  name: "HDMI-A-1",
  description: "New Panel",
  identity: "New Panel",
  enabled: true,
  pendingResolution: "1920x1080",
  pendingRefresh: "60",
  scale: 1,
  transform: 0,
  layoutWidth: 1920,
  layoutHeight: 1080,
  x: 5000,
  y: 0
}
const portraitRules = Model.presetRules(portraitPreset, [rotated[0], unseen])
assert.equal(portraitRules.find(rule => rule.name === "HDMI-A-1").position, "1440x0")

console.log("model tests passed")
