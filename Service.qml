import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

// Two jobs, no UI:
//
// 1. Once per discharge, switch to power-saver when the battery drops to
//    `threshold`. It sets the profile directly rather than through
//    omarchy-powerprofiles-set, so the profile Omarchy remembers for battery
//    stays as it was. Plugging in rearms it.
//
// 2. While power-saver is active, turn off the desktop effects picked in the
//    settings. They go into one file in Omarchy's Hyprland toggles directory,
//    which Omarchy loads after the user's config, the way its own toggles work.
//    The file only ever turns things off, so removing it brings back exactly
//    what the user had, including effects they turned off themselves.
//
// The file is removed when the service is unloaded, which is the only hook a
// plugin gets when it is disabled or removed. That also happens on a plugin
// reload, shell restart or logout, so in power-saver the new instance writes it
// again. A lock keeps the two runs in order.
Item {
  id: root

  readonly property string pluginId: "seagleNet.power-saver"
  readonly property int defaultThreshold: 20

  // Every effect the plugin can turn off, in the order they are logged, and
  // whether it does so unless told otherwise. Transparency is left alone by
  // default, as Omarchy's own animations toggle does.
  readonly property var effectNames: ["animations", "blur", "shadows", "glow", "motionBlur", "wobble", "transparency"]
  readonly property var effectDefaults: ({
      "animations": true,
      "blur": true,
      "shadows": true,
      "glow": true,
      "motionBlur": true,
      "wobble": true,
      "transparency": false
    })

  // Settings live on this plugin's entry in ~/.config/omarchy/shell.json: a
  // "threshold" percentage and a "disable" object of effect names to booleans.
  // The shell hands service plugins no settings, so the file is read here. It
  // is only ever read, never written.
  property int threshold: defaultThreshold
  property var effects: defaultEffects()
  readonly property string effectsKey: effects.join(" ")
  // The last settings problems reported, so a file reload repeats none.
  property string settingsWarning: ""
  // Set once the startup line is logged, which already names the settings.
  property bool started: false

  // Events are logged as INFO and problems as WARN in the shell's log:
  // qs log -p "$OMARCHY_PATH/shell" | grep seagleNet.power-saver:
  function log(message) {
    console.info(pluginId + ": " + message)
  }

  function warn(message) {
    console.warn(pluginId + ": " + message)
  }

  function defaultEffects() {
    return effectNames.filter(function (name) {
      return effectDefaults[name]
    })
  }

  function describeEffects(list) {
    return list.length > 0 ? list.join(", ") : "nothing"
  }

  // A missing or empty file means the defaults; one that does not parse keeps
  // the current settings, since it is most likely being edited.
  function readSettings() {
    var nextThreshold = defaultThreshold
    var chosen = Object.assign({}, effectDefaults)
    var problems = []
    var raw = String(settingsFile.text() || "")
    if (raw.trim() !== "") {
      var entry = null
      try {
        var parsed = JSON.parse(raw)
        var entries = parsed && Array.isArray(parsed.plugins) ? parsed.plugins : []
        for (var i = 0; i < entries.length; i++) {
          if (entries[i] && String(entries[i].id || "") === pluginId) {
            entry = entries[i]
            break
          }
        }
      } catch (e) {
        var parseProblem = "could not parse shell.json (" + e.message + "); keeping the current settings"
        if (parseProblem !== settingsWarning)
          warn(parseProblem)
        settingsWarning = parseProblem
        return
      }
      if (entry && entry.threshold !== undefined) {
        var n = Number(entry.threshold)
        if (isFinite(n) && n >= 5 && n <= 95)
          nextThreshold = Math.round(n)
        else
          problems.push("ignoring threshold " + JSON.stringify(entry.threshold) + ", expected a number from 5 to 95; using " + defaultThreshold + "%")
      }
      if (entry && entry.disable !== undefined) {
        var disable = entry.disable
        if (!disable || typeof disable !== "object" || Array.isArray(disable)) {
          problems.push("ignoring \"disable\", expected an object such as {\"transparency\": true}; using the defaults")
        } else {
          for (var key in disable) {
            if (effectNames.indexOf(key) === -1)
              problems.push("ignoring unknown effect \"" + key + "\" in \"disable\", expected one of " + effectNames.join(", "))
            else if (typeof disable[key] !== "boolean")
              problems.push("ignoring \"disable\"." + key + ", expected true or false")
            else
              chosen[key] = disable[key]
          }
        }
      }
    }

    var message = problems.join("; ")
    if (message !== "" && message !== settingsWarning)
      warn("settings in shell.json: " + message)
    settingsWarning = message

    var nextEffects = effectNames.filter(function (name) {
      return chosen[name]
    })
    if (started && nextThreshold !== threshold)
      log("threshold " + nextThreshold + "%")
    if (started && nextEffects.join(" ") !== effectsKey)
      log("in power-saver, turning off: " + describeEffects(nextEffects))
    threshold = nextThreshold
    effects = nextEffects
  }

  FileView {
    id: settingsFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    blockLoading: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readSettings()
    onLoadFailed: root.readSettings()
  }

  property bool saver: PowerProfiles.profile === PowerProfile.PowerSaver
  // What the last finished run applied, "normal" or "saver" plus the effects;
  // "" until the first one.
  property string applied: ""
  property var pending: null

  PersistentProperties {
    id: persisted
    reloadableId: "seagleNet-power-saver"
    property bool switchedThisDischarge: false
  }

  function batteryLevel() {
    var device = UPower.displayDevice
    if (!device || !device.isPresent)
      return -1
    return Math.round(Number(device.percentage || 0) * 100)
  }

  function discharging() {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery && device.state === UPowerDeviceState.Discharging)
  }

  function profileName() {
    switch (PowerProfiles.profile) {
    case PowerProfile.PowerSaver:
      return "power-saver"
    case PowerProfile.Performance:
      return "performance"
    default:
      return "balanced"
    }
  }

  function rearm() {
    if (persisted.switchedThisDischarge)
      log("on AC, low-battery switch rearmed")
    persisted.switchedThisDischarge = false
  }

  function checkBattery() {
    if (!UPower.onBattery) {
      rearm()
      return
    }
    if (persisted.switchedThisDischarge || !discharging())
      return
    var level = batteryLevel()
    if (level < 0 || level > threshold)
      return
    persisted.switchedThisDischarge = true
    if (saver) {
      log("battery at " + level + "%, already in power-saver")
      return
    }
    log("battery at " + level + "% (threshold " + threshold + "%), switching from " + profileName() + " to power-saver")
    PowerProfiles.profile = PowerProfile.PowerSaver
  }

  function apply() {
    if (!started)
      return
    var want = saver ? "saver " + effectsKey : "normal"
    if (want === applied)
      return
    pending = {
      "key": want,
      "args": saver ? ["saver"].concat(effects) : ["normal"]
    }
    if (!effectsProcess.running)
      runPending()
  }

  function runPending() {
    var run = pending
    pending = null
    effectsProcess.key = run.key
    effectsProcess.mode = run.args[0]
    effectsProcess.command = ["bash", "-c", effectsScript, "power-saver"].concat(run.args)
    effectsProcess.running = true
  }

  // `saver <effects...>` writes the toggle file for those effects, `normal`
  // removes it; Hyprland is reloaded only when the file changed. Effects the
  // running Hyprland has no option for are left out. Prints "off <effect>",
  // "skipped <effect>" and "restored" for what it did, and "error: ..." for a
  // step that failed, which stops the run.
  readonly property string effectsScript: '
    changed=0
    fail() {
      echo "error: $*"
      ((changed)) && hyprctl reload config-only >/dev/null 2>&1
      exit 1
    }
    # Runs a command quietly; on failure stops with its own error message.
    try() {
      local err
      err=$("$@" 2>&1 >/dev/null) || fail "$1 failed: ${err:-exit code $?}"
    }
    supported() {
      ! hyprctl getoption "$1" | grep -q "no such option"
    }
    exec 9>"${XDG_RUNTIME_DIR:-/tmp}/seagleNet-power-saver.lock" && flock 9 || fail "could not take the lock"
    toggles="$HOME/.local/state/omarchy/toggles/hypr"
    file="$toggles/power-saver.lua"
    printf -v nl "\\n"
    mode=$1
    shift
    content=""
    if [[ $mode == saver ]]; then
      for effect in "$@"; do
        option="" line=""
        case $effect in
          animations) option=animations.enabled line="hl.config({ animations = { enabled = false } })" ;;
          blur) option=decoration.blur.enabled line="hl.config({ decoration = { blur = { enabled = false } } })" ;;
          shadows) option=decoration.shadow.enabled line="hl.config({ decoration = { shadow = { enabled = false } } })" ;;
          glow) option=decoration.glow.enabled line="hl.config({ decoration = { glow = { enabled = false } } })" ;;
          motionBlur) option=decoration.motion_blur.enabled line="hl.config({ decoration = { motion_blur = { enabled = false } } })" ;;
          wobble) option=decoration.wobble.enabled line="hl.config({ decoration = { wobble = { enabled = false } } })" ;;
          transparency) line="o.window({ tag = \\"transparent-window\\" }, { opacity = \\"1 1\\" })" ;;
          *) fail "unknown effect $effect" ;;
        esac
        if [[ -n $option ]] && ! supported "$option"; then
          echo "skipped $effect"
          continue
        fi
        content+="$line"$nl
        echo "off $effect"
      done
    fi
    if [[ -n $content ]]; then
      content="-- Written by the seagleNet.power-saver shell plugin while power-saver is active."$nl"$content"
      if [[ $(cat "$file" 2>/dev/null)$nl != "$content" ]]; then
        try mkdir -p "$toggles"
        try tee "$file" <<<"${content%$nl}"
        changed=1
      fi
    elif [[ -f $file ]]; then
      try rm -f "$file"
      changed=1
      echo "restored"
    fi
    if ((changed)); then
      try hyprctl reload config-only
    fi
    exit 0
  '

  function reportRun(mode, output) {
    var off = []
    var skipped = []
    var restored = false
    var error = ""
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line.indexOf("error: ") === 0)
        error = line.slice(7)
      else if (line.indexOf("off ") === 0)
        off.push(line.slice(4))
      else if (line.indexOf("skipped ") === 0)
        skipped.push(line.slice(8))
      else if (line === "restored")
        restored = true
    }
    var what = mode === "saver" ? "power-saver on" : "power-saver off"
    var done = []
    if (off.length > 0)
      done.push("turned off " + off.join(", "))
    if (skipped.length > 0)
      done.push("skipped " + skipped.join(", ") + " (not in this Hyprland)")
    if (restored)
      done.push("effects restored")
    if (error !== "")
      warn(what + " failed: " + error + (done.length > 0 ? " (done before that: " + done.join("; ") + ")" : ""))
    else if (done.length > 0)
      log(what + ": " + done.join("; "))
  }

  Process {
    id: effectsProcess
    property string key: ""
    property string mode: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.reportRun(effectsProcess.mode, text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "")
          root.warn("unexpected output from the effects script: " + message.slice(0, 500))
      }
    }
    onExited: {
      root.applied = key
      // Deferred: the process still reports running while it signals exit.
      if (root.pending !== null)
        Qt.callLater(root.runPending)
    }
  }

  onSaverChanged: apply()
  onEffectsKeyChanged: apply()

  Connections {
    target: UPower
    function onOnBatteryChanged() {
      // Leave the immediate switch to Omarchy's battery service, which picks
      // the remembered battery profile on unplug; the timer checks after it.
      if (!UPower.onBattery)
        root.rearm()
    }
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkBattery()
  }

  // Gives the cleanup of an instance unloaded just before this one time to
  // take the lock first, and UPower time to report the battery.
  Timer {
    id: startupDelay
    interval: 1000
    onTriggered: {
      var level = root.batteryLevel()
      var power = level < 0 ? "no battery" : level + "% " + (UPower.onBattery ? "on battery" : "on AC")
      root.log("started: profile " + root.profileName() + ", " + power + ", threshold " + root.threshold + "%, in power-saver turning off: " + root.describeEffects(root.effects))
      root.started = true
      root.apply()
    }
  }

  Component.onCompleted: {
    readSettings()
    startupDelay.start()
  }

  // Detached, so the cleanup outlives this object. It reports nothing back,
  // since nothing is left to receive it.
  Component.onDestruction: {
    log(applied.indexOf("saver") === 0 ? "stopped, restoring effects" : "stopped")
    Quickshell.execDetached(["bash", "-c", effectsScript, "power-saver", "normal"])
  }
}
