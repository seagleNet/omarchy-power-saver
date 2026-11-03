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
toggles="$HOME/.local/state/omarchy/toggles/hypr"
file="$toggles/power-saver.lua"
printf -v nl "\n"
mode=$1
shift
content=""
dim=""
if [[ $mode == saver ]]; then
    for effect in "$@"; do
        option="" line=""
        case $effect in
        dim=*)
            dim=${effect#dim=}
            [[ $dim =~ ^[0-9]+$ ]] && ((dim >= 1 && dim <= 100)) || fail "invalid dim level ${dim@Q}, expected 1 to 100"
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
fi
if [[ -n $content ]]; then
    content="-- Written by the seaglenet.power-saver shell plugin while power-saver is active.$nl$content"
    if [[ $(cat "$file" 2>/dev/null)$nl != "$content" ]]; then
        try mkdir -p "$toggles"
        try tee "$file" <<<"${content%"$nl"}"
        changed=1
    fi
elif [[ -f $file ]]; then
    try rm -f "$file"
    changed=1
    echo "restored"
fi
if ((changed)); then
    try hyprctl reload config-only
    changed=0
fi
if [[ -n $dim ]]; then
    dim_screen "$dim"
else
    restore_brightness
fi
exit 0
