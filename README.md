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

It is a background service with no bar widget.

## Requirements

- Omarchy 4 with the Lua Hyprland config
- `power-profiles-daemon` and UPower (both part of Omarchy)

## Install

```sh
omarchy plugin add https://github.com/seagleNet/omarchy-power-saver --enable
```

This installs it to `~/.config/omarchy/plugins/seagleNet.power-saver` and
enables it.

## Settings

Settings go on the plugin's entry in `~/.config/omarchy/shell.json`:

```json
"plugins": [
  {
    "id": "seagleNet.power-saver",
    "threshold": 25,
    "disable": { "transparency": true, "animations": false }
  }
]
```

- `threshold`: the battery percentage, from 5 to 95, at which to switch to
  `power-saver`. Defaults to 20. The battery is checked every 30 seconds.
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

## Logs

The plugin logs to the Omarchy shell's log: what it changes and why as `INFO`,
and problems such as invalid settings or a failed step as `WARN`.

```sh
qs log --log-times -p "$OMARCHY_PATH/shell" | grep seagleNet.power-saver:
```

Add `-f` to follow it. That log only covers the running shell; Omarchy also
keeps it in the journal, which goes back further:
`journalctl --user -t omarchy-shell`.

## Uninstall

```sh
omarchy plugin remove seagleNet.power-saver
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
bash effects.sh saver animations blur   # or: bash effects.sh normal
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
bats tests                             # effects.sh against a fake hyprctl
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
