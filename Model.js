function clampBrightness(value) {
  var n = Number(value)
  if (!isFinite(n)) return 1
  return Math.max(1, Math.min(100, Math.round(n)))
}

function normalizeScale(scale) {
  var n = parseFloat(String(scale || ""))
  if (!isFinite(n)) return ""
  return String(Math.round(n * 100) / 100)
}

function gcd(a, b) {
  while (b) {
    var remainder = a % b
    a = b
    b = remainder
  }
  return a
}

function cleanScale(scale, width, height) {
  var requested = Number(scale)
  var modeWidth = Number(width)
  var modeHeight = Number(height)
  if (!isFinite(requested) || !isFinite(modeWidth) || !isFinite(modeHeight)
      || requested <= 0 || modeWidth <= 0 || modeHeight <= 0) return ""

  var divisor = gcd(Math.round(modeWidth * 120), Math.round(modeHeight * 120))
  var scaleUnits = Math.round(requested * 120)
  if (scaleUnits > divisor) scaleUnits = divisor
  while (divisor % scaleUnits !== 0) scaleUnits++
  return normalizeScale(scaleUnits / 120)
}

function matchingScaleIndex(scales, currentScale, width, height) {
  var current = Number(currentScale)
  if (!Array.isArray(scales) || !isFinite(current)) return -1

  var bestIndex = -1
  var bestDistance = Infinity
  var normalizedCurrent = normalizeScale(current)
  for (var i = 0; i < scales.length; i++) {
    if (cleanScale(scales[i], width, height) !== normalizedCurrent) continue

    var distance = Math.abs(Number(scales[i]) - current)
    if (distance < bestDistance) {
      bestIndex = i
      bestDistance = distance
    }
  }
  return bestIndex
}

function availableScales(scales, width, height) {
  if (!Array.isArray(scales) || Number(width) <= 0 || Number(height) <= 0) return scales || []

  var byEffectiveScale = {}
  for (var i = 0; i < scales.length; i++) {
    var requested = Number(scales[i])
    var effective = Number(cleanScale(requested, width, height))

    if (!isFinite(requested) || !isFinite(effective)) continue

    var key = normalizeScale(effective)
    var existing = byEffectiveScale[key]
    if (!existing || Math.abs(requested - effective) < existing.distance) {
      byEffectiveScale[key] = {
        value: String(scales[i]),
        index: i,
        distance: Math.abs(requested - effective)
      }
    }
  }

  return Object.keys(byEffectiveScale)
    .map(function(key) { return byEffectiveScale[key] })
    .sort(function(a, b) { return a.index - b.index })
    .map(function(candidate) { return candidate.value })
}

// tr is an optional translate(key, english) from the QML side (I18n.t);
// without it the English text stands, which is what the Node tests assert.
function brightnessName(percent, tr) {
  var t = typeof tr === "function" ? tr : function(key, english) { return english }
  var p = Math.round(percent)
  if (p >= 95) return t("monitor.level.sunBlast", "Sun blast")
  if (p >= 80) return t("monitor.level.solarFlare", "Solar flare")
  if (p >= 65) return t("monitor.level.goldenHour", "Golden hour")
  if (p >= 45) return t("monitor.level.evenDay", "Even day")
  if (p >= 30) return t("monitor.level.softGlow", "Soft glow")
  if (p >= 20) return t("monitor.level.lampLight", "Lamp light")
  if (p >= 10) return t("monitor.level.candlelit", "Candlelit")
  return t("monitor.level.nightOwl", "Night owl")
}

function parseDisplays(raw) {
  var displays = []
  try {
    displays = raw ? JSON.parse(String(raw)) : []
  } catch (e) {
    displays = []
  }
  if (!Array.isArray(displays)) displays = []

  var count = 0
  for (var i = 0; i < displays.length; i++) {
    if (displays[i] && displays[i].enabled) count++
  }

  return {
    displays: displays,
    enabledDisplayCount: count
  }
}

function clampInteger(value, min, max, fallback) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  n = Math.round(n)
  if (n < min) return min
  if (n > max) return max
  return n
}

function parseModeString(raw) {
  var match = /^(\d{2,5})x(\d{2,5})@(\d{1,3}(?:\.\d+)?)(?:Hz)?$/.exec(String(raw || ""))
  if (!match) return null
  return {
    width: parseInt(match[1], 10),
    height: parseInt(match[2], 10),
    refresh: String(Number(match[3])),
    raw: String(raw)
  }
}

function nearestRefresh(modes, resolution, refresh) {
  var target = Number(refresh)
  if (!Array.isArray(modes) || !isFinite(target)) return ""

  var best = ""
  var bestDistance = Infinity
  for (var i = 0; i < modes.length; i++) {
    var mode = modes[i]
    if (!mode || mode.width + "x" + mode.height !== resolution) continue
    var distance = Math.abs(Number(mode.refresh) - target)
    if (distance < bestDistance) {
      best = mode.refresh
      bestDistance = distance
    }
  }
  return best
}

function resolutionsFor(modes) {
  var seen = {}
  var out = []
  if (!Array.isArray(modes)) return out
  for (var i = 0; i < modes.length; i++) {
    var mode = modes[i]
    if (!mode) continue
    var resolution = mode.width + "x" + mode.height
    if (!seen[resolution]) {
      seen[resolution] = true
      out.push(resolution)
    }
  }
  return out
}

function refreshRatesFor(modes, resolution) {
  var seen = {}
  var out = []
  if (!Array.isArray(modes)) return out
  for (var i = 0; i < modes.length; i++) {
    var mode = modes[i]
    if (!mode || mode.width + "x" + mode.height !== resolution) continue
    if (!seen[mode.refresh]) {
      seen[mode.refresh] = true
      out.push(mode.refresh)
    }
  }
  out.sort(function(a, b) { return Number(b) - Number(a) })
  return out
}

function modeString(resolution, refresh) {
  if (!resolution || !refresh) return ""
  return String(resolution) + "@" + String(refresh)
}

function parseMonitors(raw) {
  var list
  try {
    list = JSON.parse(String(raw || "[]"))
  } catch (e) {
    return []
  }
  if (!Array.isArray(list)) return []

  var out = []
  for (var i = 0; i < list.length && out.length < 32; i++) {
    var item = list[i]
    if (!item || typeof item !== "object") continue

    var name = String(item.name || "").slice(0, 64)
    if (!/^[A-Za-z0-9._:-]+$/.test(name)) continue

    var width = clampInteger(item.width, 1, 100000, 0)
    var height = clampInteger(item.height, 1, 100000, 0)
    if (!width || !height) continue

    var scale = Number(item.scale)
    if (!isFinite(scale) || scale <= 0 || scale > 10) scale = 1

    var refreshRate = Number(item.refreshRate)
    if (!isFinite(refreshRate) || refreshRate <= 0 || refreshRate > 1000) refreshRate = 60

    var modes = []
    if (Array.isArray(item.availableModes)) {
      for (var j = 0; j < item.availableModes.length && modes.length < 256; j++) {
        var mode = parseModeString(item.availableModes[j])
        if (mode) modes.push(mode)
      }
    }

    var resolution = width + "x" + height
    var refresh = nearestRefresh(modes, resolution, refreshRate)
    if (refresh === "") refresh = String(Number(refreshRate.toFixed(2)))

    var description = String(item.description || "").slice(0, 256)
    var transform = clampInteger(item.transform, 0, 7, 0)
    // hyprctl reports the mode's pixel size, so a 90/270 degree rotation swaps
    // the on-screen footprint that overlap and packing math has to use.
    var layoutWidth = Math.max(1, Math.round(width / scale))
    var layoutHeight = Math.max(1, Math.round(height / scale))
    if (transform % 2 === 1) {
      var swapped = layoutWidth
      layoutWidth = layoutHeight
      layoutHeight = swapped
    }
    out.push({
      name: name,
      description: description,
      identity: description !== "" ? description : name,
      width: width,
      height: height,
      pendingWidth: width,
      pendingHeight: height,
      logicalWidth: Math.max(1, Math.round(width / scale)),
      logicalHeight: Math.max(1, Math.round(height / scale)),
      layoutWidth: layoutWidth,
      layoutHeight: layoutHeight,
      x: clampInteger(item.x, -100000, 100000, 0),
      y: clampInteger(item.y, -100000, 100000, 0),
      scale: scale,
      transform: transform,
      refreshRate: refreshRate,
      enabled: item.disabled !== true,
      focused: item.focused === true,
      availableModes: modes,
      pendingResolution: resolution,
      pendingRefresh: refresh
    })
  }
  return out
}

function overlaps(a, b) {
  if (!a || !b || !a.enabled || !b.enabled) return false
  var aw = a.layoutWidth || a.logicalWidth
  var ah = a.layoutHeight || a.logicalHeight
  var bw = b.layoutWidth || b.logicalWidth
  var bh = b.layoutHeight || b.logicalHeight
  return a.x < b.x + bw
    && b.x < a.x + aw
    && a.y < b.y + bh
    && b.y < a.y + ah
}

function anyOverlap(monitors) {
  if (!Array.isArray(monitors)) return false
  for (var i = 0; i < monitors.length; i++) {
    for (var j = i + 1; j < monitors.length; j++) {
      if (overlaps(monitors[i], monitors[j])) return true
    }
  }
  return false
}

function monitorOverlaps(monitors, name) {
  if (!Array.isArray(monitors)) return false

  var target = null
  for (var i = 0; i < monitors.length; i++) {
    if (monitors[i] && monitors[i].name === name) {
      target = monitors[i]
      break
    }
  }
  if (!target) return false

  for (var j = 0; j < monitors.length; j++) {
    if (!monitors[j] || monitors[j].name === name) continue
    if (overlaps(target, monitors[j])) return true
  }
  return false
}

function sortedByPosition(monitors) {
  if (!Array.isArray(monitors)) return []
  return monitors.slice().sort(function(a, b) {
    if (a.x !== b.x) return a.x - b.x
    if (a.y !== b.y) return a.y - b.y
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
  })
}

function freePosition(monitors, name) {
  var right = 0
  var found = false
  if (Array.isArray(monitors)) {
    for (var i = 0; i < monitors.length; i++) {
      var monitor = monitors[i]
      if (!monitor || monitor.name === name || !monitor.enabled) continue
      right = Math.max(right, monitor.x + (monitor.layoutWidth || monitor.logicalWidth))
      found = true
    }
  }
  return { x: found ? right : 0, y: 0 }
}

function layoutSize(monitor) {
  var w = Number(monitor && (monitor.layoutWidth || monitor.logicalWidth)) || 0
  var h = Number(monitor && (monitor.layoutHeight || monitor.logicalHeight)) || 0
  return { w: Math.max(1, Math.round(w)), h: Math.max(1, Math.round(h)) }
}

function rectsOverlap(ax, ay, aw, ah, bx, by, bw, bh) {
  return ax < bx + bw && bx < ax + aw && ay < by + bh && by < ay + ah
}

// Snap candidates for the top-left corner of the named monitor: the origin,
// every enabled sibling's left/right edges (for our left edge), our width
// shifted variants (for our right edge to align), and the same on Y.
function snapCandidates(monitors, name) {
  var xs = [0]
  var ys = [0]
  var sw = 0
  var sh = 0

  if (Array.isArray(monitors)) {
    for (var i = 0; i < monitors.length; i++) {
      if (monitors[i] && monitors[i].name === name) {
        var self = layoutSize(monitors[i])
        sw = self.w
        sh = self.h
      }
    }
    for (var j = 0; j < monitors.length; j++) {
      var other = monitors[j]
      if (!other || other.name === name || !other.enabled) continue
      var size = layoutSize(other)
      xs.push(other.x, other.x + size.w, other.x - sw, other.x + size.w - sw)
      ys.push(other.y, other.y + size.h, other.y - sh, other.y + size.h - sh)
    }
  }
  return { xs: xs, ys: ys, w: sw, h: sh }
}

function nearestCandidate(value, candidates, magnet) {
  var best = null
  var bestDistance = Infinity
  for (var i = 0; i < candidates.length; i++) {
    var candidate = Number(candidates[i])
    if (!isFinite(candidate)) continue
    var distance = Math.abs(value - candidate)
    if (distance < bestDistance) {
      best = candidate
      bestDistance = distance
    }
  }
  return bestDistance <= magnet ? best : null
}

// Drag resolution with edge snapping and collision push-out. The pointer
// position first snaps to a nearby edge (24px magnet) or an 8px grid, then
// any overlap with an enabled sibling is resolved by pushing out along the
// axis of least penetration — so dragging one display through another slides
// it around instead of inside. Returns the position plus which axes snapped,
// or null when no overlap-free position exists (the card stays put).
function resolveDrag(monitors, name, rawX, rawY) {
  if (!Array.isArray(monitors) || !isFinite(Number(rawX)) || !isFinite(Number(rawY))) return null

  var self = null
  for (var i = 0; i < monitors.length; i++) {
    if (monitors[i] && monitors[i].name === name) {
      self = monitors[i]
      break
    }
  }
  if (!self || !self.enabled) return null

  var size = layoutSize(self)
  var w = size.w
  var h = size.h
  var candidates = snapCandidates(monitors, name)

  var snapX = nearestCandidate(rawX, candidates.xs, 24)
  var snapY = nearestCandidate(rawY, candidates.ys, 24)
  var x = snapX !== null ? snapX : Math.round(rawX / 8) * 8
  var y = snapY !== null ? snapY : Math.round(rawY / 8) * 8

  function firstOverlap() {
    for (var k = 0; k < monitors.length; k++) {
      var other = monitors[k]
      if (!other || other.name === name || !other.enabled) continue
      var otherSize = layoutSize(other)
      if (rectsOverlap(x, y, w, h, other.x, other.y, otherSize.w, otherSize.h)) return other
    }
    return null
  }

  for (var iter = 0; iter < 8; iter++) {
    var hit = firstOverlap()
    if (!hit) break
    var hitSize = layoutSize(hit)

    // Minimal-translation-vector: push out along the shallowest axis so the
    // card slides around the obstacle instead of jumping across it. Ties
    // prefer vertical, which reads as sliding over/through while dragging
    // horizontally (and mirrors for vertical drags).
    var pushLeft = (x + w) - hit.x
    var pushRight = (hit.x + hitSize.w) - x
    var pushUp = (y + h) - hit.y
    var pushDown = (hit.y + hitSize.h) - y
    var minimum = Math.min(pushLeft, pushRight, pushUp, pushDown)

    if (minimum === pushUp) y = hit.y - h
    else if (minimum === pushDown) y = hit.y + hitSize.h
    else if (minimum === pushLeft) x = hit.x - w
    else x = hit.x + hitSize.w
  }

  if (firstOverlap()) return null

  return {
    x: Math.round(x),
    y: Math.round(y),
    snappedX: candidates.xs.indexOf(x) >= 0,
    snappedY: candidates.ys.indexOf(y) >= 0
  }
}

function identityOf(monitor) {
  if (!monitor) return ""
  return monitor.description ? String(monitor.description) : String(monitor.name || "")
}

function comboMonitors(monitors) {
  var out = []
  if (!Array.isArray(monitors)) return out
  for (var i = 0; i < monitors.length; i++) {
    var identity = identityOf(monitors[i])
    if (identity !== "") out.push(identity)
  }
  out.sort()
  return out
}

function comboKey(monitors) {
  return JSON.stringify(comboMonitors(monitors))
}

function parsePosition(value) {
  var match = /^(-?\d{1,6})x(-?\d{1,6})$/.exec(String(value || ""))
  if (!match) return null
  return { x: parseInt(match[1], 10), y: parseInt(match[2], 10) }
}

// A saved preset matches when every monitor it names is connected now. The
// largest such set wins, so a saved A+B layout still applies when a third
// monitor is plugged in alongside it.
function bestPreset(presets, monitors) {
  if (!Array.isArray(presets) || !Array.isArray(monitors)) return null

  var current = comboMonitors(monitors)
  var best = null
  var bestSize = -1
  var bestUpdated = ""

  for (var i = 0; i < presets.length; i++) {
    var preset = presets[i]
    if (!preset || !Array.isArray(preset.monitors) || !Array.isArray(preset.layout)) continue
    if (preset.monitors.length === 0) continue

    var subset = true
    for (var j = 0; j < preset.monitors.length; j++) {
      if (current.indexOf(String(preset.monitors[j])) < 0) {
        subset = false
        break
      }
    }
    if (!subset) continue

    var updated = String(preset.updated || "")
    if (preset.monitors.length > bestSize
        || (preset.monitors.length === bestSize && updated > bestUpdated)) {
      best = preset
      bestSize = preset.monitors.length
      bestUpdated = updated
    }
  }
  return best
}

function presetLayoutByIdentity(preset) {
  var byIdentity = {}
  if (!preset || !Array.isArray(preset.layout)) return byIdentity
  for (var i = 0; i < preset.layout.length; i++) {
    var entry = preset.layout[i]
    if (!entry || typeof entry.identity !== "string") continue
    byIdentity[entry.identity] = entry
  }
  return byIdentity
}

function layoutMatchesPreset(preset, monitors) {
  if (!preset || !Array.isArray(monitors)) return false
  var byIdentity = presetLayoutByIdentity(preset)
  var matched = 0

  for (var i = 0; i < monitors.length; i++) {
    var monitor = monitors[i]
    var entry = byIdentity[identityOf(monitor)]
    if (!entry) continue
    matched++

    var wantDisabled = entry.disabled === true
    if (wantDisabled !== !monitor.enabled) return false
    if (wantDisabled) continue

    if (String(entry.mode || "") !== modeString(monitor.pendingResolution, monitor.pendingRefresh)) return false
    if (String(entry.position || "") !== (monitor.x + "x" + monitor.y)) return false
    if (Math.abs(Number(entry.scale) - monitor.scale) > 0.001) return false
    if (Number(entry.transform) !== monitor.transform) return false
  }
  return matched > 0
}

// Rules for every monitor plugged in now: preset monitors take their saved
// geometry, monitors the preset has never seen are packed to the right.
function presetRules(preset, monitors) {
  if (!preset || !Array.isArray(monitors)) return []

  var byIdentity = presetLayoutByIdentity(preset)
  var used = {}
  var rules = []
  var right = 0

  for (var i = 0; i < monitors.length; i++) {
    var monitor = monitors[i]
    var identity = identityOf(monitor)
    var entry = byIdentity[identity]
    if (!entry) continue
    used[identity] = true

    if (entry.disabled === true) {
      rules.push({
        name: monitor.name,
        identity: identity,
        description: monitor.description,
        disabled: true
      })
      continue
    }

    var position = String(entry.position || "")
    var parsed = parsePosition(position)
    if (!parsed) position = right + "x0"

    var entryScale = isFinite(Number(entry.scale)) ? Number(entry.scale) : monitor.scale
    var entryMode = parseModeString(entry.mode)
    var entryTransform = isFinite(Number(entry.transform)) ? Number(entry.transform) : monitor.transform
    // Packing advances by the entry's on-screen width, so a rotated entry
    // reserves its mode height instead.
    var entryWidth = entryMode
      ? Math.max(1, Math.round((entryTransform % 2 === 1 ? entryMode.height : entryMode.width) / entryScale))
      : (monitor.layoutWidth || monitor.logicalWidth)

    rules.push({
      name: monitor.name,
      identity: identity,
      description: monitor.description,
      mode: String(entry.mode || modeString(monitor.pendingResolution, monitor.pendingRefresh)),
      position: position,
      scale: entryScale,
      transform: entryTransform,
      disabled: false
    })

    if (parsed) right = Math.max(right, parsed.x + entryWidth)
    else right += entryWidth
  }

  for (var j = 0; j < monitors.length; j++) {
    var extra = monitors[j]
    var extraIdentity = identityOf(extra)
    if (used[extraIdentity]) continue

    if (!extra.enabled) {
      rules.push({
        name: extra.name,
        identity: extraIdentity,
        description: extra.description,
        disabled: true
      })
      continue
    }

    rules.push({
      name: extra.name,
      identity: extraIdentity,
      description: extra.description,
      mode: modeString(extra.pendingResolution, extra.pendingRefresh),
      position: right + "x0",
      scale: extra.scale,
      transform: extra.transform,
      disabled: false
    })
    right += extra.layoutWidth || extra.logicalWidth
  }

  return rules
}

if (typeof module !== "undefined") {
  module.exports = {
    clampBrightness: clampBrightness,
    normalizeScale: normalizeScale,
    cleanScale: cleanScale,
    matchingScaleIndex: matchingScaleIndex,
    availableScales: availableScales,
    brightnessName: brightnessName,
    parseDisplays: parseDisplays,
    clampInteger: clampInteger,
    parseModeString: parseModeString,
    nearestRefresh: nearestRefresh,
    resolutionsFor: resolutionsFor,
    refreshRatesFor: refreshRatesFor,
    modeString: modeString,
    parseMonitors: parseMonitors,
    overlaps: overlaps,
    anyOverlap: anyOverlap,
    monitorOverlaps: monitorOverlaps,
    sortedByPosition: sortedByPosition,
    freePosition: freePosition,
    layoutSize: layoutSize,
    rectsOverlap: rectsOverlap,
    snapCandidates: snapCandidates,
    nearestCandidate: nearestCandidate,
    resolveDrag: resolveDrag,
    identityOf: identityOf,
    comboMonitors: comboMonitors,
    comboKey: comboKey,
    parsePosition: parsePosition,
    bestPreset: bestPreset,
    layoutMatchesPreset: layoutMatchesPreset,
    presetRules: presetRules
  }
}
