#!/usr/bin/env bats
# Tests for effects.sh, run against the fake hyprctl in tests/bin with a
# throwaway HOME and XDG_RUNTIME_DIR.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    export HYPRCTL_LOG="$BATS_TEST_TMPDIR/hyprctl.log"
    export BRIGHTNESS_FILE="$BATS_TEST_TMPDIR/brightness"
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
    : >"$HYPRCTL_LOG"
    echo 800 >"$BRIGHTNESS_FILE"
    STATE="$XDG_RUNTIME_DIR/seaglenet-power-saver.brightness"
    TOGGLE="$HOME/.local/state/omarchy/toggles/hypr/power-saver.lua"
    HEADER="-- Written by the seaglenet.power-saver shell plugin while power-saver is active."
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

brightness() {
    cat "$BRIGHTNESS_FILE"
}

@test "dim lowers the backlight and normal puts it back" {
    effects saver dim=30 animations
    [ "$status" -eq 0 ]
    [ "$output" = $'off animations\ndimmed 80 30' ]
    [ "$(brightness)" -eq 300 ]
    [ "$(cat "$STATE")" = "panel 800 300" ]
    effects normal
    [ "$status" -eq 0 ]
    [ "$output" = $'restored\nbrightness restored 80' ]
    [ "$(brightness)" -eq 800 ]
    [ ! -e "$STATE" ]
}

@test "dim alone writes no toggle file and does not reload" {
    effects saver dim=30
    [ "$status" -eq 0 ]
    [ "$output" = "dimmed 80 30" ]
    [ ! -e "$TOGGLE" ]
    [ "$(reloads)" -eq 0 ]
}

@test "dim never raises the backlight" {
    echo 200 >"$BRIGHTNESS_FILE"
    effects saver dim=30
    [ "$status" -eq 0 ]
    [ "$output" = "not dimmed 20" ]
    [ "$(brightness)" -eq 200 ]
    effects normal
    [ "$output" = "" ]
    [ "$(brightness)" -eq 200 ]
}

@test "a brightness changed while dimmed is kept" {
    effects saver dim=30
    echo 500 >"$BRIGHTNESS_FILE"
    effects saver dim=20
    [ "$status" -eq 0 ]
    [ "$output" = "brightness kept 50" ]
    [ "$(brightness)" -eq 500 ]
    effects normal
    [ "$output" = "brightness kept 50" ]
    [ "$(brightness)" -eq 500 ]
    [ ! -e "$STATE" ]
}

@test "a new dim level applies from the brightness before dimming" {
    effects saver dim=30
    effects saver dim=50
    [ "$output" = "dimmed 80 50" ]
    [ "$(brightness)" -eq 500 ]
    effects saver dim=90
    [ "$output" = "not dimmed 80" ]
    [ "$(brightness)" -eq 800 ]
}

@test "saver without dim puts the brightness back" {
    effects saver dim=30 blur
    effects saver blur
    [ "$status" -eq 0 ]
    [ "$output" = $'off blur\nbrightness restored 80' ]
    [ "$(brightness)" -eq 800 ]
}

@test "a driver rounding the level does not count as a change" {
    BRIGHTNESS_STEP=64 effects saver dim=30
    [ "$output" = "dimmed 80 26" ]
    [ "$(brightness)" -eq 256 ]
    effects normal
    [ "$output" = "brightness restored 80" ]
    [ "$(brightness)" -eq 800 ]
}

@test "dim without a backlight is reported and changes nothing" {
    BRIGHTNESS_NONE=1 effects saver dim=30 animations
    [ "$status" -eq 0 ]
    [ "$output" = $'off animations\nno backlight' ]
    [ ! -e "$STATE" ]
}

@test "an invalid dim level fails without touching anything" {
    for level in 0 101 abc ""; do
        effects saver animations "dim=$level"
        [ "$status" -eq 1 ]
        [[ $output == *"error: invalid dim level"* ]]
    done
    [ ! -e "$TOGGLE" ]
    [ "$(brightness)" -eq 800 ]
}

@test "a failed brightness change is reported" {
    BRIGHTNESS_FAIL_SET=1 effects saver dim=30
    [ "$status" -eq 1 ]
    [ "$output" = "error: brightnessctl failed: permission denied" ]
    [ ! -e "$STATE" ]
}
