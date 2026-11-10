import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
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
  // permits — needed for the brightness + state methods below.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string internalMonitor: ""
  property string externalMonitor: ""
  property string focusedMonitor: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0

  // ---- Layout tab: arrangement, resolution, refresh, presets ----
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property string activeTab: "display"
  // Latch: the Layout tab's UI builds on first activation and stays built.
  property bool layoutBuilt: false

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

  // Drag state shared by the monitor cards.
  property string dragMonitorName: ""
  property point dragPressScene: Qt.point(0, 0)
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
  readonly property string overlapNames: {
    var monitors = enabledLayoutMonitors
    for (var i = 0; i < monitors.length; i++) {
      for (var j = i + 1; j < monitors.length; j++) {
        if (Model.overlaps(monitors[i], monitors[j]))
          return monitors[i].name + " ↔ " + monitors[j].name
      }
    }
    return ""
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

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel
  //                  (mirrors Audio's slider rows). Only present if a
  //                  controllable backlight was detected.
  //   "scale"      - 6 Button scale presets; treated as a single
  //                  horizontal row from j/k's perspective. h/l moves
  //                  between presets, identical to bluetooth's header.
  //   "monitors"   - vertical display row list for enabling/disabling displays;
  //                  j/k walks each row.
  // Mouse hover on a target updates root state via the components' `hovered`
  // signal so keyboard cursor and pointer share one highlight.
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.availableScales(scalePresets, display.width, display.height)
    }
    return scalePresets
  }
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1
  // Same queue as brightness: a stop chosen while the CLI runs must still land.
  property int pendingTextPx: 0
  property bool textSizeQueued: false
  // Trial persistence intent ("save"/"clear"), drained when no child runs.
  property string trialIntent: ""
  property bool trialResumed: false
  // Queued scale pick, so a click during an in-flight pick is not dropped.
  property string pendingScale: ""
  property real dragStartScale: 1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property var visibleSections: {
    if (activeTab !== "display") return []
    var list = []
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    list.push("scale")
    if (displays.length > 1) list.push("monitors")
    return list
  }

  function sectionCount(section) {
    if (section === "brightness") return 0  // only the slider sentinel at -1
    if (section === "textsize") return 0    // slider sentinel at -1, like brightness
    if (section === "scale") return scaleValues.length
    if (section === "monitors") return displays.length
    return 0
  }

  function sectionIsSingleRow(section) {
    // brightness and text size are lone sliders; scale presets sit horizontally.
    return section === "brightness" || section === "textsize" || section === "scale"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize") return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        // Coming up from below — land on the last navigable row of the prev
        // section, or its sentinel for single-row sections.
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  // h/l: in scale section, walks the preset row; everywhere else, no-op
  // because adjustBrightness handles horizontal motion on the brightness
  // slider.
  function moveCursorH(delta) {
    if (focusSection !== "scale") return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > scaleValues.length - 1) next = scaleValues.length - 1
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    // The cursor model only exists on the Display tab. Without this guard a stale
    // focusSection replays there: Space in the Layout tab would blank a monitor
    // or change the scale.
    if (activeTab !== "display") return
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex])
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
    }
    // brightness: no separate action; the slider value is the action.
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      // brightness/text size use the -1 sentinel; scale clamps into the presets.
      if (focusSection === "brightness" || focusSection === "textsize") selectedIndex = -1
      else if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays). Mirrors audio's
  // ensureCursorVisible helper.
  function ensureCursorVisible(item) {
    var scrollArea = panel.loadedContent ? panel.loadedContent.scrollArea : null
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.monitorScale,
      displays: root.displays,
      activeTab: root.activeTab,
      layoutDirty: root.layoutDirty,
      overlap: root.hasLayoutOverlap,
      confirmPending: root.confirmPending,
      confirmSecondsLeft: root.confirmSecondsLeft,
      applyMode: root.applyMode,
      layout: root.layoutMonitors.map(function(monitor) {
        return {
          name: monitor.name,
          x: monitor.x,
          y: monitor.y,
          width: monitor.layoutWidth,
          height: monitor.layoutHeight,
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
    function layout(): string {
      root.activeTab = "layout"
      root.open()
      return "ok"
    }
    function display(): string {
      root.activeTab = "display"
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
    // stateProc (brightness probe) costs ~0.8s; only run it for the Display
    // tab that reads it. The Layout tab's layoutProc answers in ~15ms.
    if (activeTab === "display" && !stateProc.running) stateProc.running = true
    // Poll the layout once the tab exists, dirty or not: otherwise a hotplug
    // with unsaved edits is never seen and the canvas keeps ghost cards.
    if ((layoutBuilt || confirmPending) && !layoutProc.running) layoutProc.running = true
  }

  function refreshLayout() {
    if (!layoutProc.running) layoutProc.running = true
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
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

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  function activeScaleIndex() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.matchingScaleIndex(scaleValues, monitorScale, display.width, display.height)
    }
    return -1
  }

  function effectiveScale(scale) {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.cleanScale(scale, display.width, display.height)
    }
    return normalizeScale(scale)
  }

  // Playful mood-name for a given brightness percent. Bands intentionally
  // span ~10–20 points so casual tweaks change the label, while small
  // nudges within one band don't.
  function brightnessName(percent) {
    return Model.brightnessName(percent, Commons.I18n.t)
  }

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    // The 5s poll hands over fresh arrays; assigning them rebuilds every
    // delegate and resets the hover highlight under a stationary pointer.
    if (root.enabledDisplayCount === parsed.enabledDisplayCount
        && JSON.stringify(root.displays) === JSON.stringify(parsed.displays)) return
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (enabled && root.enabledDisplayCount <= 1) return

    // hyprctl keyword is rejected under the Lua config ("non-legacy parsers"),
    // so drive the monitor through the hl.monitor eval API instead.
    var output = '"' + name.replace(/[\\"]/g, "\\$&") + '"'
    // hl.monitor updates the existing rule. Keep its mode, position and scale
    // when bringing the display back.
    var expr = enabled
      ? 'hl.monitor({ output = ' + output + ', disabled = true })'
      : 'hl.monitor({ output = ' + output + ', disabled = false })'
    actionProc.command = ["hyprctl", "eval", expr]
    if (!actionProc.running) actionProc.running = true
  }

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
    // replace a healthy, unsaved-free layout with that in-between snapshot;
    // re-read once the compositor has settled, and accept it if it persists.
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
    var names = []
    var focusName = ""
    for (var i = 0; i < monitors.length; i++) {
      var monitor = monitors[i]
      next[monitor.name] = monitor
      names.push(monitor.name)
      if (monitor.focused) focusName = monitor.name
    }

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
    activeTab = "layout"
    open()
    confirmTimer.restart()
  }

  function selectLayoutMonitor(name) {
    if (!name) return
    selectedLayoutName = name
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

    var canvasW = canvasViewWidth > 0 ? canvasViewWidth : Style.space(360)
    var canvasH = canvasViewHeight > 0 ? canvasViewHeight : Style.space(190)
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

  function toggleLayoutMonitor(name) {
    var monitor = layoutState[name]
    if (!monitor) return
    setMonitorEnabled(name, !monitor.enabled)
  }

  function arrangeMonitors(reverse) {
    var order = Model.sortedByPosition(enabledLayoutMonitors)
    if (reverse) order.reverse()

    var next = {}
    for (var key in layoutState) next[key] = layoutState[key]
    var x = 0
    for (var i = 0; i < order.length; i++) {
      var monitor = cloneMonitor(order[i])
      monitor.x = x
      monitor.y = 0
      next[monitor.name] = monitor
      x += monitor.layoutWidth
    }
    layoutState = next
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
    activeTab = "layout"
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

  // The confirmation overlay focuses itself (see confirmOverlay): content ids
  // inside KeyboardPanel's Component-wrapped content are not reachable from
  // root functions, so the overlay owns its keyboard handling directly.

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

  // argv rather than a shell string, and its own process so a scale pick is not
  // lost behind an in-flight display toggle.
  function setScale(scale) {
    if (scaleProc.running) {
      root.pendingScale = String(scale)
      return
    }
    scaleProc.command = ["omarchy-hyprland-monitor-scaling", String(scale)]
    scaleProc.running = true
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

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    var value = Math.round(px)
    root.pendingTextPx = value
    if (textScaleProc.running) {
      // A stop chosen while the CLI runs must still land; dropping it left the
      // slider pinned to a stop the shell never applied.
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
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    refresh()
  }

  // A resumed trial arrives through FileView.onLoaded (blockLoading makes the
  // text available on the first read), so there is exactly one resume path.

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      refresh()
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = 0
      }
      cursorActive = false
    } else {
      // A drag whose delegate died mid-press (close while held) never delivers
      // `released`, which would leave the snap guides painted on the canvas.
      dragMonitorName = ""
      snapX = false
      snapY = false
    }
  }
  // Resumed trials never change the overlay's visibility, so claim the keys when
  // the prompt appears rather than only when it is first shown.
  onConfirmPendingChanged: if (confirmPending && opened) confirmOverlay.forceActiveFocus()
  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()
  onActiveTabChanged: {
    clampCursor()
    if (activeTab === "layout") {
      layoutBuilt = true
      if (!layoutDirty) refreshLayout()
    } else if (activeTab === "display") {
      refresh()
    }
  }

  // Only poll while the panel is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh + Component.onCompleted cover the
  // rest. External brightness changes are reflected whenever the panel is open.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
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

  Process {
    id: layoutProc
    command: ["hyprctl", "-j", "monitors", "all"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.setLayoutMonitors(Model.parseMonitors(text))
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
          root.refresh()
          return
        }
        if (root.applyMode === "revert") {
          root.layoutStatusKey = "layout.reverted"
          root.layoutStatusDetail = ""
          root.layoutDirty = false
          root.confirmPending = false
          root.clearTrial()
          root.refresh()
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

  // A stuck child (flock wait, hung hyprctl) must not wedge the Layout tab:
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
      if (exitCode !== 0) {
        // A clear that keeps failing would let a later reload revert a layout
        // the user already kept, so at least say so.
        console.warn("displays: could not clear trial: " + String(trialClearError.text || "").trim())
      }
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

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        // A poll that lands mid-write echoes the pre-change hardware value, so
        // leave the optimistic percentage alone until the write has landed.
        if (!setBrightnessProc.running && !root.brightnessSetQueued && !brightnessDebounce.running)
          root.brightnessPercent = root.brightnessAvailable ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
        root.internalMonitor = String(lines[1] || "").trim()
        root.externalMonitor = String(lines[2] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() === root.externalMonitor && root.externalMonitor !== ""
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
      }
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT call refresh() after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading via
    // `omarchy-brightness-display` races the hardware/driver and can
    // return an empty string, which the parser then coerces to 0 —
    // visible as a "bounce to zero" after h/l keypresses. External
    // brightness changes are still picked up by the 5s periodic refresh,
    // the open-time refresh, and Component.onCompleted.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
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
      // The stop never reached the shell: drop the optimistic preview so the
      // slider and label follow the live base size again.
      root.textSizePreviewIndex = -1
      console.warn("displays: text size failed: " + String(textScaleError.text || "").trim())
    }
  }

  Process {
    id: scaleProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var queued = root.pendingScale
      root.pendingScale = ""
      if (queued !== "") root.setScale(queued)
      if (exitCode !== 0) console.warn("displays: scaling command failed")
      root.refresh()
    }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
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
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
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
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(760))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias scrollArea: scrollArea
      implicitHeight: panelColumn.implicitHeight
      anchors.fill: parent
      // The confirmation card owns the keyboard while it is up; its Keep
      // button takes focus and Enter/Space confirms.
      blocked: root.confirmPending
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.focusSection === "scale") root.moveCursorH(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
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
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.barForeground
              font.family: root.barFontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: root.activeTab === "layout"
                  ? strings.t("layout.title")
                  : Commons.I18n.t("monitor.display")
                textFormat: Text.PlainText
                color: root.barForeground
                font.family: root.barFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                textFormat: Text.PlainText
                text: {
                  if (root.activeTab === "layout")
                    return strings.t("layout.hint").toUpperCase()
                  if (root.brightnessAvailable) {
                    return root.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return Commons.I18n.t("monitor.fixedBrightness")
                }
                color: Qt.darker(root.barForeground, 1.4)
                font.family: root.barFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Tabs ----------
          Row {
            id: tabRow
            width: parent.width
            spacing: Style.spacing.xs

            Button {
              width: (tabRow.width - tabRow.spacing) / 2
              text: strings.t("tab.display")
              fontSize: Style.font.body
              foreground: root.barForeground
              fontFamily: root.barFontFamily
              horizontalPadding: Style.spacing.sm
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              selected: root.activeTab === "display"
              onClicked: root.activeTab = "display"
            }

            Button {
              width: (tabRow.width - tabRow.spacing) / 2
              text: strings.t("tab.layout")
              fontSize: Style.font.body
              foreground: root.barForeground
              fontFamily: root.barFontFamily
              horizontalPadding: Style.spacing.sm
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              selected: root.activeTab === "layout"
              onClicked: root.activeTab = "layout"
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            visible: root.activeTab === "display" && root.brightnessAvailable
            foreground: root.barForeground
          }

          Column {
            visible: root.activeTab === "display" && root.brightnessAvailable
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: Commons.I18n.t("monitor.brightness")
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercent
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

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.barForeground
              outline: true

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
                  root.setBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Text size ----------
          PanelSeparator {
            visible: root.activeTab === "display"
            foreground: root.barForeground
          }

          Column {
            visible: root.activeTab === "display"
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

            CursorSurface {
              id: textSizeRow
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
              foreground: root.barForeground
              outline: true

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
                  // Same path as the keyboard stops: sets the preview and
                  // suppresses hover hijack while the reflow lands.
                  root.adjustTextSize(Math.round(v) - root.currentTextIndex())
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "textsize"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Scale ----------
          PanelSeparator {
            visible: root.activeTab === "display"
            foreground: root.barForeground
          }

          Column {
            visible: root.activeTab === "display"
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

              PanelSectionHeader {
                id: scaleHeader
                text: Commons.I18n.t("monitor.scale")
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Name the monitor SCALE targets, since it only applies to the
              // focused one.
              Text {
                id: scaleMonitor
                textFormat: Text.PlainText
                text: root.focusedMonitor
                // Only worth naming when more than one display is in play.
                visible: root.focusedMonitor !== "" && root.enabledDisplayCount > 1
                color: Qt.darker(root.barForeground, 1.4)
                font.family: root.barFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Grid {
              id: scaleRow
              width: parent.width
              columns: root.scaleValues.length
              spacing: Style.spacing.xs

              readonly property real cellWidth: root.scaleValues.length > 0
                ? (width - spacing * (columns - 1)) / columns
                : 0

              Repeater {
                model: root.scaleValues

                ScalePill {
                  required property string modelData
                  required property int index

                  scaleValue: modelData
                  scaleIndex: index
                  width: scaleRow.cellWidth
                }
              }
            }
          }

          // ---------- Monitors ----------
          PanelSeparator {
            visible: root.activeTab === "display" && root.displays.length > 1
            foreground: root.barForeground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.activeTab === "display" && root.displays.length > 1

            PanelSectionHeader {
              text: Commons.I18n.t("monitor.displays")
              foreground: root.barForeground
              fontFamily: root.barFontFamily
            }

            Repeater {
              model: root.displays

              MonitorRow {
                required property var modelData
                required property int index

                width: panelColumn.width
                display: modelData
                rowIndex: index
              }
            }
          }

          // ---------- Layout ----------
          // Built lazily on first activation so opening the panel (usually
          // the Display tab) stays at stock weight; the latch keeps it built
          // afterwards so tab switches stay instant.
          Loader {
            width: parent.width
            visible: root.activeTab === "layout"
            active: root.layoutBuilt
            sourceComponent: layoutTabComponent
            // Without this, a build failure is indistinguishable from a tab
            // that renders at zero height; only the console would know.
            onStatusChanged: if (status === Loader.Error) {
              root.layoutStatusKey = "layout.failed"
              root.layoutStatusDetail = "layout tab failed to build"
            }
          }

          Component {
            id: layoutTabComponent

            Column {
              width: panelColumn.width
              spacing: Style.space(12)

            Item {
              width: parent.width
              implicitHeight: Math.max(layoutHeader.implicitHeight, layoutHint.implicitHeight)

              PanelSectionHeader {
                id: layoutHeader
                text: strings.t("layout.arrange")
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: layoutHint
                textFormat: Text.PlainText
                text: strings.t("layout.dragHint")
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
              id: arrangementCanvas
              width: parent.width
              height: Style.space(190)
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
                  readonly property var monitor: root.layoutState[modelData] || ({})

                  text: monitor.name || modelData
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

            Row {
              width: parent.width
              spacing: Style.spacing.xs

              Button {
                width: (parent.width - parent.spacing * 2) / 3
                text: strings.t("layout.arrangeButton")
                fontSize: Style.font.caption
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                horizontalPadding: Style.spacing.xs
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                enabled: root.enabledLayoutMonitors.length > 1
                onClicked: root.arrangeMonitors(false)
              }

              Button {
                width: (parent.width - parent.spacing * 2) / 3
                text: strings.t("layout.swap")
                fontSize: Style.font.caption
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                horizontalPadding: Style.spacing.xs
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                enabled: root.enabledLayoutMonitors.length > 1
                onClicked: root.arrangeMonitors(true)
              }

              Button {
                width: (parent.width - parent.spacing * 2) / 3
                text: strings.t("layout.primary")
                fontSize: Style.font.caption
                foreground: root.barForeground
                fontFamily: root.barFontFamily
                horizontalPadding: Style.spacing.xs
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                enabled: root.selectedMonitor !== null
                  && root.selectedMonitor.enabled
                  && !(root.selectedMonitor.x === 0 && root.selectedMonitor.y === 0)
                onClicked: if (root.selectedMonitor) root.makePrimary(root.selectedMonitor.name)
              }
            }

            PanelSeparator {
              foreground: root.barForeground
            }

            Column {
              width: parent.width
              spacing: Style.space(10)
              visible: root.selectedMonitor !== null

              Item {
                width: parent.width
                implicitHeight: Math.max(selectedName.implicitHeight, selectedEnabledToggle.implicitHeight)

                Column {
                  id: selectedName
                  anchors.left: parent.left
                  anchors.right: selectedEnabledLabel.left
                  anchors.rightMargin: Style.space(10)
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
                    text: root.selectedMonitor
                      ? (root.selectedMonitor.description || "")
                        + " · " + (root.selectedMonitor.pendingResolution || "")
                        + " · " + Commons.I18n.formatNumber(root.selectedMonitor.scale) + "x"
                      : ""
                    color: Qt.darker(root.barForeground, 1.4)
                    font.family: root.barFontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                Text {
                  id: selectedEnabledLabel
                  anchors.right: selectedEnabledToggle.left
                  anchors.rightMargin: Style.space(8)
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
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.selectedMonitor ? root.selectedMonitor.enabled : false
                  foreground: root.barForeground
                  accent: Commons.Color.accent
                  onToggled: if (root.selectedMonitor)
                    root.setMonitorEnabled(root.selectedMonitor.name, !root.selectedMonitor.enabled)
                }
              }

              Dropdown {
                id: resolutionDropdown
                width: parent.width
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
                width: parent.width
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

              // Dropdown writes its own `value` from JS on pick (Ui/Dropdown
              // selectCurrent), which kills the caller's binding, and
              // ToggleSwitch is caller-owned. Re-push both from the model so
              // switching cards cannot show the previous monitor's settings.
              Connections {
                target: root
                function onLayoutStateChanged() { pushDetailControls() }
                function onSelectedLayoutNameChanged() { pushDetailControls() }
                function pushDetailControls() {
                  resolutionDropdown.value = root.selectedMonitor ? root.selectedMonitor.pendingResolution : ""
                  refreshDropdown.value = root.selectedMonitor ? root.selectedMonitor.pendingRefresh : ""
                  selectedEnabledToggle.checked = root.selectedMonitor ? root.selectedMonitor.enabled : false
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.hasLayoutOverlap
                text: root.overlapNames !== ""
                  ? strings.t("layout.overlapNamed").arg(root.overlapNames)
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
                color: root.layoutStatusKey === "layout.failed"
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
        // Self-focus: content ids are not reachable from root functions, so
        // the overlay takes focus itself and owns its keys. PanelKeyCatcher
        // is blocked while the prompt is up, so these reach it directly.
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
              text: strings.t("layout.confirmBody")
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

  component ScalePill: Button {
    id: pill
    required property string scaleValue
    required property int scaleIndex

    text: Commons.I18n.formatNumber(root.effectiveScale(scaleValue)) + "x"
    fontSize: Style.font.caption
    foreground: root.barForeground
    fontFamily: root.barFontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.activeScaleIndex() === scaleIndex
    hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === scaleIndex

    onClicked: root.setScale(scaleValue)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "scale"
      root.selectedIndex = pill.scaleIndex
    }
  }

  component MonitorRow: CursorSurface {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)

    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
    current: isFocused
    foreground: root.barForeground
    fill: Style.hoverFillFor(root.barForeground, Commons.Color.accent)
    currentFill: Style.selectedFillFor(root.barForeground, Commons.Color.accent)
    implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: monitorInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: "󰍹"
        color: root.barForeground
        font.family: root.barFontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.focused
          ? Commons.I18n.t("monitor.displayFocused").arg(monitorRow.display.name)
          : monitorRow.display.name
        color: root.barForeground
        font.family: root.barFontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.enabled ? "󰄬" : ""
        color: root.barForeground
        font.family: root.barFontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
        root.cursorActive = true
        root.focusSection = "monitors"
        root.selectedIndex = monitorRow.rowIndex
      }
      onClicked: if (monitorRow.canToggle) root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
    }
  }
}
