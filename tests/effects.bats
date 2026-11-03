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

# The Lua effects.sh writes for a refresh rule, after the header.
refresh_rule() {
    echo "local power_saver_monitor = { output = \"eDP-1\", mode = \"2560x1600@$1\" } -- refresh rate was $2
hl.monitor(power_saver_monitor)
-- Again once the config is loaded, since the monitor panel's saved modes apply after this file.
hl.on(\"config.reloaded\", function() hl.monitor(power_saver_monitor) end)"
}

@test "refresh picks the fastest listed rate at or below the limit" {
    effects saver blur refresh=100
    [ "$status" -eq 0 ]
    [ "$output" = $'off blur\nrefresh 165 60' ]
    [ "$(cat "$TOGGLE")" = "$HEADER
hl.config({ decoration = { blur = { enabled = false } } })
$(refresh_rule 60 165)" ]
    [ "$(reloads)" -eq 1 ]
}

@test "refresh takes a listed rate within half a hertz above the limit" {
    HYPRCTL_MONITORS='[{"name": "eDP-1", "width": 2560, "height": 1600, "refreshRate": 144,
        "availableModes": ["2560x1600@144.00Hz", "2560x1600@60.03Hz"]}]' effects saver refresh=60
    [ "$output" = "refresh 144 60.03" ]
    grep -q '"2560x1600@60.03"' "$TOGGLE"
}

@test "refresh ignores rates offered only at another resolution" {
    effects saver refresh=40
    [ "$status" -eq 0 ]
    [ "$output" = "refresh unsupported 40" ]
    [ ! -e "$TOGGLE" ]
    [ "$(reloads)" -eq 0 ]
}

@test "refresh never raises the rate" {
    HYPRCTL_MONITORS='[{"name": "eDP-1", "width": 2560, "height": 1600, "refreshRate": 60.001,
        "availableModes": ["2560x1600@165.00Hz", "2560x1600@60.00Hz"]}]' effects saver refresh=120
    [ "$status" -eq 0 ]
    [ "$output" = "refresh kept 60" ]
    [ ! -e "$TOGGLE" ]
}

@test "refresh only touches the laptop screen" {
    HYPRCTL_MONITORS='[{"name": "DP-1", "width": 2560, "height": 1440, "refreshRate": 144,
        "availableModes": ["2560x1440@144.00Hz", "2560x1440@60.00Hz"]}]' effects saver refresh=60
    [ "$status" -eq 0 ]
    [ "$output" = "no laptop screen" ]
    [ ! -e "$TOGGLE" ]
}

@test "a rerun keeps the rate from before the rule and does not reload" {
    effects saver refresh=60
    HYPRCTL_MONITORS='[{"name": "eDP-1", "width": 2560, "height": 1600, "refreshRate": 60,
        "availableModes": ["2560x1600@165.00Hz", "2560x1600@120.00Hz", "2560x1600@60.00Hz"]}]' \
        effects saver refresh=60
    [ "$status" -eq 0 ]
    [ "$output" = "refresh 165 60" ]
    [ "$(reloads)" -eq 1 ]
}

@test "a higher limit while lowered raises to it, from the rate before" {
    effects saver refresh=60
    HYPRCTL_MONITORS='[{"name": "eDP-1", "width": 2560, "height": 1600, "refreshRate": 60,
        "availableModes": ["2560x1600@165.00Hz", "2560x1600@120.00Hz", "2560x1600@60.00Hz"]}]' \
        effects saver refresh=120
    [ "$output" = "refresh 165 120" ]
    [ "$(cat "$TOGGLE")" = "$HEADER
$(refresh_rule 120 165)" ]
}

@test "normal and saver without refresh put the rate back" {
    effects saver blur refresh=60
    effects saver blur
    [ "$status" -eq 0 ]
    [ "$output" = $'off blur\nrefresh restored 165' ]
    [ "$(cat "$TOGGLE")" = "$HEADER
hl.config({ decoration = { blur = { enabled = false } } })" ]
    effects saver refresh=60
    effects normal
    [ "$output" = $'refresh restored 165\nrestored' ]
    [ ! -e "$TOGGLE" ]
}

@test "an invalid refresh rate fails without touching anything" {
    for rate in 0 29 1001 60.5 abc ""; do
        effects saver "refresh=$rate"
        [ "$status" -eq 1 ]
        [[ $output == *"error: invalid refresh rate"* ]]
    done
    [ ! -e "$TOGGLE" ]
}

@test "an unsafe monitor name is refused" {
    HYPRCTL_MONITORS='[{"name": "eDP-1 \"})os.execute(\"x", "width": 2560, "height": 1600, "refreshRate": 165,
        "availableModes": ["2560x1600@60.00Hz"]}]' effects saver refresh=60
    [ "$status" -eq 1 ]
    [[ $output == "error: refusing the unsafe monitor name"* ]]
    [ ! -e "$TOGGLE" ]
}

@test "a mode the panel does not take is rolled back, keeping the effects" {
    HYPRCTL_REFUSE_MODE=1 effects saver blur refresh=60
    [ "$status" -eq 0 ]
    [ "$output" = $'off blur\nrefresh 165 60\nrefresh failed 60' ]
    [ "$(cat "$TOGGLE")" = "$HEADER
hl.config({ decoration = { blur = { enabled = false } } })" ]
    [ "$(reloads)" -eq 2 ]
}

@test "a refused mode with nothing else leaves no toggle file" {
    HYPRCTL_REFUSE_MODE=1 effects saver refresh=60
    [ "$status" -eq 0 ]
    [ "$output" = $'refresh 165 60\nrefresh failed 60' ]
    [ ! -e "$TOGGLE" ]
    [ "$(reloads)" -eq 2 ]
}

@test "a laptop screen that mirrors another is left alone" {
    HYPRCTL_MONITORS='[{"name": "eDP-1", "width": 2560, "height": 1600, "refreshRate": 165, "mirrorOf": "DP-1",
        "availableModes": ["2560x1600@165.00Hz", "2560x1600@60.00Hz"]}]' effects saver refresh=60
    [ "$status" -eq 0 ]
    [ "$output" = "refresh mirrored" ]
    [ ! -e "$TOGGLE" ]
}
