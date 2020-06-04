#!/bin/bash

#set download directory to find *.dat files
#DOWNLOAD_DIR=/mnt/c/Users/no-sp/Downloads/neu/

declare -a OpenFiles
#set Editor for windows/linux&mac:
# subl, vim , etc
if grep -qE "(Microsoft|WSL)" /proc/version &> /dev/null ; then
    subl=/mnt/c/Program\ Files/Sublime\ Text\ 3/subl.exe
    os=win
    #subl $(wslpath -w /mnt/c/Users/name/Downloads/neu/myfile1)
    OpenFiles=("${DEBUG_DIR}" "${SMART_GREP}" "${PACK_ONOFF}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}" "${DU}" "${IFCONFIG}" "${SPACE_FILES}":100000 "${DiskLog}" "${KERN}":100000 "${SYSDB}":100000 "${MESSAGES}":1000000 "${sm}" "${PicArray[@]}")
else
    #IFS=$'\n'
    #subl="subl" #SublimeText 3
    subl="subl"
    #subl='tilix -e vim -p'
    #subl='tilix -e vim -p' #vim
    #OpenFiles=("${DEBUG_DIR} ${SMART_GREP} ${PACK} ${Bash_history} ${hb_debug} ${HB} ${sm} ${MESSAGES}") #for vim
    #OpenFiles=("${DEBUG_DIR}" "${SMART_GREP}" "${PACK}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}" "${IFCONFIG}" "${SPACE_FILES}" "${DiskLog}" "${KERN}" "${SYSDBtac}" "${sm}" "${MESSAGES}" "${PicArray[@]}") # for visualcode
    OpenFiles=("${DEBUG_DIR}" "${SMART_GREP}" "${PACK_ONOFF}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}" "${DU}" "${IFCONFIG}" "${SPACE_FILES}":100000 "${DiskLog}":100000 "${KERN}":100000 "${SYSDB}":100000 "${MESSAGES}":1000000  "${sm}" "${PicArray[@]}") # for subl
    #subl='tilix -e vim -g -p' #vim-gnome
    #to add:
    #IFS=$' \t\n'
    os=other
fi