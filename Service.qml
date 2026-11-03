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
//    If "dim" is set, it also lowers the built-in panel's backlight, and puts
//    it back afterwards unless the user changed it in the meantime. If
//    "refreshRate" is set, the same file also puts the built-in panel on the
//    fastest mode it lists at that rate or below.
//
// The file is removed when the service is unloaded, which is the only hook a
// plugin gets when it is disabled or removed. That also happens on a plugin
// reload, shell restart or logout, so in power-saver the new instance writes it
// again. A lock keeps the two runs in order.
Item {
  id: root

  readonly property string pluginId: "seaglenet.power-saver"
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
  // "threshold" percentage, a "disable" object of effect names to booleans and
  // a "dim" percentage for the backlight and a "refreshRate" in Hz, each false
  // for none.
  // The shell hands service plugins no settings, so the file is read here. It
  // is only ever read, never written.
  property int threshold: defaultThreshold
  property var effects: defaultEffects()
  // The backlight percentage to dim to in power-saver; 0 leaves it alone.
  property int dim: 0
  // The highest refresh rate in power-saver, in Hz; 0 leaves it alone.
  property int refreshRate: 0
  // Whether power-saver switching on and off shows a notification.
  property bool notifications: true
  readonly property var extraArgs: (dim > 0 ? ["dim=" + dim] : []).concat(refreshRate > 0 ? ["refresh=" + refreshRate] : [])
  readonly property string effectsKey: effects.concat(extraArgs).join(" ")
  // The last settings problems reported, so a file reload repeats none.
  property string settingsWarning: ""
  // Set once the startup line is logged, which already names the settings.
  property bool started: false

  // Events are logged as INFO and problems as WARN in the shell's log:
  // qs log -p "$OMARCHY_PATH/shell" | grep seaglenet.power-saver:
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

  function describeDim(level) {
    return level > 0 ? "dimming the screen to " + level + "%" : "not dimming the screen"
  }

  readonly property string feedbackUrl: "https://github.com/seagleNet/omarchy-power-saver/issues/new?template=refresh-rate.yml"

  function noteExperimental() {
    log("refreshRate is experimental and not yet tried on a high-refresh laptop; please report how it works: " + feedbackUrl)
  }

  function describeRefresh(rate) {
    return rate > 0 ? "refresh rate at most " + rate + " Hz" : "keeping the refresh rate"
  }

  // A missing or empty file means the defaults; one that does not parse keeps
  // the current settings, since it is most likely being edited.
  function readSettings() {
    var nextThreshold = defaultThreshold
    var nextDim = 0
    var nextRefresh = 0
    var nextNotifications = true
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
      if (entry && entry.dim !== undefined && entry.dim !== false) {
        var level = entry.dim
        if (typeof level === "number" && isFinite(level) && level >= 1 && level <= 100)
          nextDim = Math.round(level)
        else
          problems.push("ignoring dim " + JSON.stringify(entry.dim) + ", expected a percentage from 1 to 100 or false; not dimming the screen")
      }
      if (entry && entry.refreshRate !== undefined && entry.refreshRate !== false) {
        var rate = entry.refreshRate
        if (typeof rate === "number" && isFinite(rate) && rate >= 30 && rate <= 1000)
          nextRefresh = Math.round(rate)
        else
          problems.push("ignoring refreshRate " + JSON.stringify(entry.refreshRate) + ", expected a rate in Hz from 30 to 1000 or false; keeping the refresh rate")
      }
      if (entry && entry.notify !== undefined) {
        if (typeof entry.notify === "boolean")
          nextNotifications = entry.notify
        else
          problems.push("ignoring notify " + JSON.stringify(entry.notify) + ", expected true or false; showing notifications")
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
    if (started && nextEffects.join(" ") !== effects.join(" "))
      log("in power-saver, turning off: " + describeEffects(nextEffects))
    if (started && nextDim !== dim)
      log("in power-saver, " + describeDim(nextDim))
    if (started && nextRefresh !== refreshRate) {
      log("in power-saver, " + describeRefresh(nextRefresh))
      if (refreshRate === 0)
        noteExperimental()
    }
    threshold = nextThreshold
    effects = nextEffects
    dim = nextDim
    refreshRate = nextRefresh
    if (started && nextNotifications !== notifications)
      log(nextNotifications ? "notifications on" : "notifications off")
    notifications = nextNotifications
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
    reloadableId: "seaglenet-power-saver"
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
    autoSwitch = {
      "level": level,
      "from": profileName(),
      "at": Date.now()
    }
    PowerProfiles.profile = PowerProfile.PowerSaver
  }

  // Set by checkBattery as it switches, so the notification can say why.
  property var autoSwitch: null
  // Set when the profile switches, for the run that follows to announce.
  property var notice: null

  function profileSwitched() {
    if (started) {
      // The profile change arrives over D-Bus, so allow it a moment.
      var auto = saver && autoSwitch !== null && Date.now() - autoSwitch.at < 10000 ? autoSwitch : null
      notice = {
        "auto": auto
      }
    }
    autoSwitch = null
    apply()
  }

  function apply() {
    if (!started)
      return
    var want = saver ? "saver " + effectsKey : "normal"
    if (want === applied) {
      // Switched back before anything changed: nothing to announce.
      notice = null
      return
    }
    pending = {
      "key": want,
      "args": saver ? ["saver"].concat(effects, extraArgs) : ["normal"],
      "notice": notice || (pending ? pending.notice : null)
    }
    notice = null
    if (!effectsProcess.running)
      runPending()
  }

  function runPending() {
    var run = pending
    if (effectsScript === "")
      return
    pending = null
    effectsProcess.key = run.key
    effectsProcess.mode = run.args[0]
    effectsProcess.notice = run.notice
    effectsProcess.command = ["bash", "-c", effectsScript, "power-saver"].concat(run.args)
    effectsProcess.running = true
  }

  // The effects script, see effects.sh. Its text is loaded once here and run
  // with `bash -c`, so the cleanup on unload does not depend on the file: when
  // the plugin is removed, its directory is deleted right after the unload.
  FileView {
    id: effectsFile
    path: decodeURIComponent(Qt.resolvedUrl("effects.sh").toString().replace(/^file:\/\//, ""))
    blockLoading: true
    printErrors: false
    onLoadFailed: root.warn("could not read effects.sh; effects will not be turned off")
  }
  readonly property string effectsScript: String(effectsFile.text() || "")

  function reportRun(mode, output, notice) {
    var off = []
    var dimmedTo = ""
    var refreshTo = ""
    var back = []
    var skipped = []
    var restored = false
    var screen = []
    var problems = []
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
      else if (line.indexOf("dimmed ") === 0) {
        dimmedTo = line.split(" ")[2]
        screen.push("dimmed the screen from " + line.slice(7).replace(" ", "% to ") + "%")
      } else if (line.indexOf("not dimmed ") === 0)
        screen.push("screen already at " + line.slice(11) + "%, not dimmed")
      else if (line.indexOf("brightness restored ") === 0) {
        back.push("brightness")
        screen.push("brightness restored to " + line.slice(20) + "%")
      } else if (line.indexOf("brightness kept ") === 0)
        screen.push("brightness left at " + line.slice(16) + "%, since it was changed while dimmed")
      else if (line === "no backlight")
        screen.push("no backlight to dim")
      else if (line.indexOf("refresh kept ") === 0)
        screen.push("refresh rate already " + line.slice(13) + " Hz, not lowered")
      else if (line.indexOf("refresh unsupported ") === 0)
        screen.push("the laptop screen has no refresh rate at or below " + line.slice(20) + " Hz at its resolution, not lowered")
      else if (line.indexOf("refresh failed ") === 0)
        problems.push("the laptop screen did not switch to " + line.slice(15) + " Hz, so its refresh rate was left as it was")
      else if (line === "refresh mirrored")
        screen.push("the laptop screen mirrors another display, refresh rate not lowered")
      else if (line.indexOf("refresh restored ") === 0) {
        back.push("refresh rate")
        screen.push("refresh rate restored to " + line.slice(17) + " Hz")
      } else if (line.indexOf("refresh ") === 0) {
        refreshTo = line.split(" ")[2]
        screen.push("refresh rate lowered from " + line.slice(8).replace(" ", " to ") + " Hz")
      } else if (line === "no laptop screen")
        screen.push("no laptop screen to lower the refresh rate of")
    }
    var what = mode === "saver" ? "power-saver on" : "power-saver off"
    var done = []
    if (off.length > 0)
      done.push("turned off " + off.join(", "))
    if (skipped.length > 0)
      done.push("skipped " + skipped.join(", ") + " (not in this Hyprland)")
    if (restored)
      done.push("effects restored")
    // A refused rate was taken out again, so it was never lowered.
    if (problems.length > 0)
      screen = screen.filter(function (entry) {
        return entry.indexOf("refresh rate lowered") !== 0
      })
    done = done.concat(screen)
    for (var j = 0; j < problems.length; j++)
      warn(what + ": " + problems[j])
    if (error !== "")
      warn(what + " failed: " + error + (done.length > 0 ? " (done before that: " + done.join("; ") + ")" : ""))
    else if (done.length > 0)
      log(what + ": " + done.join("; "))

    if (notice && notifications) {
      var sentences = []
      if (notice.auto)
        sentences.push("Battery at " + notice.auto.level + "%, switched from " + notice.auto.from + ".")
      if (mode === "saver") {
        if (off.length > 0)
          sentences.push(capitalize(joinAnd(off.map(effectLabel))) + " off.")
        if (dimmedTo !== "")
          sentences.push("Screen dimmed to " + dimmedTo + "%.")
        if (refreshTo !== "" && problems.length === 0)
          sentences.push("Refresh rate lowered to " + refreshTo + " Hz.")
      } else {
        if (restored)
          back.unshift("effects")
        if (back.length > 0)
          sentences.push(capitalize(joinAnd(back)) + " restored.")
      }
      if (error !== "" || problems.length > 0)
        sentences.push("Not everything could be changed, see the log.")
      notify(mode === "saver" ? "Power-saver on" : "Power-saver off", sentences.join(" "), notice.auto ? "normal" : "low")
    }
  }

  function effectLabel(name) {
    return name === "motionBlur" ? "motion blur" : name
  }

  // ["a", "b", "c"] -> "a, b and c"
  function joinAnd(list) {
    return list.length < 2 ? list.join("") : list.slice(0, -1).join(", ") + " and " + list[list.length - 1]
  }

  function capitalize(text) {
    return text.charAt(0).toUpperCase() + text.slice(1)
  }

  // Through Omarchy's own sender, as its battery warning does; it passes the
  // text to D-Bus as plain values, never through a shell. The glyph is the
  // leaf Omarchy's power panel shows for power-saver.
  function notify(headline, body, urgency) {
    Quickshell.execDetached(["omarchy-notification-send", "-g", "󰌪", "-u", urgency, headline, body])
  }

  Process {
    id: effectsProcess
    property string key: ""
    property string mode: ""
    property var notice: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.reportRun(effectsProcess.mode, text, effectsProcess.notice)
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

  onSaverChanged: profileSwitched()
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
      root.log("started: profile " + root.profileName() + ", " + power + ", threshold " + root.threshold + "%, in power-saver turning off: " + root.describeEffects(root.effects) + ", " + root.describeDim(root.dim) + ", " + root.describeRefresh(root.refreshRate))
      if (root.refreshRate > 0)
        root.noteExperimental()
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
    log(applied.indexOf("saver") === 0 ? "stopped, restoring effects" + (applied.indexOf(" dim=") !== -1 ? " and brightness" : "") + (applied.indexOf(" refresh=") !== -1 ? " and refresh rate" : "") : "stopped")
    if (effectsScript !== "")
      Quickshell.execDetached(["bash", "-c", effectsScript, "power-saver", "normal"])
  }
}
