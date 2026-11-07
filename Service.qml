import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Watches the connected monitor set and restores the saved preset for it.
// Runs independently of the bar panel, so plugging a dock back in restores
// the arrangement without opening the widget.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string presetsPath: home + "/.config/omarchy/monitor-presets.json"

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    if (url.indexOf("file://") !== 0) return ""
    return decodeURIComponent(url.substring(7)).replace(/\/+$/, "")
  }

  property var presets: []
  property var pendingMonitors: []
  property string lastKey: ""
  property bool applying: false
  property bool pendingApply: false

  function loadPresets(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      root.presets = (parsed && Array.isArray(parsed.presets)) ? parsed.presets : []
    } catch (e) {
      root.presets = []
    }
  }

  function handleMonitors(raw) {
    var monitors = Model.parseMonitors(raw)
    if (monitors.length === 0) return

    var key = Model.comboKey(monitors)
    if (key === root.lastKey) return
    root.lastKey = key

    root.loadPresets(presetsFile.text())
    var preset = Model.bestPreset(root.presets, monitors)
    if (!preset) return
    if (Model.layoutMatchesPreset(preset, monitors)) return

    root.pendingMonitors = monitors
    settleTimer.restart()
  }

  function applyPending() {
    if (root.applying) {
      root.pendingApply = true
      return
    }

    var monitors = root.pendingMonitors
    if (!monitors || monitors.length === 0 || root.pluginDir === "") return

    root.loadPresets(presetsFile.text())
    var preset = Model.bestPreset(root.presets, monitors)
    if (!preset) return

    var rules = Model.presetRules(preset, monitors)
    if (!rules || rules.length === 0) return

    console.log("io.github.callumau.displays: restoring preset for " + root.lastKey)
    root.applying = true
    // --live-only: automatic restores move displays now but never rewrite the
    // user's monitors.conf. Only an explicit Apply saves configuration.
    applyProc.command = ["bash", root.pluginDir + "/apply-displays.sh", JSON.stringify(rules), "--live-only"]
    applyProc.running = true
  }

  Component.onCompleted: {
    console.log("io.github.callumau.displays: preset watcher ready")
    pollProc.running = true
  }

  Timer {
    interval: 2500
    running: true
    repeat: true
    onTriggered: if (!pollProc.running) pollProc.running = true
  }

  Timer {
    id: settleTimer
    interval: 1200
    repeat: false
    onTriggered: root.applyPending()
  }

  FileView {
    id: presetsFile
    path: root.presetsPath
    watchChanges: true
    printErrors: false
    blockLoading: true
    onLoaded: root.loadPresets(text())
    onFileChanged: reload()
  }

  Process {
    id: pollProc
    command: ["hyprctl", "-j", "monitors", "all"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleMonitors(text)
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { id: applyStdout; waitForEnd: true }
    stderr: StdioCollector { id: applyStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.applying = false
      if (exitCode !== 0) {
        console.log("io.github.callumau.displays: preset apply failed: "
          + String(applyStderr.text || "").trim().slice(0, 300))
      } else {
        console.log("io.github.callumau.displays: preset restored for " + root.lastKey)
      }
      if (root.pendingApply) {
        root.pendingApply = false
        settleTimer.restart()
      }
    }
  }
}
