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
toggles="$HOME/.local/state/omarchy/toggles/hypr"
file="$toggles/power-saver.lua"
printf -v nl "\n"
mode=$1
shift
content=""
if [[ $mode == saver ]]; then
    for effect in "$@"; do
        option="" line=""
        case $effect in
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
fi
exit 0
