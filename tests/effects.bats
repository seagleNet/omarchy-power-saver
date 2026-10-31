#!/usr/bin/env bats
# Tests for effects.sh, run against the fake hyprctl in tests/bin with a
# throwaway HOME and XDG_RUNTIME_DIR.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    export HYPRCTL_LOG="$BATS_TEST_TMPDIR/hyprctl.log"
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
    : >"$HYPRCTL_LOG"
    TOGGLE="$HOME/.local/state/omarchy/toggles/hypr/power-saver.lua"
    HEADER="-- Written by the seagleNet.power-saver shell plugin while power-saver is active."
}

# Runs the script the way Service.qml does: its text through `bash -c`.
effects() {
    run bash -c "$(<"$REPO/effects.sh")" power-saver "$@"
}

reloads() {
    grep -c '^reload config-only$' "$HYPRCTL_LOG" || true
}

@test "saver writes every effect to the toggle file and reloads once" {
    effects saver animations blur shadows glow motionBlur wobble transparency
    [ "$status" -eq 0 ]
    [ "$output" = $'off animations\noff blur\noff shadows\noff glow\noff motionBlur\noff wobble\noff transparency' ]
    expected="$HEADER
hl.config({ animations = { enabled = false } })
hl.config({ decoration = { blur = { enabled = false } } })
hl.config({ decoration = { shadow = { enabled = false } } })
hl.config({ decoration = { glow = { enabled = false } } })
hl.config({ decoration = { motion_blur = { enabled = false } } })
hl.config({ decoration = { wobble = { enabled = false } } })
o.window({ tag = \"transparent-window\" }, { opacity = \"1 1\" })"
    [ "$(cat "$TOGGLE")" = "$expected" ]
    [ -z "$(tail -c1 "$TOGGLE")" ] # ends in a newline
    [ "$(reloads)" -eq 1 ]
}

@test "saver skips effects the running Hyprland has no option for" {
    HYPRCTL_UNSUPPORTED="decoration.wobble.enabled decoration.glow.enabled" \
        effects saver animations glow wobble
    [ "$status" -eq 0 ]
    [ "$output" = $'off animations\nskipped glow\nskipped wobble' ]
    [ "$(cat "$TOGGLE")" = "$HEADER
hl.config({ animations = { enabled = false } })" ]
}

@test "an unchanged saver run leaves the file alone and does not reload" {
    effects saver animations blur
    [ "$(reloads)" -eq 1 ]
    effects saver animations blur
    [ "$status" -eq 0 ]
    [ "$output" = $'off animations\noff blur' ]
    [ "$(reloads)" -eq 1 ]
}

@test "normal removes the toggle file and reloads" {
    effects saver animations
    effects normal
    [ "$status" -eq 0 ]
    [ "$output" = "restored" ]
    [ ! -e "$TOGGLE" ]
    [ "$(reloads)" -eq 2 ]
}

@test "an unknown effect fails without touching the file" {
    effects saver animations
    before="$(cat "$TOGGLE")"
    effects saver blur sparkles
    [ "$status" -eq 1 ]
    [ "$output" = $'off blur\nerror: unknown effect sparkles' ]
    [ "$(cat "$TOGGLE")" = "$before" ]
    [ "$(reloads)" -eq 1 ]
}

@test "a failed reload is reported" {
    HYPRCTL_FAIL_RELOAD=1 effects saver animations
    [ "$status" -eq 1 ]
    [ "$output" = $'off animations\nerror: hyprctl failed: reload refused' ]
}
