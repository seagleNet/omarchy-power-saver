#!/usr/bin/env bats
# Runs effects.sh against the running Hyprland and Omarchy config, to catch
# Hyprland or Omarchy changing under the plugin: a renamed option, a changed
# Lua config API, a helper or window tag that is gone. Not run in CI, which has
# no Hyprland; run it in your session after updates:
#
#   bats tests/integration
#
# It writes the real toggle file and reloads the Hyprland config a few times,
# so effects flicker off and on. On a laptop screen with a slower mode it also
# switches to that mode and back, which blanks the screen briefly. At the end
# the toggle file is put back as it was and the config reloaded once more.

setup_file() {
    [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || skip "needs a running Hyprland session"
    command -v jq >/dev/null || skip "needs jq"
    export TOGGLE="$HOME/.local/state/omarchy/toggles/hypr/power-saver.lua"
    export SAVED="$BATS_FILE_TMPDIR/power-saver.lua.saved"
    export ERRORS_BEFORE="$BATS_FILE_TMPDIR/configerrors"
    export VALUES_BEFORE="$BATS_FILE_TMPDIR/values"

    # Start from the effects as configured, without the plugin's file.
    if [[ -f $TOGGLE ]]; then
        cp "$TOGGLE" "$SAVED"
        rm "$TOGGLE"
        hyprctl reload config-only >/dev/null
    fi
    hyprctl configerrors >"$ERRORS_BEFORE"
    for option in $(options); do
        echo "$option $(value "$option")"
    done >"$VALUES_BEFORE"
}

teardown_file() {
    [[ -n ${TOGGLE:-} ]] || return 0
    if [[ -f $SAVED ]]; then
        cp "$SAVED" "$TOGGLE"
    else
        rm -f "$TOGGLE"
    fi
    hyprctl reload config-only >/dev/null
}

# The Hyprland options effects.sh turns off, read from the script itself.
options() {
    grep -oE 'option=[a-z_.]+' "$BATS_TEST_DIRNAME/../../effects.sh" | cut -d= -f2
}

value() {
    hyprctl -j getoption "$1" | jq -r 'if has("bool") then .bool else .int end'
}

effects() {
    run bash -c "$(<"$BATS_TEST_DIRNAME/../../effects.sh")" power-saver "$@"
}

@test "the running Hyprland has every option effects.sh turns off" {
    missing=()
    for option in $(options); do
        hyprctl getoption "$option" | grep -q "no such option" && missing+=("$option")
    done
    [ "${#missing[@]}" -eq 0 ] || {
        echo "missing in this Hyprland: ${missing[*]}"
        false
    }
}

@test "Omarchy still tags the windows that transparency makes opaque" {
    omarchy="${OMARCHY_PATH:-/usr/share/omarchy}/default/hypr"
    grep -rq 'tag = "+transparent-window"' "$omarchy" || {
        echo "nothing in $omarchy adds the transparent-window tag any more"
        false
    }
}

@test "saver turns every effect off and Hyprland loads the file without errors" {
    effects saver animations blur shadows glow motionBlur wobble transparency
    [ "$status" -eq 0 ]
    [[ $output != *skipped* ]]
    [ -f "$TOGGLE" ]
    diff -u "$ERRORS_BEFORE" <(hyprctl configerrors)
    for option in $(options); do
        [ "$(value "$option")" = "false" ] || {
            echo "$option is $(value "$option") in power-saver"
            false
        }
    done
}

@test "normal restores every effect as it was" {
    effects saver animations blur shadows glow motionBlur wobble transparency
    effects normal
    [ "$status" -eq 0 ]
    [ ! -e "$TOGGLE" ]
    diff -u "$ERRORS_BEFORE" <(hyprctl configerrors)
    diff -u "$VALUES_BEFORE" <(for option in $(options); do
        echo "$option $(value "$option")"
    done)
}

# The laptop screen's rate, or nothing without one.
laptop_rate() {
    hyprctl monitors -j | jq -r '[.[] | select(.name | test("^(eDP|LVDS|DSI)-"))][0].refreshRate // empty'
}

close_to() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !((a - b) ^ 2 < 0.25) }'
}

@test "refresh lowers the laptop screen and normal restores it" {
    slowest=$(hyprctl monitors -j | jq -r '[.[] | select(.name | test("^(eDP|LVDS|DSI)-"))][0] // empty
        | "\(.width)x\(.height)" as $size | .refreshRate as $rate
        | [.availableModes[] | capture("^(?<size>[0-9]+x[0-9]+)@(?<rate>[0-9.]+)Hz$")
            | select(.size == $size) | .rate | tonumber | select(. < $rate - 0.5)] | min // empty')
    [[ -n $slowest ]] || skip "no laptop screen with a slower mode at its resolution"
    before=$(laptop_rate)
    effects saver "refresh=$(printf '%.0f' "$slowest")"
    [ "$status" -eq 0 ]
    [[ $output == "refresh "* ]]
    diff -u "$ERRORS_BEFORE" <(hyprctl configerrors)
    close_to "$(laptop_rate)" "$slowest"
    effects normal
    [ "$status" -eq 0 ]
    [[ $output == *"refresh restored"* ]]
    close_to "$(laptop_rate)" "$before"
}
