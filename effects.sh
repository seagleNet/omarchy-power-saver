#!/usr/bin/env bash
# Turns the power-saver desktop effects on and off for the seaglenet.power-saver
# shell plugin. Service.qml runs it with `bash -c`, from the text it loaded at
# startup, so the cleanup still works while the plugin directory is removed.
#
# `saver <effects...>` writes the toggle file for those effects, `normal`
# removes it; Hyprland is reloaded only when the file changed. Effects the
# running Hyprland has no option for are left out. Prints "off <effect>",
# "skipped <effect>" and "restored" for what it did, and "error: ..." for a
# step that failed, which stops the run.
#
# A `dim=<percent>` argument to `saver` also lowers the built-in panel's
# backlight to that percentage, if it is brighter. The level before is kept in
# a state file, and `normal`, or `saver` without `dim=`, puts it back, unless
# the brightness was changed since. Prints "dimmed <from> <to>",
# "not dimmed <percent>", "brightness restored <percent>",
# "brightness kept <percent>" and "no backlight", percentages without the %.
#
# A `refresh=<hz>` argument to `saver` also puts the built-in panel on the
# fastest refresh rate it offers at its current resolution that is at most
# that, if that is slower than it runs at. Only modes the panel lists are
# used. The rule goes into the toggle file, so removing it restores the rate.
# After the reload it checks that the panel runs at the new rate, and if not
# takes the rule out again. Prints "refresh <from> <to>", "refresh kept <hz>",
# "refresh unsupported <hz>" (no mode that slow), "refresh failed <hz>" (the
# panel did not take it), "refresh restored <hz>", "refresh mirrored" and
# "no laptop screen".

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
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/seaglenet-power-saver.lock" || fail "could not open the lock file"
flock 9 || fail "could not take the lock"
brightness_state="${XDG_RUNTIME_DIR:-/tmp}/seaglenet-power-saver.brightness"
# Prints the raw current and maximum brightness of a backlight device.
read_brightness() {
    brightnessctl -m -d "$1" 2>/dev/null | awk -F, '{ print $3, $5; found = 1 } END { exit !found }'
}
percent() {
    echo $((($1 * 100 + $2 / 2) / $2))
}
# Lowers the backlight to $1 percent of its maximum, never raising it. The
# state file holds the device, the level before dimming and the level set.
dim_screen() {
    local device saved set current max target
    if [[ -f $brightness_state ]]; then
        read -r device saved set <"$brightness_state"
        read -r current max < <(read_brightness "$device") || fail "could not read the brightness of $device"
        if [[ $current != "$set" ]]; then
            echo "brightness kept $(percent "$current" "$max")"
            return
        fi
    else
        device=$(omarchy-hw-display 2>/dev/null) || device=""
        if [[ -z $device ]] || ! read -r current max < <(read_brightness "$device"); then
            echo "no backlight"
            return
        fi
        saved=$current
    fi
    target=$(((max * $1 + 50) / 100))
    ((target < 1)) && target=1
    ((target > saved)) && target=$saved
    if ((target != current)); then
        try brightnessctl -q -d "$device" set "$target"
        # Read back, since a driver may round the level it was given.
        read -r current max < <(read_brightness "$device") || fail "could not read the brightness of $device"
    fi
    echo "$device $saved $current" >"$brightness_state" || fail "could not write $brightness_state"
    if ((current < saved)); then
        echo "dimmed $(percent "$saved" "$max") $(percent "$current" "$max")"
    else
        echo "not dimmed $(percent "$current" "$max")"
    fi
}
# Puts back the level from before dimming, if the brightness is still the one
# dim_screen set.
restore_brightness() {
    local device saved set current max
    [[ -f $brightness_state ]] || return 0
    read -r device saved set <"$brightness_state"
    if read -r current max < <(read_brightness "$device"); then
        if [[ $current != "$set" ]]; then
            echo "brightness kept $(percent "$current" "$max")"
        elif [[ $saved != "$set" ]]; then
            try brightnessctl -q -d "$device" set "$saved"
            echo "brightness restored $(percent "$saved" "$max")"
        fi
    fi
    try rm -f "$brightness_state"
}
# Sets $refresh_rule to the Lua that lowers the laptop screen to the fastest
# mode at its current size of at most $1 Hz, and $refresh_name and
# $refresh_target to the screen and that rate. While a rule from an earlier run is in
# place the screen runs at that rule's rate, so the rate from before is taken
# from the rule's comment instead.
lower_refresh() {
    local json info name size current best mirror
    json=$(hyprctl monitors -j) || fail "hyprctl monitors failed"
    info=$(jq -r --argjson max "$1" '
        [.[] | select(.name | test("^(eDP|LVDS|DSI)-"))][0] // empty
        | "\(.width)x\(.height)" as $size
        | [.name, $size, (.refreshRate * 100 | round / 100), (.mirrorOf // "none"),
            ([.availableModes[]
                | capture("^(?<size>[0-9]+x[0-9]+)@(?<rate>[0-9.]+)Hz$")
                | select(.size == $size)
                | .rate | tonumber
                | select(. <= $max + 0.5)]
                | max // 0 | . * 100 | round / 100)]
        | @tsv' <<<"$json") || fail "could not read the monitors"
    if [[ -z $info ]]; then
        echo "no laptop screen"
        return
    fi
    IFS=$'\t' read -r name size current mirror best <<<"$info"
    if [[ $mirror != none ]]; then
        echo "refresh mirrored"
        return
    fi
    # The name and size are written into Lua that Hyprland runs.
    [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || fail "refusing the unsafe monitor name ${name@Q}"
    [[ $size =~ ^[0-9]+x[0-9]+$ ]] || fail "unexpected monitor size ${size@Q}"
    [[ -n $previous_rate ]] && current=$previous_rate
    if [[ $best == 0 ]]; then
        echo "refresh unsupported $1"
    elif awk -v best="$best" -v current="$current" 'BEGIN { exit !(best < current - 0.5) }'; then
        refresh_rule="local power_saver_monitor = { output = \"$name\", mode = \"$size@$best\" } -- refresh rate was $current$nl"
        refresh_rule+="hl.monitor(power_saver_monitor)$nl"
        refresh_rule+="-- Again once the config is loaded, since the monitor panel's saved modes apply after this file.$nl"
        refresh_rule+="hl.on(\"config.reloaded\", function() hl.monitor(power_saver_monitor) end)$nl"
        refresh_name=$name refresh_target=$best
        echo "refresh $current $best"
    elif [[ -z $previous_rate ]]; then
        echo "refresh kept $current"
    fi
}
# Whether $refresh_name runs at $refresh_target Hz, waiting up to two seconds
# for the mode to be set.
refresh_applied() {
    local i
    for ((i = 0; i < 20; i++)); do
        hyprctl monitors -j 2>/dev/null | jq -e --arg name "$refresh_name" --argjson rate "$refresh_target" \
            'any(.[]; .name == $name and ((.refreshRate - $rate) | fabs) < 0.5)' >/dev/null && return 0
        sleep 0.1
    done
    return 1
}
# Writes $1 after the header to the toggle file, or removes the file when $1
# is empty, and sets $changed when that changed it.
write_toggle() {
    local text="-- Written by the seaglenet.power-saver shell plugin while power-saver is active.$nl$1"
    if [[ -n $1 ]]; then
        if [[ $(cat "$file" 2>/dev/null)$nl != "$text" ]]; then
            try mkdir -p "$toggles"
            try tee "$file" <<<"${text%"$nl"}"
            changed=1
        fi
    elif [[ -f $file ]]; then
        try rm -f "$file"
        changed=1
    fi
}
toggles="$HOME/.local/state/omarchy/toggles/hypr"
file="$toggles/power-saver.lua"
printf -v nl "\n"
mode=$1
shift
content=""
dim=""
refresh=""
refresh_rule=""
refresh_name=""
refresh_target=""
# The rate from before the rule an earlier run wrote, from its comment.
previous_rate=""
rate_comment=" -- refresh rate was ([0-9.]+)"
if [[ -f $file && "$(<"$file")" =~ $rate_comment ]]; then
    previous_rate=${BASH_REMATCH[1]}
fi
if [[ $mode == saver ]]; then
    for effect in "$@"; do
        option="" line=""
        case $effect in
        dim=*)
            dim=${effect#dim=}
            if ! [[ $dim =~ ^[0-9]+$ ]] || ((dim < 1 || dim > 100)); then
                fail "invalid dim level ${dim@Q}, expected 1 to 100"
            fi
            continue
            ;;
        refresh=*)
            refresh=${effect#refresh=}
            if ! [[ $refresh =~ ^[0-9]+$ ]] || ((refresh < 30 || refresh > 1000)); then
                fail "invalid refresh rate ${refresh@Q}, expected 30 to 1000"
            fi
            continue
            ;;
        animations) option=animations.enabled line="hl.config({ animations = { enabled = false } })" ;;
        blur) option=decoration.blur.enabled line="hl.config({ decoration = { blur = { enabled = false } } })" ;;
        shadows) option=decoration.shadow.enabled line="hl.config({ decoration = { shadow = { enabled = false } } })" ;;
        glow) option=decoration.glow.enabled line="hl.config({ decoration = { glow = { enabled = false } } })" ;;
        motionBlur) option=decoration.motion_blur.enabled line="hl.config({ decoration = { motion_blur = { enabled = false } } })" ;;
        wobble) option=decoration.wobble.enabled line="hl.config({ decoration = { wobble = { enabled = false } } })" ;;
        transparency) line="o.window({ tag = \"transparent-window\" }, { opacity = \"1 1\" })" ;;
        *) fail "unknown effect $effect" ;;
        esac
        if [[ -n $option ]] && ! supported "$option"; then
            echo "skipped $effect"
            continue
        fi
        content+="$line$nl"
        echo "off $effect"
    done
    [[ -n $refresh ]] && lower_refresh "$refresh"
fi
[[ -n $previous_rate && -z $refresh_rule ]] && echo "refresh restored $previous_rate"
[[ -z $content$refresh_rule && -f $file ]] && echo "restored"
write_toggle "$content$refresh_rule"
if ((changed)); then
    try hyprctl reload config-only
    changed=0
    # A mode the panel lists but does not take must not stay in place.
    if [[ -n $refresh_rule ]] && ! refresh_applied; then
        write_toggle "$content"
        try hyprctl reload config-only
        changed=0
        echo "refresh failed $refresh_target"
    fi
fi
if [[ -n $dim ]]; then
    dim_screen "$dim"
else
    restore_brightness
fi
exit 0
