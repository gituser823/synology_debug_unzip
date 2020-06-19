#!/bin/bash

declare -a OpenFiles
#set Editor for windows/linux&mac:
# subl, vim , etc
if grep -qE "(Microsoft|WSL)" /proc/version &> /dev/null ; then
    subl=/mnt/c/Program\ Files/Sublime\ Text\ 3/subl.exe
    os=win
    #subl $(wslpath -w /mnt/c/Users/name/Downloads/neu/myfile1)
    OpenFiles=("${DEBUG_DIR}" "${SMART_GREP}" "${PACK_ONOFF}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}" "${IFCONFIG}" "${SPACE_FILES}" "${DiskLog}" "${KERN}" "${SYSDB}" "${MESSAGES}" "${sm}" "${PicArray[@]}")
else
    #IFS=$'\n'
    #subl="subl" #SublimeText 3
    subl="subl"
    #subl='tilix -e vim -p'
    #subl='tilix -e vim -p' #vim
    #OpenFiles=("${DEBUG_DIR} ${SMART_GREP} ${PACK} ${Bash_history} ${hb_debug} ${HB} ${sm} ${MESSAGES}") #for vim
    #OpenFiles=("${DEBUG_DIR}" "${SMART_GREP}" "${PACK}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}" "${DU}" ${IFCONFIG}" "${SPACE_FILES}" "${DiskLog}" "${KERN}" "${SYSDBtac}" "${sm}" "${MESSAGES}" "${PicArray[@]}") # for visualcode
    OpenFiles=("${DEBUG_DIR}" "${SMART_GREP}" "${PACK_ONOFF}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}" "${IFCONFIG}" "${SPACE_FILES:+$SPACE_FILES:100000}" "${DiskLog:+$DiskLog:100000}" "${KERN:+$KERN:100000}" "${SYSDB:+$SYSDB:100000}" "${MESSAGES:+$MESSAGES:100000}"  "${sm}" "${PicArray[@]}") # for subl
    #subl='tilix -e vim -g -p' #vim-gnome
    #to add:
    #IFS=$' \t\n'
    os=other
fi