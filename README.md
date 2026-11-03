# Power Saver

An [Omarchy](https://omarchy.org/) shell plugin that saves battery in two ways:

- **Low battery:** switches to the `power-saver` profile once when the battery
  drops to 20% (configurable) while discharging. Plugging in rearms it. If you
  pick another profile while still below the threshold, it leaves your choice
  alone.
- **Lighter desktop in power-saver:** whenever `power-saver` is active, however
  it was selected, it turns off the Hyprland effects you choose: by default
  animations, blur, shadows, glow, motion blur and wobble. Leaving
  `power-saver` brings back exactly what you had, including effects you turned
  off yourself.
- **Dimmer, slower screen in power-saver (optional):** it can also lower the
  laptop screen's brightness and refresh rate while `power-saver` is active,
  and put them back when `power-saver` ends.

It is a background service with no bar widget. When `power-saver` switches on
or off it shows a notification saying what changed, and for the low-battery
switch, why.

## Requirements

- Omarchy 4 with the Lua Hyprland config
- `power-profiles-daemon` and UPower (both part of Omarchy)
- `brightnessctl` for `dim` (part of Omarchy)

## Install

```sh
omarchy plugin add https://github.com/seagleNet/omarchy-power-saver --enable
```

This installs it to `~/.config/omarchy/plugins/seaglenet.power-saver` and
enables it.

`omarchy plugin add` and `omarchy plugin update` install the newest commit on
`master`, not a fixed version. `master` only moves on a release, so this is the
latest release. To check what you have:

```sh
git -C ~/.config/omarchy/plugins/seaglenet.power-saver describe --tags --always
```

It prints the release, such as `v1.0.1`, which should match the latest
[release](https://github.com/seagleNet/omarchy-power-saver/releases) and the
version on the [marketplace page](https://omarchyplugins.com/plugin.html?id=seaglenet.power-saver).
Anything longer, such as `v1.0.1-2-gabc1234`, is a commit after that release.

## Settings

Settings go on the plugin's entry in `~/.config/omarchy/shell.json`:

```json
"plugins": [
  {
    "id": "seaglenet.power-saver",
    "threshold": 25,
    "dim": 40,
    "notify": true,
    "refreshRate": 60,
    "disable": { "transparency": true, "animations": false }
  }
]
```

- `threshold`: the battery percentage, from 5 to 95, at which to switch to
  `power-saver`. Defaults to 20. The battery is checked every 30 seconds.
- `dim`: the brightness, from 1 to 100%, to lower the built-in screen to in
  `power-saver`, or `false` to leave it alone. Defaults to `false`. A screen
  that is already as dim or dimmer is left as it is. When `power-saver` ends,
  the brightness goes back to what it was, unless you changed it in the
  meantime; then your setting stays. External monitors are not dimmed.
- `notify`: `false` to switch off the notifications when `power-saver` starts
  and ends. Defaults to `true`. They say what the plugin changed, such as
  "Animations, blur and shadows off. Screen dimmed to 40%.", and after the
  low-battery switch also the battery level and the profile it switched from.
  None is shown when the shell or plugin restarts.
- `refreshRate` (experimental): the highest refresh rate, from 30 Hz, for the
  built-in screen in `power-saver`, or `false` to leave it alone. Defaults to
  `false`. Only rates the screen offers at its current resolution are used:
  the fastest one at or below this, within half a hertz, so `60` also takes a
  60.03 Hz mode. If it has none that slow, or already runs at most that fast,
  nothing changes and the log says so. After switching, the plugin checks that
  the screen runs at the new rate, and if not switches it back and logs a
  warning. Switching blanks the screen for a moment, going into `power-saver`
  and out of it. External monitors, and a laptop screen that mirrors one, keep
  their rate. It has not been tried on a high-refresh laptop yet, so
  [feedback](#refresh-rate-feedback) is very welcome. See
  [Recovering the screen](#recovering-the-screen) if a rate leaves it black.
- `disable`: which effects to turn off in `power-saver`. Each key is `true` or
  `false`; effects you leave out keep their default.
  - `animations`: window, workspace and layer animations (default `true`)
  - `blur`: background blur (default `true`)
  - `shadows`: window shadows (default `true`)
  - `glow`: window glow (default `true`)
  - `motionBlur`: motion blur (default `true`)
  - `wobble`: wobbly windows (default `true`)
  - `transparency`: makes the windows Omarchy draws see-through opaque
    (default `false`)

Effects the running Hyprland has no option for, such as wobble before 0.57,
are skipped. Changes apply without a restart, also while `power-saver` is
active. Invalid values are logged and replaced by their defaults. The plugin
only reads `shell.json`, it never writes to it.

## How it works

The profile is set through Quickshell's `PowerProfiles` service, not through
`omarchy-powerprofiles-set`, so the profile Omarchy remembers for battery use
stays as you chose it.

While `power-saver` is active the plugin keeps one file,
`~/.local/state/omarchy/toggles/hypr/power-saver.lua`. Omarchy loads every file
in that directory after your Hyprland config, the same way its own toggles such
as `omarchy toggle animations` work. The file only turns effects off, so
removing it restores your own settings.

The file is removed when `power-saver` ends, and whenever the plugin is
unloaded: on disable or removal, but also on a plugin reload, shell restart or
logout. In `power-saver` the plugin writes it again as soon as it is loaded,
so a reload then briefly brings the effects back.

With `dim`, the screen is dimmed through `brightnessctl`, on the backlight
`omarchy-hw-display` picks. The brightness from before is kept in
`$XDG_RUNTIME_DIR/seaglenet-power-saver.brightness` and put back at the same
times the effects are, so a reload in `power-saver` also briefly brightens the
screen. If you changed the brightness while dimmed, a reload dims it again.

With `refreshRate`, the toggle file also holds a monitor rule for the built-in
screen that sets only its mode, so its position and scale stay yours. The
monitor panel's saved settings load after the toggle files, so the rule applies
again once the config has loaded and wins over a mode chosen there.

### Recovering the screen

A screen can list a rate it does not really show, and the plugin cannot tell
when the screen accepts the mode but stays black. To get the picture back,
switch to a text console with Ctrl+Alt+F2 (Ctrl+Alt+F1 or F7 returns to the
desktop), log in, and run:

```sh
rm ~/.local/state/omarchy/toggles/hypr/power-saver.lua
HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -n 1) hyprctl reload
```

Then remove `refreshRate` from `shell.json`, or set a higher rate, before the
plugin switches back into `power-saver`.

### Refresh rate feedback

`refreshRate` is experimental: it is only tested against a stand-in for
Hyprland, not yet on a laptop whose screen can switch rates. If you try it,
whether it works or not, please
[open a refresh rate report](https://github.com/seagleNet/omarchy-power-saver/issues/new?template=refresh-rate.yml).
It asks for your laptop model, what happened, your screen's modes and the
plugin's log. If you have such a laptop, running `bats tests/integration` (see
[Development](#development)) also helps; one of its tests switches the screen
down and back.

## Logs

The plugin logs to the Omarchy shell's log: what it changes and why as `INFO`,
and problems such as invalid settings or a failed step as `WARN`.

```sh
qs log --log-times -p "$OMARCHY_PATH/shell" | grep seaglenet.power-saver:
```

Add `-f` to follow it. That log only covers the running shell; Omarchy also
keeps it in the journal, which goes back further:
`journalctl --user -t omarchy-shell`.

## Uninstall

```sh
omarchy plugin remove seaglenet.power-saver
```

Removing the plugin unloads it first, which deletes its file and restores your
effects.

## Development

Saving a file in the plugin directory restarts the plugin, but with the QML the
shell already loaded; `omarchy-shell shell rescanPlugins` does the same. Run
`omarchy restart shell` to pick up changes to `Service.qml`, and after renaming
the plugin. Changes to `effects.sh` apply on save, since every start of the
plugin reads it again.

`effects.sh` writes and removes the Hyprland toggle file. The plugin loads its
text once at startup and runs it with `bash -c`, so the cleanup on removal does
not depend on the file still being there. It can also be run on its own:

```sh
bash effects.sh saver animations blur dim=40 refresh=60   # or: bash effects.sh normal
```

QML is formatted with Qt's `qmlformat` using the checked-in `.qmlformat.ini`
(two-space indent, only essential semicolons):

```sh
/usr/lib/qt6/bin/qmlformat -i Service.qml
```

Shell files are formatted with `shfmt` (4-space indent, from `.editorconfig`).
The checks CI runs, on every push and pull request:

```sh
/usr/lib/qt6/bin/qmllint Service.qml   # settings in .qmllint.ini
shfmt -d . && shfmt -f . | xargs shellcheck
bats tests                             # effects.sh against fake hyprctl and brightnessctl
```

CI has no Hyprland, so after Hyprland or Omarchy updates, also run the
integration tests in your session. They check `effects.sh` against the running
Hyprland and your Omarchy config. Effects flicker off and on while they run,
and everything is put back afterwards:

```sh
bats tests/integration
```

The security workflow runs Semgrep and zizmor. A finding fails
the job and shows up in its log.

## License

[MIT](LICENSE)
