#!/bin/bash

#possible variables are
#"${DEBUG_DIR}" "${SMART_GREP}" "${PACK_ONOFF}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}"
#"${IFCONFIG}" "${SPACE_FILES}" "${DiskLog}" "${KERN}" "${SYSDB}" "${MESSAGES}"  "${sm}" "${PicArray[@]}"

declare -a OpenFiles
#set Editor for windows/linux&mac:
# subl, vim , etc
if grep -qE "(Microsoft|WSL)" /proc/version &> /dev/null ; then
    subl=/mnt/c/Program\ Files/Sublime\ Text\ 3/subl.exe
    os=win
    #subl "$(wslpath -w $i)"
    OpenFiles=("${DEBUG_DIR}" "${SMART_GREP}" "${PACK_ONOFF}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}" "${IFCONFIG}" "${SPACE_FILES}" "${DiskLog}" "${KERN}" "${SYSDB}" "${MESSAGES}" "${sm}" "${PicArray[@]}")
else
    # Prefer Flatpak Sublime Text if installed (carries user plugins
    # like Log Highlight). Falls back to plain `subl` (snap/native).
    if command -v flatpak >/dev/null 2>&1 && \
       flatpak info com.sublimehq.SublimeText >/dev/null 2>&1; then
        subl="flatpak run com.sublimehq.SublimeText"
    else
        subl="subl"
    fi
    os=other
    #subl='tilix -e vim -p'
    #subl='tilix -e vim -p' #vim
    #OpenFiles=("${DEBUG_DIR} ${SMART_GREP} ${PACK} ${Bash_history} ${hb_debug} ${HB} ${sm} ${MESSAGES}") #for vim
    #OpenFiles=("${DEBUG_DIR}" "${SMART_GREP}" "${PACK}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}" "${DU}" ${IFCONFIG}" "${SPACE_FILES}" "${DiskLog}" "${KERN}" "${SYSDBtac}" "${sm}" "${MESSAGES}" "${PicArray[@]}") # for visualcode
    OpenFiles=("${SMART_GREP}" "${PACK_ONOFF}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}" "${SPACE_FILES:+$SPACE_FILES:100000}" "${DiskLog:+$DiskLog:100000}" "${KERN:+$KERN:100000}" "${SYSDB:+$SYSDB:100000}" "${MESSAGES:+$MESSAGES:100000}"  "${sm}" "${PicArray[@]}") # for subl
    #subl='tilix -e vim -g -p' #vim-gnome
fi