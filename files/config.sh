#!/bin/bash

#possible variables are
#"${DEBUG_DIR}" "${SMART_GREP}" "${PACK_ONOFF}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}"
#"${IFCONFIG}" "${SPACE_FILES}" "${DiskLog}" "${KERN}" "${SYSDB}" "${MESSAGES}"  "${sm}" "${PicArray[@]}"

declare -a OpenFiles
declare -a subl

# Returns the first available GUI editor command (words as separate array elements).
_detect_editor() {
    if command -v flatpak >/dev/null 2>&1 && \
       flatpak info com.sublimehq.SublimeText >/dev/null 2>&1; then
        echo "flatpak run com.sublimehq.SublimeText"; return
    fi
    for cmd in subl sublime_text gedit kate mousepad xed pluma; do
        command -v "$cmd" >/dev/null 2>&1 && echo "$cmd" && return
    done
    echo "xdg-open"
}

# Searches common Windows install paths for Sublime Text (WSL only).
_find_win_subl() {
    # Try WSL interop PATH first (works if Sublime Text dir is in Windows PATH)
    local cmd
    for cmd in sublime_text.exe subl.exe; do
        command -v "$cmd" >/dev/null 2>&1 && echo "$cmd" && return
    done
    # Try common install paths
    local win_user
    win_user=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n')
    local paths=(
        "/mnt/c/Program Files/Sublime Text/sublime_text.exe"
        "/mnt/c/Program Files/Sublime Text 4/sublime_text.exe"
        "/mnt/c/Program Files/Sublime Text 3/sublime_text.exe"
        "/mnt/c/Program Files/Sublime Text/subl.exe"
        "/mnt/c/Program Files/Sublime Text 4/subl.exe"
        "/mnt/c/Program Files/Sublime Text 3/subl.exe"
        "/mnt/c/Users/$win_user/AppData/Local/Programs/Sublime Text/sublime_text.exe"
        "/mnt/c/Users/$win_user/AppData/Local/Programs/Sublime Text 3/sublime_text.exe"
        "/mnt/c/Users/$win_user/AppData/Local/Programs/Sublime Text 4/sublime_text.exe"
    )
    for p in "${paths[@]}"; do
        [ -x "$p" ] && echo "$p" && return
    done
}

if grep -qE "(Microsoft|WSL)" /proc/version &> /dev/null ; then
    os=win
    _win_subl=$(_find_win_subl)
    if [ -n "$_win_subl" ]; then
        subl=("$_win_subl")
        editor_type=sublime
    else
        # Sublime Text not found — open with Windows Explorer (always available in WSL)
        subl=(explorer.exe)
        editor_type=other
    fi
    OpenFiles=("${DEBUG_DIR}" "${SMART_GREP}" "${PACK_ONOFF}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}" "${IFCONFIG}" "${SPACE_FILES}" "${DiskLog}" "${KERN}" "${SYSDB}" "${MESSAGES}" "${sm}" "${PicArray[@]}")
else
    _detected=$(_detect_editor)
    read -ra subl <<< "$_detected"
    os=other

    case "$_detected" in
        *SublimeText*|subl|sublime_text) editor_type=sublime ;;
        *) editor_type=other ;;
    esac

    if [[ "$editor_type" == "sublime" ]]; then
        # :100000 jumps to end-of-file in Sublime Text
        OpenFiles=("${SMART_GREP}" "${PACK_ONOFF}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}" "${SPACE_FILES:+$SPACE_FILES:100000}" "${DiskLog:+$DiskLog:100000}" "${KERN:+$KERN:100000}" "${SYSDB:+$SYSDB:100000}" "${MESSAGES:+$MESSAGES:100000}" "${sm}" "${PicArray[@]}")
    else
        OpenFiles=("${SMART_GREP}" "${PACK_ONOFF}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}" "${SPACE_FILES}" "${DiskLog}" "${KERN}" "${SYSDB}" "${MESSAGES}" "${sm}" "${PicArray[@]}")
    fi
fi
