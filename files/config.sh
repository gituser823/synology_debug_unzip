#!/bin/bash

#set download directory to find *.dat files
DOWNLOAD_DIR=/home/thomas/Downloads/neu

#set Editor for windows/linux&mac:
# subl, vim , etc
if grep -qE "(Microsoft|WSL)" /proc/version &> /dev/null ; then
    subl=/mnt/c/Program\ Files/Sublime\ Text\ 3/subl.exe
    os=win
else
    subl=subl #SublimeText 3
    #subl='tilix -e vim -p' #vim
    declare -a OpenFiles
    OpenFiles=("${DEBUG_DIR}" "${SMART_GREP}" "${PACK}" "${Bash_history}" "${hb_debug}" "${HB}" "${DF}" "${IFCONFIG}" "${SPACE_FILES}":100000 "${SYSDBtac}":100000 "${sm}" "${MESSAGES}":1000000 "${PicArray[@]}")
    #subl='tilix -e vim -g -p' #vim-gnome
    #to add:
    os=other
fi