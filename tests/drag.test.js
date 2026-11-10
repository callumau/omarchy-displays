const assert = require("node:assert")
const Model = require("../Model.js")

function monitor(name, x, y, w, h, enabled) {
  return {
    name: name,
    description: name,
    identity: name,
    enabled: enabled !== false,
    x: x,
    y: y,
    scale: 1,
    transform: 0,
    layoutWidth: w,
    layoutHeight: h,
    logicalWidth: w,
    logicalHeight: h,
    pendingResolution: w + "x" + h,
    pendingRefresh: "60",
    availableModes: []
  }
}

function overlaps(result, target, other) {
  return Model.rectsOverlap(
    result.x, result.y, target.layoutWidth, target.layoutHeight,
    other.x, other.y, other.layoutWidth, other.layoutHeight
  )
}

function assertClean(monitors, name, result, label) {
  assert.ok(result !== null, label + ": expected a position, got null")
  const target = monitors.find(m => m.name === name)
  for (const other of monitors) {
    if (other.name === name || !other.enabled) continue
    assert.equal(overlaps(result, target, other), false,
      label + ": overlaps " + other.name)
  }
}

// Five monitors: three wide on top, two below on the left.
function fiveWide() {
  return [
    monitor("A", 0, 0, 2560, 1440),
    monitor("B", 2560, 0, 2560, 1440),
    monitor("C", 5120, 0, 2560, 1440),
    monitor("D", 0, 1440, 1920, 1080),
    monitor("E", 1920, 1440, 1920, 1080)
  ]
}

// Four monitors: 2x2 grid with mixed sizes.
function fourGrid() {
  return [
    monitor("A", 0, 0, 2560, 1440),
    monitor("B", 2560, 0, 1920, 1080),
    monitor("C", 0, 1440, 1920, 1080),
    monitor("D", 1920, 1440, 2560, 1440)
  ]
}

// The no-overlap invariant holds for every target dropped anywhere on a
// coarse grid over both layouts.
for (const makeLayout of [fiveWide, fourGrid]) {
  const monitors = makeLayout()
  for (const target of monitors) {
    // A regression that returned null everywhere would satisfy the invariant
    // below, so require a result where one must exist.
    assert.ok(Model.resolveDrag(monitors, target.name, target.x, target.y) !== null,
      target.name + " at its own position")
    for (let gx = -5120; gx <= 8448; gx += 640) {
      for (let gy = -2880; gy <= 4320; gy += 360) {
        const result = Model.resolveDrag(monitors, target.name, gx, gy)
        if (result === null) continue
        assertClean(monitors, target.name, result,
          target.name + " to " + gx + "," + gy)
      }
    }
  }
}
assert.ok(Model.resolveDrag(fiveWide(), "A", 8448, 0) !== null,
  "fiveWide: free spot right of the row")
assert.ok(Model.resolveDrag(fourGrid(), "D", 8448, 0) !== null,
  "fourGrid: free spot right of the grid")
console.log("drag sweep invariant passed")

// Edge snapping: near-adjacent positions snap exactly and report the axis.
{
  // Origin snap with free space at 0,0.
  const open = [monitor("A", 2560, 0, 2560, 1440)]
  const origin = Model.resolveDrag(open, "A", 10, -14)
  assert.equal(origin.x, 0)
  assert.equal(origin.y, 0)
  assert.equal(origin.snappedX, true)
  assert.equal(origin.snappedY, true)

  // Left-edge to right-edge adjacency.
  const pair = [monitor("A", 0, 0, 2560, 1440), monitor("C", 6000, 0, 2560, 1440)]
  const snapped = Model.resolveDrag(pair, "C", 2548, 12)
  assert.equal(snapped.x, 2560)
  assert.equal(snapped.snappedX, true)

  // Right-edge to right-edge alignment from below: C.left snaps to
  // A.right - C.width while its top snaps to A.bottom.
  const narrow = [monitor("A", 0, 0, 2560, 1440), monitor("C", 6000, 3000, 1280, 1440)]
  const aligned = Model.resolveDrag(narrow, "C", 1290, 1446)
  assert.equal(aligned.x, 1280)
  assert.equal(aligned.y, 1440)
  assert.equal(aligned.snappedX, true)
  assert.equal(aligned.snappedY, true)
}
console.log("drag snapping passed")

// Dragging B left through A slides it around instead of inside.
{
  const monitors = fiveWide()
  const through = Model.resolveDrag(monitors, "B", 100, 0)
  assertClean(monitors, "B", through, "B through A")
  // It must have been pushed fully out on one side.
  const b = monitors.find(m => m.name === "B")
  const moved = through.x + b.layoutWidth <= 0
    || through.x >= 2560
    || through.y + b.layoutHeight <= 0
    || through.y >= 1440
  assert.equal(moved, true, "B was pushed clear of A, got " + through.x + "," + through.y)
}
console.log("drag through-slide passed")

// Dragging D up through the row above lands it adjacent, never inside.
{
  const monitors = fiveWide()
  const up = Model.resolveDrag(monitors, "D", 300, 1400)
  assertClean(monitors, "D", up, "D up through A")
}
console.log("drag vertical slide passed")

// A monitor boxed in on all sides with no fitting gap stays put (null).
{
  const pocket = [
    monitor("S", -250, -250, 500, 500),
    monitor("L", -2150, -2150, 2000, 4300),
    monitor("R", 150, -2150, 2000, 4300),
    monitor("U", -2150, -2150, 4300, 2000),
    monitor("D", -2150, 150, 4300, 2000)
  ]
  assert.equal(Model.resolveDrag(pocket, "S", -200, -200), null)
  assert.equal(Model.resolveDrag(pocket, "S", 0, 0), null)
}
console.log("drag pocket passed")

// Disabled monitors are ignored by both snapping and collision.
{
  const monitors = [monitor("A", 0, 0, 2560, 1440), monitor("B", 2560, 0, 2560, 1440, false)]
  const result = Model.resolveDrag(monitors, "A", 3000, 0)
  assert.equal(result.x, 3000)
  assertClean(monitors, "A", result, "A over disabled B")
}

// A rotated panel's footprint comes from parseMonitors: a landscape panel
// dropped beside a portrait one lands next to it instead of being pushed down.
{
  const monitors = Model.parseMonitors(JSON.stringify([
    { name: "P", description: "Portrait", width: 2560, height: 1440, x: 0, y: 0, scale: 1, refreshRate: 60, transform: 1 },
    { name: "W", description: "Landscape", width: 2560, height: 1440, x: 1440, y: 0, scale: 1, refreshRate: 60, transform: 0 }
  ]))
  const beside = Model.resolveDrag(monitors, "W", 1440, 0)
  assertClean(monitors, "W", beside, "W beside portrait P")
  assert.equal(beside.x, 1440)
  assert.equal(beside.y, 0)
}

// Unknown or disabled targets, and bad input, resolve to null.
{
  const monitors = fiveWide()
  assert.equal(Model.resolveDrag(monitors, "Z", 0, 0), null)
  assert.equal(Model.resolveDrag(monitors, "A", NaN, 0), null)
  assert.equal(Model.resolveDrag("nope", "A", 0, 0), null)
  const disabled = fiveWide().map(m => m.name === "A" ? monitor("A", 0, 0, 2560, 1440, false) : m)
  assert.equal(Model.resolveDrag(disabled, "A", 100, 100), null)
}
console.log("drag edge cases passed")
console.log("drag tests passed")
