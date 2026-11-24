import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.callumau.displays"
  ipcTarget: "io.github.callumau.displays"
  manageIpc: false

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness, identify, and state methods below.
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // name -> monitor object. Replaced as a whole on every edit so the
  // Repeater delegates keep a stable model (their names array) while their
  // bound geometry updates during a drag.
  property var layoutNames: []
  property var layoutState: ({})
  property string selectedLayoutName: ""
  property real canvasScale: 1
  property real canvasOffsetX: 0
  property real canvasOffsetY: 0
  property real canvasViewWidth: 0
  property real canvasViewHeight: 0
  property bool layoutDirty: false
  property bool applyRunning: false
  property bool acceptOverlapSnapshot: false
  property string layoutStatusKey: ""
  property string layoutStatusDetail: ""

  // Identify overlay: briefly shows matching numbers on every active screen.
  readonly property int identifyDurationMs: 3000
  property bool identifying: false

  // Per-monitor brightness state (probed lazily for the selected display).
  property var brightnessCache: ({})
  property string brightnessProbeMonitor: ""
  property string brightnessMonitor: ""
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property string pendingBrightnessMonitor: ""
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property real wheelAccumulator: 0

  // Scale stops for the selected display (filtered to clean Hyprland divisors).
  readonly property var scalePresets: ["0.5", "0.75", "1", "1.25", "1.5", "1.6", "2", "2.5", "3", "4"]

  // Text size slider — curated macOS-style notches (px), global across the
  // desktop (omarchy-shell, GTK apps, and terminals via omarchy-display-text-size).
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  property int textSizePreviewIndex: -1
  property int pendingTextPx: 0
  property bool textSizeQueued: false

  // Post-Apply trial: a layout is live but not persisted until the user keeps
  // it. If the timer expires, the previous live layout comes back.
  readonly property int confirmationSeconds: 15
  property bool confirmPending: false
  property int confirmSecondsLeft: confirmationSeconds
  property real confirmDeadline: 0
  property string applyMode: "apply"
  property var pendingLayoutRules: []
  property var previousLayoutRules: []
  property var liveLayoutRules: []
  property string trialIntent: ""
  property bool trialResumed: false

  // Drag state shared by the monitor cards.
  property string dragMonitorName: ""
  property point dragPressScene: Qt.point(0, 0)
  property real dragStartScale: 1
  property real dragStartX: 0
  property real dragStartY: 0

  // Snap guide lines drawn on the canvas while dragging: the dragged card's
  // snapped left/top edge, which always sits on a sibling's edge (or 0).
  property bool snapX: false
  property int snapGuideX: 0
  property bool snapY: false
  property int snapGuideY: 0

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    if (url.indexOf("file://") !== 0) return ""
    return decodeURIComponent(url.substring(7)).replace(/\/+$/, "")
  }

  readonly property string homeDir: Quickshell.env("HOME")
  // Null-safe bar accessor: the shell also instantiates this panel without a bar
  // (preview/thumbnail), where every `bar.x` read throws on each re-evaluation.
  readonly property string barFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string trialPath: homeDir + "/.config/omarchy/.monitor-trial.json"

  readonly property var layoutMonitors: {
    var list = []
    for (var i = 0; i < layoutNames.length; i++) {
      var monitor = layoutState[layoutNames[i]]
      if (monitor) list.push(monitor)
    }
    return list
  }

  readonly property var enabledLayoutMonitors: {
    var list = []
    for (var i = 0; i < layoutMonitors.length; i++) {
      if (layoutMonitors[i].enabled) list.push(layoutMonitors[i])
    }
    return list
  }

  readonly property var selectedMonitor: selectedLayoutName !== ""
    ? (layoutState[selectedLayoutName] || null) : null

  readonly property bool hasLayoutOverlap: Model.anyOverlap(layoutMonitors)

  // The first overlapping pair, so the warning names the displays instead of
  // leaving the user to compare rectangles.
  readonly property var overlapPair: {
    var monitors = enabledLayoutMonitors
    for (var i = 0; i < monitors.length; i++) {
      for (var j = i + 1; j < monitors.length; j++) {
        if (Model.overlaps(monitors[i], monitors[j]))
          return [monitors[i].name, monitors[j].name]
      }
    }
    return []
  }

  readonly property var scaleValues: {
    var m = selectedMonitor
    if (!m) return scalePresets
    return Model.availableScales(scalePresets, m.pendingWidth || m.width, m.pendingHeight || m.height)
  }

  readonly property var resolutionOptions: {
    var monitor = selectedMonitor
    if (!monitor) return []
    var resolutions = Model.resolutionsFor(monitor.availableModes)
    if (resolutions.indexOf(monitor.pendingResolution) < 0)
      resolutions.unshift(monitor.pendingResolution)
    return resolutions
  }

  readonly property var refreshOptions: {
    var monitor = selectedMonitor
    if (!monitor) return []
    var rates = Model.refreshRatesFor(monitor.availableModes, monitor.pendingResolution)
    if (rates.indexOf(monitor.pendingRefresh) < 0)
      rates.unshift(monitor.pendingRefresh)
    return rates
  }

  readonly property var resolutionDropdownOptions: {
    var options = []
    for (var i = 0; i < resolutionOptions.length; i++) {
      var parts = String(resolutionOptions[i]).split("x")
      options.push({
        value: resolutionOptions[i],
        label: parts.length === 2 ? parts[0] + " × " + parts[1] : resolutionOptions[i]
      })
    }
    return options
  }

  readonly property var refreshDropdownOptions: {
    var options = []
    for (var i = 0; i < refreshOptions.length; i++) {
      var value = String(refreshOptions[i])
      var decimals = value.indexOf(".") >= 0 ? 2 : 0
      options.push({
        value: value,
        label: Commons.I18n.formatNumber(Number(value), decimals) + " Hz"
      })
    }
    return options
  }

  readonly property var orientationDropdownOptions: {
    var options = [
      { value: "0", label: strings.t("layout.orientation.landscape") },
      { value: "1", label: strings.t("layout.orientation.portrait") },
      { value: "2", label: strings.t("layout.orientation.landscapeFlipped") },
      { value: "3", label: strings.t("layout.orientation.portraitFlipped") }
    ]
    var m = selectedMonitor
    if (m && m.transform > 3) {
      options.push({
        value: String(m.transform),
        label: strings.t("layout.orientation.custom").arg(m.transform)
      })
    }
    return options
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value, root.selectedLayoutName)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      selectedMonitor: root.selectedLayoutName,
      layoutDirty: root.layoutDirty,
      overlap: root.hasLayoutOverlap,
      identifying: root.identifying,
      confirmPending: root.confirmPending,
      confirmSecondsLeft: root.confirmSecondsLeft,
      applyMode: root.applyMode,
      layout: root.layoutMonitors.map(function(monitor) {
        return {
          name: monitor.name,
          number: root.monitorNumber(monitor.name),
          x: monitor.x,
          y: monitor.y,
          width: monitor.layoutWidth,
          height: monitor.layoutHeight,
          scale: monitor.scale,
          transform: monitor.transform,
          enabled: monitor.enabled,
          pendingResolution: monitor.pendingResolution,
          pendingRefresh: monitor.pendingRefresh
        }
      })
    })
  }

  // A target of its own: the bar host also registers the plugin id, and the
  // first handler wins, so extra methods would be unreachable there.
  ShellIpc {
    target: "io.github.callumau.displays.panel"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function identify(): string {
      root.identifyMonitors()
      return "ok"
    }
    function layout(): string {
      root.open()
      return "ok"
    }
    function display(): string {
      root.open()
      return "ok"
    }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (!layoutProc.running) layoutProc.running = true
    if (root.opened && selectedLayoutName !== "") probeBrightness(selectedLayoutName)
  }

  function refreshLayout() {
    if (!layoutProc.running) layoutProc.running = true
  }

  // ---- Per-monitor brightness ----
  function applyCachedBrightness(name) {
    if (!name) {
      root.brightnessAvailable = false
      root.brightnessPercent = 0
      root.brightnessMonitor = ""
      return
    }
    var cached = root.brightnessCache[name]
    if (cached) {
      root.brightnessAvailable = cached.available
      root.brightnessPercent = cached.percent
      root.brightnessMonitor = name
    } else {
      root.brightnessAvailable = false
      root.brightnessMonitor = ""
    }
  }

  function probeBrightness(name) {
    if (!name) return
    var monitor = layoutState[name]
    if (monitor && !monitor.enabled) {
      root.brightnessAvailable = false
      root.brightnessMonitor = name
      return
    }
    applyCachedBrightness(name)
    if (brightnessProbeProc.running) return
    root.brightnessProbeMonitor = name
    brightnessProbeProc.command = ["omarchy-brightness-display", "--monitor", name]
    brightnessProbeProc.running = true
  }

  function setBrightness(value, monitorName) {
    var target = monitorName || root.selectedLayoutName
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent
    root.pendingBrightnessMonitor = target

    if (target !== "") {
      var nextCache = {}
      for (var k in root.brightnessCache) nextCache[k] = root.brightnessCache[k]
      nextCache[target] = { available: true, percent: percent }
      root.brightnessCache = nextCache
    }

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    var cmd = ["omarchy-brightness-display", "--no-osd"]
    if (target !== "") {
      cmd.push("--monitor")
      cmd.push(target)
    }
    cmd.push(percent + "%")
    setBrightnessProc.command = cmd
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  // ---- Per-monitor scale ----
  function currentScaleIndex() {
    var m = selectedMonitor
    if (!m || scaleValues.length === 0) return 0
    var exact = Model.matchingScaleIndex(scaleValues, m.scale, m.pendingWidth || m.width, m.pendingHeight || m.height)
    if (exact >= 0) return exact
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < scaleValues.length; i++) {
      var eff = Number(effectiveScale(scaleValues[i]))
      var d = Math.abs(eff - m.scale)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  function effectiveScale(scale) {
    var m = selectedMonitor
    if (m) return Model.cleanScale(scale, m.pendingWidth || m.width, m.pendingHeight || m.height)
    return Model.normalizeScale(scale)
  }

  function setMonitorScale(name, scale) {
    var monitor = layoutState[name]
    if (!monitor) return
    var w = monitor.pendingWidth || monitor.width
    var h = monitor.pendingHeight || monitor.height
    var clean = Number(Model.cleanScale(scale, w, h))
    if (!isFinite(clean) || clean <= 0) return
    var next = cloneMonitor(monitor)
    next.scale = clean
    var rotated = next.transform % 2 === 1
    next.layoutWidth = Math.max(1, Math.round((rotated ? h : w) / clean))
    next.layoutHeight = Math.max(1, Math.round((rotated ? w : h) / clean))
    replaceMonitor(next)
    layoutDirty = true
    layoutStatusKey = ""
    layoutStatusDetail = ""
    recomputeCanvas()
  }

  // ---- Layout model helpers ----
  function cloneMonitor(monitor) {
    var copy = {}
    for (var key in monitor) copy[key] = monitor[key]
    return copy
  }

  function replaceMonitor(monitor) {
    if (!monitor || !monitor.name) return
    var next = {}
    for (var key in layoutState) next[key] = layoutState[key]
    next[monitor.name] = monitor
    layoutState = next
  }

  function rulesFromMonitors(monitors) {
    var rules = []
    for (var i = 0; i < monitors.length; i++) {
      var monitor = monitors[i]
      if (!monitor) continue
      var identity = monitor.identity || monitor.description || monitor.name
      if (!monitor.enabled) {
        rules.push({
          name: monitor.name,
          identity: identity,
          description: monitor.description || "",
          disabled: true
        })
      } else {
        rules.push({
          name: monitor.name,
          identity: identity,
          description: monitor.description || "",
          mode: Model.modeString(monitor.pendingResolution, monitor.pendingRefresh),
          position: Math.round(monitor.x) + "x" + Math.round(monitor.y),
          scale: monitor.scale,
          transform: monitor.transform,
          disabled: false
        })
      }
    }
    return rules
  }

  function sameMonitorSet(monitors) {
    if (!monitors || monitors.length !== layoutNames.length) return false
    for (var i = 0; i < monitors.length; i++) {
      if (layoutNames.indexOf(monitors[i].name) < 0) return false
    }
    return true
  }

  function setLayoutMonitors(monitors) {
    if (!monitors || monitors.length === 0) return

    var sameNames = sameMonitorSet(monitors)
    var droppedTrial = false

    // A hotplug during the confirmation prompt changes the display set under
    // the pending trial. Drop the prompt and let the new snapshot (and the
    // preset watcher) take over. The first snapshot after a (re)load populates
    // the canvas behind the resumed prompt instead. The trial layout stays
    // live, so say so and keep the layout dirty — Apply/Revert must stay
    // reachable instead of stranding a divergence no config describes.
    if (confirmPending) {
      if (sameNames) return
      if (layoutNames.length > 0) {
        confirmPending = false
        confirmTimer.stop()
        clearTrial()
        droppedTrial = true
      }
    }
    var resumingTrial = confirmPending

    // Applying a swap briefly puts one display on top of another. Do not
    // replace a clean layout with that in-between snapshot; re-read once the
    // compositor has settled, and accept it if it persists.
    if (Model.anyOverlap(monitors) && !layoutDirty && !hasLayoutOverlap
        && !acceptOverlapSnapshot) {
      acceptOverlapSnapshot = true
      overlapRetry.restart()
      return
    }
    acceptOverlapSnapshot = false

    // Polling runs with unsaved edits too. Same display set means keep the
    // edited geometry and only refresh the live baseline that Revert uses.
    if (sameNames && layoutDirty && !droppedTrial) {
      liveLayoutRules = rulesFromMonitors(monitors)
      return
    }

    var next = {}
    var focusName = ""
    for (var i = 0; i < monitors.length; i++) {
      var monitor = monitors[i]
      next[monitor.name] = monitor
      if (monitor.focused) focusName = monitor.name
    }
    var names = Model.orderedMonitorNames(monitors)

    if (names.indexOf(selectedLayoutName) < 0)
      selectedLayoutName = focusName !== "" ? focusName : names[0]

    liveLayoutRules = rulesFromMonitors(monitors)
    layoutState = next
    if (!sameNames) layoutNames = names
    // A delegate destroyed mid-drag never delivers `released`.
    if (names.indexOf(dragMonitorName) < 0) endDragMonitor()
    if (!resumingTrial) {
      layoutStatusKey = droppedTrial ? "layout.trialDropped"
        : (layoutDirty ? "layout.displaySetChanged" : "")
      layoutStatusDetail = ""
      layoutDirty = droppedTrial
      snapX = false
      snapY = false
    }
    recomputeCanvas()
    if (root.opened && selectedLayoutName !== "" && brightnessMonitor !== selectedLayoutName)
      probeBrightness(selectedLayoutName)
  }

  function resumeTrial(raw) {
    if (trialResumed) return
    trialResumed = true
    var trial = null
    try {
      trial = JSON.parse(String(raw || ""))
    } catch (e) {
      return
    }
    if (!trial || !Array.isArray(trial.pending) || !Array.isArray(trial.previous)) return
    if (trial.pending.length === 0 || trial.previous.length === 0) return
    var deadline = Number(trial.deadline)
    if (!isFinite(deadline) || deadline <= 0) {
      clearTrial()
      return
    }

    pendingLayoutRules = trial.pending
    previousLayoutRules = trial.previous

    if (Date.now() >= deadline) {
      // The deadline passed while the shell was gone: revert straight away.
      confirmPending = true
      revertPendingLayout()
      return
    }

    confirmDeadline = deadline
    confirmSecondsLeft = Math.max(1, Math.ceil((deadline - Date.now()) / 1000))
    confirmPending = true
    applyMode = "apply"
    layoutStatusKey = "layout.testing"
    layoutStatusDetail = ""
    layoutDirty = true
    open()
    confirmTimer.restart()
  }

  function selectLayoutMonitor(name) {
    if (!name) return
    selectedLayoutName = name
    if (root.opened) probeBrightness(name)
  }

  function monitorNumber(name) {
    if (!name) return 0
    var idx = layoutNames.indexOf(name)
    return idx >= 0 ? idx + 1 : 0
  }

  function identifyMonitors() {
    if (layoutNames.length === 0) refreshLayout()
    identifying = true
    identifyTimer.restart()
  }

  function stopIdentify() {
    identifyTimer.stop()
    identifying = false
  }

  function recomputeCanvas() {
    var monitors = enabledLayoutMonitors
    if (monitors.length === 0) {
      canvasScale = 1
      canvasOffsetX = 0
      canvasOffsetY = 0
      return
    }

    var minX = monitors[0].x
    var minY = monitors[0].y
    var maxX = monitors[0].x + monitors[0].layoutWidth
    var maxY = monitors[0].y + monitors[0].layoutHeight
    for (var i = 1; i < monitors.length; i++) {
      minX = Math.min(minX, monitors[i].x)
      minY = Math.min(minY, monitors[i].y)
      maxX = Math.max(maxX, monitors[i].x + monitors[i].layoutWidth)
      maxY = Math.max(maxY, monitors[i].y + monitors[i].layoutHeight)
    }

    var canvasW = canvasViewWidth > 0 ? canvasViewWidth : Style.space(380)
    var canvasH = canvasViewHeight > 0 ? canvasViewHeight : Style.space(144)
    var pad = Style.space(10)
    var spanW = Math.max(1, maxX - minX)
    var spanH = Math.max(1, maxY - minY)
    var scale = Math.min(0.22, (canvasW - pad * 2) / spanW, (canvasH - pad * 2) / spanH)
    if (!isFinite(scale) || scale <= 0) scale = 0.1

    canvasScale = scale
    canvasOffsetX = (canvasW - spanW * scale) / 2 - minX * scale
    canvasOffsetY = (canvasH - spanH * scale) / 2 - minY * scale
  }

  function moveMonitor(name, x, y) {
    var monitor = layoutState[name]
    if (!monitor || !monitor.enabled) return
    // Edge snapping plus collision push-out live in the model so the drag
    // can never place a display inside another one. A null result means the
    // pointer is somewhere nothing fits (fully boxed in) — stay put.
    var resolved = Model.resolveDrag(layoutMonitors, name, x, y)
    if (!resolved) return
    var next = cloneMonitor(monitor)
    next.x = resolved.x
    next.y = resolved.y
    replaceMonitor(next)
    snapX = resolved.snappedX
    snapGuideX = resolved.x
    snapY = resolved.snappedY
    snapGuideY = resolved.y
    layoutDirty = true
  }

  function endDragMonitor() {
    dragMonitorName = ""
    snapX = false
    snapY = false
    // Clear the status on drop rather than on every pointer move, so a
    // divergence message survives a nudge.
    layoutStatusKey = ""
    layoutStatusDetail = ""
    // Refit the canvas to the dropped arrangement so the whole layout stays
    // in view after a long drag.
    recomputeCanvas()
  }

  function setMonitorResolution(name, resolution) {
    var monitor = layoutState[name]
    if (!monitor) return
    var next = cloneMonitor(monitor)
    next.pendingResolution = resolution

    var parts = String(resolution).split("x")
    var pendingWidth = parseInt(parts[0], 10)
    var pendingHeight = parseInt(parts[1], 10)
    if (pendingWidth > 0 && pendingHeight > 0) {
      next.pendingWidth = pendingWidth
      next.pendingHeight = pendingHeight
      var clean = Number(Model.cleanScale(next.scale, pendingWidth, pendingHeight))
      if (isFinite(clean) && clean > 0) next.scale = clean
      // hyprctl reports mode pixels, so a 90/270 degree rotation swaps the
      // footprint — same rule as Model.parseMonitors.
      var rotated = next.transform % 2 === 1
      next.layoutWidth = Math.max(1, Math.round((rotated ? pendingHeight : pendingWidth) / next.scale))
      next.layoutHeight = Math.max(1, Math.round((rotated ? pendingWidth : pendingHeight) / next.scale))
    }

    var rates = Model.refreshRatesFor(next.availableModes, resolution)
    if (rates.indexOf(next.pendingRefresh) < 0)
      next.pendingRefresh = rates.length > 0 ? rates[0] : next.pendingRefresh
    replaceMonitor(next)
    layoutDirty = true
    layoutStatusKey = ""
    layoutStatusDetail = ""
    recomputeCanvas()
  }

  function setMonitorRefresh(name, refresh) {
    var monitor = layoutState[name]
    if (!monitor) return
    var next = cloneMonitor(monitor)
    next.pendingRefresh = refresh
    replaceMonitor(next)
    layoutDirty = true
    layoutStatusKey = ""
    layoutStatusDetail = ""
  }

  function setMonitorTransform(name, transform) {
    var monitor = layoutState[name]
    if (!monitor) return
    var value = parseInt(String(transform), 10)
    if (!isFinite(value) || value < 0 || value > 7) return
    var next = cloneMonitor(monitor)
    next.transform = value
    var w = next.pendingWidth || next.width
    var h = next.pendingHeight || next.height
    var rotated = value % 2 === 1
    next.layoutWidth = Math.max(1, Math.round((rotated ? h : w) / next.scale))
    next.layoutHeight = Math.max(1, Math.round((rotated ? w : h) / next.scale))
    replaceMonitor(next)
    layoutDirty = true
    layoutStatusKey = ""
    layoutStatusDetail = ""
    recomputeCanvas()
  }

  function setMonitorEnabled(name, enabled) {
    var monitor = layoutState[name]
    if (!monitor) return
    if (!enabled && enabledLayoutMonitors.length <= 1) return
    var next = cloneMonitor(monitor)
    var wasEnabled = next.enabled
    next.enabled = enabled
    if (enabled && !wasEnabled) {
      var spot = Model.freePosition(enabledLayoutMonitors, name)
      next.x = spot.x
      next.y = spot.y
    }
    replaceMonitor(next)
    layoutDirty = true
    layoutStatusKey = ""
    layoutStatusDetail = ""
    recomputeCanvas()
  }

  function makePrimary(name) {
    var monitor = layoutState[name]
    if (!monitor || !monitor.enabled) return

    var order = Model.sortedByPosition(enabledLayoutMonitors)
    var next = {}
    for (var key in layoutState) next[key] = layoutState[key]

    var primary = cloneMonitor(monitor)
    primary.x = 0
    primary.y = 0
    next[primary.name] = primary

    var x = primary.layoutWidth
    for (var i = 0; i < order.length; i++) {
      if (order[i].name === name) continue
      var other = cloneMonitor(order[i])
      other.x = x
      other.y = 0
      next[other.name] = other
      x += other.layoutWidth
    }
    layoutState = next
    layoutDirty = true
    layoutStatusKey = ""
    layoutStatusDetail = ""
    recomputeCanvas()
  }

  function revertLayout() {
    layoutDirty = false
    layoutStatusKey = ""
    layoutStatusDetail = ""
    refreshLayout()
  }

  function applyLayout() {
    if (applyProc.running || confirmPending) return
    if (hasLayoutOverlap) return
    if (enabledLayoutMonitors.length === 0) return

    var rules = rulesFromMonitors(layoutMonitors)
    if (rules.length === 0 || pluginDir === "") {
      layoutStatusKey = "layout.failed"
      layoutStatusDetail = pluginDir === "" ? "plugin path unavailable" : ""
      return
    }
    if (liveLayoutRules.length === 0) {
      layoutStatusKey = "layout.failed"
      layoutStatusDetail = "no previous layout to revert to"
      return
    }

    pendingLayoutRules = rules
    previousLayoutRules = liveLayoutRules.slice()
    applyMode = "apply"
    layoutStatusKey = "layout.applying"
    layoutStatusDetail = ""
    applyRunning = true

    // Trial only: no monitors.conf or preset write until the user keeps it.
    applyProc.command = ["bash", pluginDir + "/apply-displays.sh", JSON.stringify(rules), "--live-only"]
    applyProc.running = true
  }

  function trialPayload() {
    var names = []
    for (var i = 0; i < layoutNames.length; i++) names.push(layoutNames[i])
    return {
      pending: pendingLayoutRules,
      previous: previousLayoutRules,
      deadline: confirmDeadline,
      monitors: names
    }
  }

  function saveTrial() { writeTrial("save") }
  function clearTrial() { writeTrial("clear") }

  // Trial persistence drains through one deferred intent: a clear issued while
  // the save is still exiting must not be dropped, or a future-dated trial file
  // survives and the next reload reverts the layout the user just kept.
  function writeTrial(intent) {
    if (pluginDir === "") return
    trialIntent = intent
    pumpTrial()
  }

  function pumpTrial() {
    if (trialIntent === "" || trialSaveProc.running || trialClearProc.running) return
    var intent = trialIntent
    trialIntent = ""
    if (intent === "save") {
      trialSaveProc.command = ["bash", pluginDir + "/apply-displays.sh",
        JSON.stringify(trialPayload()), "--save-trial"]
      trialSaveProc.running = true
    } else {
      trialClearProc.command = ["bash", pluginDir + "/apply-displays.sh",
        "--clear-trial"]
      trialClearProc.running = true
    }
  }

  function startConfirmation() {
    confirmPending = true
    confirmSecondsLeft = confirmationSeconds
    confirmDeadline = Date.now() + confirmationSeconds * 1000
    confirmTimer.restart()
    layoutStatusKey = "layout.testing"
    layoutStatusDetail = ""
    layoutDirty = true
    applyRunning = false
    saveTrial()
    // Make sure the prompt is visible even if the panel was closed by the
    // monitor move (the bar can rebuild its widgets when screens change).
    open()
  }

  function tickConfirmation() {
    var millisecondsLeft = confirmDeadline - Date.now()
    if (millisecondsLeft <= 0) {
      confirmSecondsLeft = 0
      revertPendingLayout()
      return
    }
    confirmSecondsLeft = Math.ceil(millisecondsLeft / 1000)
  }

  function keepPendingLayout() {
    if (!confirmPending || applyProc.running) return
    confirmTimer.stop()
    confirmPending = false
    // The trial file is cleared by the --commit exit path, not here: a failed
    // commit must keep the trial resumable.
    applyMode = "keep"
    layoutStatusKey = "layout.saving"
    layoutStatusDetail = ""
    applyRunning = true

    // The live layout is already correct; write config and preset now.
    applyProc.command = ["bash", pluginDir + "/apply-displays.sh", JSON.stringify(pendingLayoutRules), "--commit"]
    applyProc.running = true
  }

  function revertPendingLayout() {
    if (!confirmPending || applyProc.running) return
    confirmTimer.stop()
    confirmPending = false
    applyMode = "revert"
    layoutStatusKey = "layout.reverting"
    layoutStatusDetail = ""
    applyRunning = true

    // config and preset still describe the previous layout, so a live apply
    // is enough to bring it back.
    applyProc.command = ["bash", pluginDir + "/apply-displays.sh", JSON.stringify(previousLayoutRules), "--live-only"]
    applyProc.running = true
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    var value = Math.round(px)
    root.pendingTextPx = value
    if (textScaleProc.running) {
      root.textSizeQueued = true
      return
    }
    root.textSizeQueued = false
    textScaleProc.command = ["omarchy-display-text-size", String(value)]
    textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    refreshLayout()
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
    } else {
      // A drag whose delegate died mid-press (close while held) never delivers
      // `released`, which would leave the snap guides painted on the canvas.
      dragMonitorName = ""
      snapX = false
      snapY = false
      stopIdentify()
    }
  }
  onConfirmPendingChanged: if (confirmPending && opened) confirmOverlay.forceActiveFocus()

  // Poll while the panel is open so hotplugs update the canvas.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refreshLayout()
  }

  Timer {
    id: overlapRetry
    interval: 1200
    repeat: false
    onTriggered: root.refreshLayout()
  }

  Timer {
    id: confirmTimer
    interval: 250
    repeat: true
    running: root.confirmPending
    onTriggered: root.tickConfirmation()
  }

  Timer {
    id: identifyTimer
    interval: root.identifyDurationMs
    repeat: false
    onTriggered: root.identifying = false
  }

  Process {
    id: layoutProc
    command: ["hyprctl", "-j", "monitors", "all"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.setLayoutMonitors(Model.parseMonitors(text))
    }
  }

  Process {
    id: brightnessProbeProc
    stdout: StdioCollector { id: brightnessProbeOut; waitForEnd: true }
    onExited: function(exitCode) {
      var target = root.brightnessProbeMonitor
      root.brightnessProbeMonitor = ""

      var available = false
      var percent = 0
      if (exitCode === 0) {
        var raw = String(brightnessProbeOut.text || "").trim()
        var parsed = parseInt(raw, 10)
        if (raw !== "" && raw !== "unavailable" && isFinite(parsed)) {
          available = true
          percent = Math.max(0, Math.min(100, parsed))
        }
      }

      if (target !== "") {
        var nextCache = {}
        for (var k in root.brightnessCache) nextCache[k] = root.brightnessCache[k]
        nextCache[target] = { available: available, percent: percent }
        root.brightnessCache = nextCache
      }

      if (target === root.selectedLayoutName) {
        root.brightnessAvailable = available
        root.brightnessMonitor = target
        // Do not overwrite an in-flight user drag/write with a stale hardware read.
        if (!setBrightnessProc.running && !root.brightnessSetQueued && !brightnessDebounce.running)
          root.brightnessPercent = available ? percent : 0
      } else if (root.opened && root.selectedLayoutName !== "" && root.selectedLayoutName !== root.brightnessMonitor) {
        root.probeBrightness(root.selectedLayoutName)
      }
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent, root.selectedLayoutName)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent, root.pendingBrightnessMonitor)
      }
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { id: applyStdout; waitForEnd: true }
    stderr: StdioCollector { id: applyStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.applyRunning = false
      var error = String(applyStderr.text || "").trim().slice(0, 160)

      if (exitCode === 0) {
        if (root.applyMode === "apply") {
          root.startConfirmation()
          return
        }
        if (root.applyMode === "keep") {
          root.layoutStatusKey = "layout.applied"
          root.layoutStatusDetail = ""
          root.layoutDirty = false
          root.confirmPending = false
          root.clearTrial()
          root.refreshLayout()
          return
        }
        if (root.applyMode === "revert") {
          root.layoutStatusKey = "layout.reverted"
          root.layoutStatusDetail = ""
          root.layoutDirty = false
          root.confirmPending = false
          root.clearTrial()
          root.refreshLayout()
          return
        }
      }

      if (root.applyMode === "keep") {
        root.layoutStatusKey = "layout.saveFailed"
        root.layoutStatusDetail = error
        root.layoutDirty = true
      } else if (root.applyMode === "revert") {
        root.layoutStatusKey = "layout.revertFailed"
        root.layoutStatusDetail = error
        // The live layout is still the pending one, so keep Apply/Revert alive.
        root.layoutDirty = true
      } else {
        root.layoutStatusKey = "layout.failed"
        root.layoutStatusDetail = error
        root.confirmPending = false
        root.clearTrial()
      }
    }
  }

  // A stuck child (flock wait, hung hyprctl) must not wedge the panel:
  // applyRunning gates Apply, Keep and Revert.
  Timer {
    id: applyWatchdog
    interval: 25000
    repeat: false
    running: root.applyRunning
    onTriggered: {
      if (!applyProc.running) return
      applyProc.running = false
      root.applyRunning = false
      root.layoutStatusKey = "layout.failed"
      root.layoutStatusDetail = "timed out"
    }
  }

  // Trial persistence: a reload mid-confirmation must not strand the trial
  // layout. The file is written on Apply and cleared on Keep, revert, or drop.
  Process {
    id: trialSaveProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: trialSaveError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("displays: could not save trial: " + String(trialSaveError.text || "").trim())
      root.pumpTrial()
    }
  }

  Process {
    id: trialClearProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: trialClearError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("displays: could not clear trial: " + String(trialClearError.text || "").trim())
      root.pumpTrial()
    }
  }

  FileView {
    id: trialFile
    path: root.trialPath
    watchChanges: false
    printErrors: false
    blockLoading: true
    onLoaded: root.resumeTrial(text())
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: textScaleError; waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.textSizeQueued) root.setTextSize(root.pendingTextPx)
    }
    onExited: function(exitCode) {
      if (exitCode === 0) return
      root.textSizePreviewIndex = -1
      console.warn("displays: text size failed: " + String(textScaleError.text || "").trim())
    }
  }

  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5, root.selectedLayoutName)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(760))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias scrollArea: scrollArea
      implicitHeight: panelColumn.implicitHeight
      anchors.fill: parent
      // The confirmation card owns the keyboard while it is up; Enter/Space
      // confirms and Escape reverts.
      blocked: root.confirmPending
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(8)

          // ---------- Header: icon · title/hint · Identify ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, identifyButton.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
              color: root.barForeground
              font.family: root.barFontFamily
              font.pixelSize: Style.font.title
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: identifyButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: 1

              Text {
                text: strings.t("layout.title")
                textFormat: Text.PlainText
                color: root.barForeground
                font.family: root.barFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: strings.t("layout.dragHint").toUpperCase()
                color: Qt.darker(root.barForeground, 1.4)
                font.family: root.barFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.0
                elide: Text.ElideRight
                width: parent.width
              }
            }

            Button {
              id: identifyButton
              text: strings.t("layout.identify")
              fontSize: Style.font.caption
              foreground: root.barForeground
              fontFamily: root.barFontFamily
              horizontalPadding: Style.spacing.sm
              verticalPadding: Style.space(4)
              bordered: true
              selected: root.identifying
              enabled: root.enabledLayoutMonitors.length > 0
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.identifyMonitors()
            }
          }

          // ---------- Arrangement canvas ----------
          Item {
            id: arrangementCanvas
            width: parent.width
            height: Style.space(144)
            clip: true

            onWidthChanged: {
              root.canvasViewWidth = width
              root.recomputeCanvas()
            }
            onHeightChanged: {
              root.canvasViewHeight = height
              root.recomputeCanvas()
            }

            BorderSurface {
              anchors.fill: parent
              color: Style.normalFillFor(root.barForeground, Commons.Color.accent)
              borderSpec: Border.controlSpec("normal", root.barForeground, Commons.Color.accent)
              radius: Style.cornerRadius
            }

            Repeater {
              model: root.layoutNames

              delegate: CursorSurface {
                id: monitorCard
                required property string modelData
                required property int index
                readonly property int displayNumber: index + 1
                readonly property var monitor: root.layoutState[modelData] || ({})
                readonly property bool invalid: root.hasLayoutOverlap
                  && Model.monitorOverlaps(root.layoutMonitors, modelData)

                visible: monitor.enabled === true
                x: root.canvasOffsetX + (monitor.x || 0) * root.canvasScale
                y: root.canvasOffsetY + (monitor.y || 0) * root.canvasScale
                width: Math.max(Style.space(36), (monitor.layoutWidth || 1) * root.canvasScale)
                height: Math.max(Style.space(26), (monitor.layoutHeight || 1) * root.canvasScale)
                hasCursor: root.selectedLayoutName === modelData
                bordered: true
                foreground: root.barForeground
                accent: invalid ? Commons.Color.urgent : Commons.Color.accent
                fill: Style.hoverFillFor(root.barForeground, Commons.Color.accent)
                currentFill: Style.selectedFillFor(root.barForeground, Commons.Color.accent)
                radius: Style.cornerRadius

                Column {
                  anchors.centerIn: parent
                  width: Math.max(1, parent.width - Style.space(8))
                  spacing: 1

                  Text {
                    textFormat: Text.PlainText
                    text: monitorCard.monitor.name || ""
                    color: monitorCard.hasCursor
                      ? Commons.Color.accent
                      : root.barForeground
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                    width: parent.width
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: monitorCard.height > Style.space(48)
                    text: (monitorCard.monitor.pendingResolution || "")
                      + " · " + (monitorCard.monitor.pendingRefresh || "") + " Hz"
                    color: Qt.darker(root.barForeground, 1.3)
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                    width: parent.width
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  visible: monitorCard.monitor.x === 0 && monitorCard.monitor.y === 0
                  text: "★"
                  color: Commons.Color.accent
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  anchors.top: parent.top
                  anchors.left: parent.left
                  anchors.margins: Style.space(3)
                }

                Rectangle {
                  visible: monitorCard.displayNumber > 0
                  anchors.top: parent.top
                  anchors.right: parent.right
                  anchors.margins: Style.space(3)
                  width: Math.max(Style.space(16), cardNumber.implicitWidth + Style.space(6))
                  height: Style.space(16)
                  radius: Style.space(4)
                  color: root.identifying
                    ? Commons.Color.accent
                    : Util.alpha(root.barForeground, 0.16)

                  Text {
                    id: cardNumber
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: String(monitorCard.displayNumber)
                    color: root.identifying
                      ? Commons.Color.background
                      : (monitorCard.hasCursor ? Commons.Color.accent : root.barForeground)
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  preventStealing: true
                  cursorShape: Qt.PointingHandCursor

                  onPressed: function(mouse) {
                    root.selectLayoutMonitor(monitorCard.modelData)
                    root.dragMonitorName = monitorCard.modelData
                    root.dragPressScene = monitorCard.mapToItem(null, mouse.x, mouse.y)
                    root.dragStartScale = root.canvasScale
                    root.dragStartX = monitorCard.monitor.x || 0
                    root.dragStartY = monitorCard.monitor.y || 0
                  }

                  onPositionChanged: function(mouse) {
                    if (!pressed || root.dragMonitorName !== monitorCard.modelData) return
                    var point = monitorCard.mapToItem(null, mouse.x, mouse.y)
                    // Divide by the scale at press: a hotplug refits the canvas
                    // mid-drag and would otherwise retro-scale the delta.
                    var dx = (point.x - root.dragPressScene.x) / root.dragStartScale
                    var dy = (point.y - root.dragPressScene.y) / root.dragStartScale
                    root.moveMonitor(monitorCard.modelData,
                      root.dragStartX + dx, root.dragStartY + dy)
                  }

                  onReleased: {
                    if (root.dragMonitorName === monitorCard.modelData)
                      root.endDragMonitor()
                  }
                }
              }
            }

            // Snap guides: vertical/horizontal rules at the dragged card's
            // snapped edge while a drag is in progress.
            Rectangle {
              visible: root.dragMonitorName !== "" && root.snapX
              x: Math.round(root.canvasOffsetX + root.snapGuideX * root.canvasScale) - 1
              y: 0
              width: 2
              height: arrangementCanvas.height
              color: Commons.Color.accent
              opacity: 0.65
            }

            Rectangle {
              visible: root.dragMonitorName !== "" && root.snapY
              y: Math.round(root.canvasOffsetY + root.snapGuideY * root.canvasScale) - 1
              x: 0
              height: 2
              width: arrangementCanvas.width
              color: Commons.Color.accent
              opacity: 0.65
            }

            Text {
              textFormat: Text.PlainText
              visible: root.enabledLayoutMonitors.length === 0
              text: strings.t("layout.noDisplays")
              color: Qt.darker(root.barForeground, 1.3)
              font.family: root.barFontFamily
              font.pixelSize: Style.font.body
              anchors.centerIn: parent
            }
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.xs

            Repeater {
              model: root.layoutNames

              delegate: Button {
                required property string modelData
                required property int index
                readonly property var monitor: root.layoutState[modelData] || ({})

                text: (index + 1) + " · " + (monitor.name || modelData)
                fontSize: Style.font.caption
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                horizontalPadding: Style.spacing.sm
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                selected: root.selectedLayoutName === modelData
                opacity: monitor.enabled === true ? 1 : 0.55
                onClicked: root.selectLayoutMonitor(modelData)
              }
            }
          }

          PanelSeparator {
            foreground: root.barForeground
          }

          // ---------- Selected display controls ----------
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.selectedMonitor !== null

            Item {
              width: parent.width
              implicitHeight: Math.max(selectedName.implicitHeight, selectedActions.implicitHeight)

              Column {
                id: selectedName
                anchors.left: parent.left
                anchors.right: selectedActions.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                  textFormat: Text.PlainText
                  text: root.selectedMonitor ? root.selectedMonitor.name : ""
                  color: root.barForeground
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  text: {
                    if (!root.selectedMonitor) return ""
                    var parts = []
                    if (root.selectedMonitor.description) parts.push(root.selectedMonitor.description)
                    if (root.selectedMonitor.pendingResolution) parts.push(root.selectedMonitor.pendingResolution)
                    parts.push(Commons.I18n.formatNumber(root.selectedMonitor.scale) + "x")
                    return parts.join(" · ")
                  }
                  color: Qt.darker(root.barForeground, 1.4)
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              Row {
                id: selectedActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Button {
                  readonly property bool isPrimary: root.selectedMonitor !== null
                    && root.selectedMonitor.x === 0 && root.selectedMonitor.y === 0
                  visible: root.enabledLayoutMonitors.length > 1
                  anchors.verticalCenter: parent.verticalCenter
                  text: isPrimary
                    ? "★ " + strings.t("layout.primary")
                    : strings.t("layout.makePrimary")
                  fontSize: Style.font.caption
                  foreground: root.barForeground
                  fontFamily: root.barFontFamily
                  horizontalPadding: Style.spacing.sm
                  verticalPadding: Style.space(3)
                  bordered: true
                  selected: isPrimary
                  enabled: root.selectedMonitor !== null && root.selectedMonitor.enabled && !isPrimary
                  onClicked: if (root.selectedMonitor) root.makePrimary(root.selectedMonitor.name)
                }

                Text {
                  id: selectedEnabledLabel
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.selectedMonitor && root.selectedMonitor.enabled
                    ? strings.t("layout.on")
                    : strings.t("layout.off")
                  color: Qt.darker(root.barForeground, 1.35)
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                ToggleSwitch {
                  id: selectedEnabledToggle
                  readonly property bool canDisable: !root.selectedMonitor
                    || !root.selectedMonitor.enabled
                    || root.enabledLayoutMonitors.length > 1
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.selectedMonitor ? root.selectedMonitor.enabled : false
                  enabled: canDisable
                  opacity: canDisable ? 1.0 : 0.45
                  foreground: root.barForeground
                  accent: Commons.Color.accent
                  onToggled: if (root.selectedMonitor)
                    root.setMonitorEnabled(root.selectedMonitor.name, !root.selectedMonitor.enabled)
                }
              }
            }

            // Per-monitor live brightness (shown only when controllable).
            Column {
              visible: root.brightnessAvailable && root.selectedMonitor !== null && root.selectedMonitor.enabled
              width: parent.width
              spacing: Style.space(6)

              Item {
                width: parent.width
                implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercentLabel.implicitHeight)

                PanelSectionHeader {
                  id: brightnessHeader
                  text: Commons.I18n.t("monitor.brightness")
                  foreground: root.barForeground
                  fontFamily: root.barFontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: brightnessPercentLabel
                  textFormat: Text.PlainText
                  text: Commons.I18n.formatNumber(Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent)) + "%"
                  color: Qt.darker(root.barForeground, 1.4)
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Item {
                width: parent.width
                height: brightnessSlider.implicitHeight + Style.spacing.controlGap

                PanelSlider {
                  id: brightnessSlider
                  bar: root.bar
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  minimum: 1
                  maximum: 100
                  step: 1
                  value: root.brightnessPercent
                  integer: true
                  onMoved: function(v) { root.previewBrightness(v) }
                  onReleased: function(v) {
                    brightnessDebounce.stop()
                    root.setBrightness(v, root.selectedLayoutName)
                  }
                }
              }
            }

            // Per-monitor scale slider (staged with Apply).
            Column {
              width: parent.width
              spacing: Style.space(6)
              enabled: root.selectedMonitor !== null && root.selectedMonitor.enabled
              opacity: enabled ? 1.0 : 0.45

              Item {
                width: parent.width
                implicitHeight: Math.max(scaleHeader.implicitHeight, scaleValueLabel.implicitHeight)

                PanelSectionHeader {
                  id: scaleHeader
                  text: Commons.I18n.t("monitor.scale")
                  foreground: root.barForeground
                  fontFamily: root.barFontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: scaleValueLabel
                  textFormat: Text.PlainText
                  text: {
                    if (!root.selectedMonitor) return ""
                    if (scaleSlider.dragging && root.scaleValues.length > 0) {
                      var idx = Math.max(0, Math.min(root.scaleValues.length - 1, Math.round(scaleSlider.liveValue)))
                      return Commons.I18n.formatNumber(root.effectiveScale(root.scaleValues[idx])) + "x"
                    }
                    return Commons.I18n.formatNumber(root.selectedMonitor.scale) + "x"
                  }
                  color: Qt.darker(root.barForeground, 1.4)
                  font.family: root.barFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Item {
                width: parent.width
                height: scaleSlider.implicitHeight + Style.spacing.controlGap

                PanelSlider {
                  id: scaleSlider
                  bar: root.bar
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  minimum: 0
                  maximum: Math.max(0, root.scaleValues.length - 1)
                  step: 1
                  integer: true
                  tickCount: root.scaleValues.length
                  value: root.currentScaleIndex()
                  onReleased: function(v) {
                    if (!root.selectedMonitor || root.scaleValues.length === 0) return
                    var idx = Math.max(0, Math.min(root.scaleValues.length - 1, Math.round(v)))
                    root.setMonitorScale(root.selectedMonitor.name, root.scaleValues[idx])
                  }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.xs

              Dropdown {
                id: resolutionDropdown
                width: Math.round((parent.width - parent.spacing) * 0.56)
                label: strings.t("layout.resolution")
                value: root.selectedMonitor ? root.selectedMonitor.pendingResolution : ""
                options: root.resolutionDropdownOptions
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                enabled: root.selectedMonitor ? root.selectedMonitor.enabled : false
                onChanged: function(value) {
                  if (root.selectedMonitor)
                    root.setMonitorResolution(root.selectedMonitor.name, value)
                }
              }

              Dropdown {
                id: refreshDropdown
                width: parent.width - parent.spacing - resolutionDropdown.width
                label: strings.t("layout.refresh")
                value: root.selectedMonitor ? root.selectedMonitor.pendingRefresh : ""
                options: root.refreshDropdownOptions
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                enabled: root.selectedMonitor
                  ? (root.selectedMonitor.enabled && root.refreshDropdownOptions.length > 0)
                  : false
                onChanged: function(value) {
                  if (root.selectedMonitor)
                    root.setMonitorRefresh(root.selectedMonitor.name, value)
                }
              }
            }

            Dropdown {
              id: orientationDropdown
              width: parent.width
              label: strings.t("layout.orientation")
              value: root.selectedMonitor ? String(root.selectedMonitor.transform) : "0"
              options: root.orientationDropdownOptions
              foreground: root.barForeground
              fontFamily: root.barFontFamily
              enabled: root.selectedMonitor ? root.selectedMonitor.enabled : false
              onChanged: function(value) {
                if (root.selectedMonitor)
                  root.setMonitorTransform(root.selectedMonitor.name, value)
              }
            }

            // Dropdown writes its own `value` from JS on pick (Ui/Dropdown
            // selectCurrent), which kills the caller's binding, and
            // ToggleSwitch is caller-owned. Re-push all of them from the model
            // so switching cards cannot show the previous monitor's settings.
            Connections {
              target: root
              function onLayoutStateChanged() { pushDetailControls() }
              function onSelectedLayoutNameChanged() { pushDetailControls() }
              function pushDetailControls() {
                resolutionDropdown.value = root.selectedMonitor ? root.selectedMonitor.pendingResolution : ""
                refreshDropdown.value = root.selectedMonitor ? root.selectedMonitor.pendingRefresh : ""
                orientationDropdown.value = root.selectedMonitor ? String(root.selectedMonitor.transform) : "0"
                selectedEnabledToggle.checked = root.selectedMonitor ? root.selectedMonitor.enabled : false
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.hasLayoutOverlap
              text: root.overlapPair.length === 2
                ? strings.t("layout.overlapNamed").arg(root.overlapPair[0]).arg(root.overlapPair[1])
                : strings.t("layout.overlap")
              color: Commons.Color.urgent
              font.family: root.barFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              wrapMode: Text.Wrap
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              visible: root.layoutStatusKey !== "" || root.layoutStatusDetail !== ""
              text: {
                var base = root.layoutStatusKey !== "" ? strings.t(root.layoutStatusKey) : ""
                return root.layoutStatusDetail !== ""
                  ? (base !== "" ? base + ": " + root.layoutStatusDetail : root.layoutStatusDetail)
                  : base
              }
              color: (root.layoutStatusKey === "layout.failed"
                  || root.layoutStatusKey === "layout.saveFailed"
                  || root.layoutStatusKey === "layout.revertFailed")
                ? Commons.Color.urgent
                : Qt.darker(root.barForeground, 1.35)
              font.family: root.barFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              width: parent.width
            }

            Row {
              width: parent.width
              spacing: Style.spacing.xs

              Button {
                width: (parent.width - parent.spacing) / 2
                text: strings.t("layout.apply")
                fontSize: Style.font.body
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                horizontalPadding: Style.spacing.sm
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                selected: root.layoutDirty && !root.hasLayoutOverlap
                  && !root.applyRunning && !root.confirmPending
                enabled: root.layoutDirty && !root.hasLayoutOverlap
                  && !root.applyRunning && !root.confirmPending
                onClicked: root.applyLayout()
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                text: root.layoutDirty
                  ? strings.t("layout.revert")
                  : strings.t("layout.reload")
                fontSize: Style.font.body
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                horizontalPadding: Style.spacing.sm
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                enabled: !root.applyRunning && !root.confirmPending
                onClicked: root.revertLayout()
              }
            }

            Text {
              textFormat: Text.PlainText
              text: strings.t("layout.rememberHint")
              color: Qt.darker(root.barForeground, 1.5)
              font.family: root.barFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              width: parent.width
            }
          }

          PanelSeparator {
            foreground: root.barForeground
          }

          // ---------- Global text size ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

              PanelSectionHeader {
                id: textSizeHeader
                text: Commons.I18n.t("monitor.textSize")
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: textSizePx
                textFormat: Text.PlainText
                text: Commons.I18n.formatNumber(textSizeSlider.dragging
                       ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                       : root.displayedTextPx()) + "px"
                color: Qt.darker(root.barForeground, 1.4)
                font.family: root.barFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Item {
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap

              PanelSlider {
                id: textSizeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.textSizeStops.length - 1
                step: 1
                integer: true
                tickCount: root.textSizeStops.length
                value: root.currentTextIndex()
                onReleased: function(v) {
                  root.adjustTextSize(Math.round(v) - root.currentTextIndex())
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }

      // Post-Apply trial card. It covers the panel so the layout behind it is
      // visible around the edges but cannot be edited until Keep/Revert.
      Item {
        id: confirmOverlay
        anchors.fill: parent
        visible: root.confirmPending
        z: 100
        focus: true
        onVisibleChanged: if (visible) forceActiveFocus()
        Keys.onReturnPressed: root.keepPendingLayout()
        Keys.onEnterPressed: root.keepPendingLayout()
        Keys.onSpacePressed: root.keepPendingLayout()
        Keys.onEscapePressed: root.revertPendingLayout()

        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(0, 0, 0, 0.55)
        }

        MouseArea {
          anchors.fill: parent
          onClicked: {}
          onWheel: function(wheel) { wheel.accepted = true }
        }

        BorderSurface {
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(32), Style.space(340))
          implicitHeight: confirmColumn.implicitHeight + Style.space(24)
          color: Commons.Color.popups.background
          borderSpec: Border.controlSpec("focus", Commons.Color.popups.text, Commons.Color.accent)
          radius: Style.cornerRadius

          Column {
            id: confirmColumn
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: strings.t("layout.confirmTitle")
              color: Commons.Color.popups.text
              font.family: root.barFontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.confirmSecondsLeft === 1
                ? strings.t("layout.confirmBodyOne")
                : strings.t("layout.confirmBody")
                    .arg(Commons.I18n.formatNumber(root.confirmSecondsLeft))
              color: Qt.darker(Commons.Color.popups.text, 1.3)
              font.family: root.barFontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
              width: parent.width
            }

            Row {
              width: parent.width
              spacing: Style.spacing.xs

              Button {
                id: keepButton
                width: (parent.width - parent.spacing) / 2
                text: strings.t("layout.keep")
                foreground: Commons.Color.popups.text
                fontFamily: root.barFontFamily
                horizontalPadding: Style.spacing.sm
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                selected: true
                focusable: true
                onClicked: root.keepPendingLayout()
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                text: strings.t("layout.revertNow")
                foreground: Commons.Color.popups.text
                fontFamily: root.barFontFamily
                horizontalPadding: Style.spacing.sm
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                focusable: true
                onClicked: root.revertPendingLayout()
              }
            }
          }
        }
      }
    }
  }

  // On-screen display badges shown when Identify is clicked. Only instantiated
  // while identifying is true so no Wayland surfaces stay parked idle.
  Variants {
    model: root.identifying ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        id: identifyWindow
        required property var modelData
        readonly property int displayNumber: root.monitorNumber(modelData ? modelData.name : "")

        screen: modelData
        visible: root.identifying && displayNumber > 0
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omarchy-displays-identify"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        // Visual-only surface: keep the input region empty so it never blocks
        // clicks on the panel or desktop below.
        mask: Region {}

        anchors {
          top: true
          bottom: true
          left: true
          right: true
        }

        BorderSurface {
          anchors.centerIn: parent
          width: Math.max(Style.space(140), identifyContent.implicitWidth + Style.space(48))
          height: identifyContent.implicitHeight + Style.space(36)
          color: Util.alpha(Commons.Color.background, 0.94)
          borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.accent, Math.max(2, Style.space(2)))
          radius: Style.cornerRadius

          Column {
            id: identifyContent
            anchors.centerIn: parent
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              text: String(identifyWindow.displayNumber)
              color: Commons.Color.accent
              font.family: root.barFontFamily
              font.pixelSize: Style.space(56)
              font.bold: true
              anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: identifyWindow.modelData ? identifyWindow.modelData.name : ""
              color: Commons.Color.popups.text
              font.family: root.barFontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              anchors.horizontalCenter: parent.horizontalCenter
            }
          }
        }
      }
    }
  }
}
