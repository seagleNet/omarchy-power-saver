# CLAUDE.md

An Omarchy shell service plugin; see README.md for what it does, its
settings and the commands CI runs. Things that are easy to get wrong:

- `effects.sh` is never run as a file. `Service.qml` loads its text at
  startup and runs it with `bash -c`, because `omarchy plugin remove` deletes
  the plugin directory right after unloading it, and the cleanup on unload
  must still work. Keep it that way.
- `reportRun` in `Service.qml` parses the lines `effects.sh` prints (`off`,
  `skipped`, `restored`, `error:`). Change one, change the other and
  `tests/effects.bats`.
- Saving a file reloads the plugin with the code the shell already loaded.
  To try a change, run `omarchy restart shell`.
- The plugin only reads `~/.config/omarchy/shell.json`; it never writes it.
- QML uses `var`, like Omarchy's own shell; `.qmllint.ini` turns that
  warning off and fails on any other. Format QML with `qmlformat` and shell
  files with `shfmt` (settings in `.qmlformat.ini` and `.editorconfig`).
- Run `bats tests` for every change. `bats tests/integration` runs against the
  live Hyprland session and reloads its config, so ask before running it; CI
  cannot run it.
