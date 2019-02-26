#!/bin/bash

#for handling spaces in filenames
#IFS=$'\n'

#debugging with times:
#N=`date +%s%N`
#export PS4='+[$(((`date +%s%N`-$N)/1000000))ms][${BASH_SOURCE}:${LINENO}]: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'; set -x;

# set bash option to avoid
# unmatched patterns expand as result values
shopt -s nullglob

#win sub:sudo apt-get  install bc unzip (sqlite3) xmllint jq
#sudo apt install sqlite3 zenity sublime-text xmllint lftp jq

sleep_scan_dir=1 #Folder rescan time in seconds
sleep_extract_zip=0.5 #rescan time for finishing download
Script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DOWNLOAD_DIR=/home/thomas/Downloads/neu
DSM=dsm
CPU_FILE="${Script_dir}/files/CPU.txt"
PShedPy="${Script_dir}/files/power_shed.py"
rss="${Script_dir}/tmp/genRSS.php"
#cputxt_file="${Script_dir}/files/CPU.php"
#cputxt_file2="${Script_dir}/files/CPU2.php"
srs="${Script_dir}/tmp/SRS.php"
srsde="${Script_dir}/tmp/SRS-de.php"
available_packages_pre="${Script_dir}/tmp/available_packages_pre.txt"
available_packages="${Script_dir}/tmp/available_packages.txt"
package_versions="${Script_dir}/tmp/package_versions.txt"
mkdir -p "${Script_dir}/comp"
mkdir -p "${Script_dir}/tmp"
ProductList="${Script_dir}/comp/ProductList.json"


function log() {
    [[ "$verbose" != 1 ]] && return
    if read -t0.01; then
        { echo "$REPLY"; cat; } | sed 's/^/[verbose] /'
    fi
    for arg in "$@"; do
        echo -e "[verbose] $arg"
    done
}

bytesToHuman() {
    b=${1:-0}; d=''; s=0; S=(Bytes {K,M,G,T,P,E,Z,Y}iB)
    while ((b > 1024)); do
        d="$(printf ".%02d" $((b % 1024 * 100 / 1024)))"
        b=$((b / 1024))
        let s++
    done
    echo -n "$b$d ${S[$s]}"
}


#einbauen: Critical Updates: https://archive.synology.com/download/DSM/criticalupdate/update_pack/

while getopts ":uvh" opt; do
  case $opt in
    u)
        echo "updating files:" >&2
        echo -e "\nDownloading latest genRSS.php:"
        curl "https://update.synology.com/autoupdate/genRSS.php" -# --output "$rss"
        stat --printf="Size: %s" "$rss"

        #echo -e "\nDownloading CPU file:"
        #curl "https://www.synology.com/de-de/knowledgebase/DSM/tutorial/General/What_kind_of_CPU_does_my_NAS_have" -# --output "$cputxt_file"
        #stat --printf="Size: %s" "$cputxt_file"
        #awk '/<table id="b_4">/{f=1;next} /<\/table>/{f=0} f' "$cputxt_file" > "$cputxt_file2"

        echo -e "\nDownloading latest SRS-list:"
        curl "https://www.synology.com/de-de/solution/SRS" -# --output "$srs"
        stat --printf="Size: %s" "$srs"
        awk '/<div class="selected_country">Deutschland<\/div>/{f=1;next} /<div class="selected_country">Griechenland<\/div>/{f=0} f' "$srs" > "$srsde"
        #CommentedOut() { #uncomment this and line 86 to stop downloading hdd-comp on -u
        echo -e "\nGetting available Models:"
        curl "https://www.synology.com/cgi/misc/?action=getProductList_withOEM" -# | grep -oP '(?<=\[).*(?=\])' > "$ProductList" #get all Models listed in Synology API
        stat --printf="Size: %s" "$ProductList"
        IFS=","
        counter="0"
        for v in $(cat "$ProductList")
        do  Models["${counter}"]="${v//\"}"
            counter=`expr $counter + 1`
        done
        IFS=$' \t\n'
        echo -e "\nModels: ${Models[*]}" #old: echo -e "\nModels: ${Models[@]}"
        echo "Downloading In-/Compatibility-lists:"
            echo "set net:connection-limit 20" > "${Script_dir}/comp/lftp.cfg"
            echo "set xfer:clobber yes" >> "${Script_dir}/comp/lftp.cfg"
            for m in "${Models[@]}"
                do
                {
                    #n="${m,,}" #convert to lowercase
                    echo 'echo getting /comp/'"${m}"'_hdds_compatible.json'
                    echo 'get "https://www.synology.com/api/compatibility/findHclList?lang=en-global&search_by=products&model='"${m//+/%2B}"'&category=hdds&usage_id=12&recommend=t" -o "'"${Script_dir}"'/comp/'"${m}"'_hdds_compatible.json"'
                    #stat --printf=", Size: %s" "${Script_dir}/comp/${m}_hdds_compatible.json"
                    echo 'echo getting /comp/'"${m}"'_hdds_incompatible.json'
                    echo 'get "https://www.synology.com/api/compatibility/findHclList?lang=en-global&search_by=products&model='"${m//+/%2B}"'&category=hdds&usage_id=12&recommend=f" -o "'"${Script_dir}"'/comp/'"${m}"'_hdds_incompatible.json"'
                    #stat --printf=", Size: %s" "${Script_dir}/comp/${m}_hdds_compatible.json"
                } >> "${Script_dir}/comp/lftp.cfg"
                done
            echo "bye" >> "${Script_dir}/comp/lftp.cfg"
            lftp -f "${Script_dir}/comp/lftp.cfg"
            echo "done.";
            sed -e "s/\\\\\///g" -i "${Script_dir}"/comp/*.json #Kingston SSDs: remove "\/"
            #}
        echo "Updating latest package Versions:"
        lftp -c "open https://archive.synology.com/download/Package/spk/; cls" > "${available_packages_pre}"; #download package list
        sed -i '/^enabled$/d' "${available_packages_pre}"
        echo "Number of available Packages: $(cat "${available_packages_pre}" | wc -w)"
        	echo "set net:connection-limit 20" > "${Script_dir}/comp/lftp2.cfg"
        	echo "set xfer:clobber yes" >> "${Script_dir}/comp/lftp2.cfg"
            cat "${available_packages_pre}" | awk -v OFS="\\\ " '$1=$1' > "${available_packages}"
            declare -a "PackageArray" #??
        	readarray -t "PackageArray" < "${available_packages}"
            #echo "Array: ${PackageArray[@]}" #package array, i.e. Java7/
        	echo "" > "${package_versions}"
            echo "open https://archive.synology.com/download/Package/spk/" >> "${Script_dir}/comp/lftp2.cfg"
        	for v in "${PackageArray[@]}"
        	do
                echo "echo -n "\""${v//\/}" \""; cd ${v}; dir | tail -n1 | cut -d \' \'  -f18; cd .." >> "${Script_dir}/comp/lftp2.cfg"
        	done
        	echo "bye" >> "${Script_dir}/comp/lftp2.cfg"
            lftp -f "${Script_dir}/comp/lftp2.cfg" | tee "${package_versions}"
        	cat "${package_versions}"
      ;;
    h)
        echo -e "\navailable commandline-arguments are:\n"
        echo -e "\t-h : Show this help"
        echo -e "\t-u : Update SRS-List, DSM-Updates, HDD-(in-)compatibility-lists, package updates"
        echo -e "\t-v : Be Verbose."
        echo -e "\n"
        exit 1
      ;;
    v)
        verbose=1
      ;;
    \?)
      echo "Invalid option: -$OPTARG. List all options with -h" >&2
      exit 1
      ;;
  esac
done


if [[ "$(find "${Script_dir}"/tmp/ -name genRSS.php -mmin +600)" ]] || [[ -z $(find "${Script_dir}"/tmp/ -name genRSS.php) ]]; then  #update, if no file found or older than 10 hours
        touch "${Script_dir}/tmp/genRSS.php"
        echo "Downloading latest genRSS.php:"
        curl "https://update.synology.com/autoupdate/genRSS.php" -# --output "$rss"
fi

#if [[ $(find "${Script_dir}"/files/ -name CPU.php -mmin 700) ]] || [[ -z $(find "${Script_dir}"/files/ -name CPU.php) ]]; then  #update, if no file found or older than 10 hours
        #echo -e "\nDownloading CPUs:"
        #curl "https://www.synology.com/de-de/knowledgebase/DSM/tutorial/General/What_kind_of_CPU_does_my_NAS_have" -# --output "$cputxt_file"
                #awk '/<table id="b_4">/{f=1;next} /<\/table>/{f=0} f' "$cputxt_file" > "$cputxt_file2"
#fi

if [[ "$(find "${Script_dir}"/tmp/ -name SRS.php -mmin +600)" ]] || [[ -z $(find "${Script_dir}"/tmp/ -name SRS.php) ]]; then  #update, if no file found or older than 10 hours
        touch "${Script_dir}/tmp/SRS.php"
        echo "Downloading latest SRS-list:"
        curl "https://www.synology.com/de-de/solution/SRS" -# --output "$srs"
        awk '/<div class="selected_country">Deutschland<\/div>/{f=1;next} /<div class="selected_country">Griechenland<\/div>/{f=0} f' "$srs" > "$srsde"
fi

if [[ "$(find "${Script_dir}"/comp/ -name lftp.cfg -mmin +5040)" ]] || [[ -z $(find "${Script_dir}"/comp/ -name lftp.cfg) ]]; then  #update, if no file found or older than 20 hours
        touch "${Script_dir}/comp/lftp.cfg"
        echo -e "\nGetting available Models:"
        curl "https://www.synology.com/cgi/misc/?action=getProductList_withOEM" -# | grep -oP '(?<=\[).*(?=\])' > "$ProductList" #get all Models listed in Synology API
        stat --printf="Size: %s" "$ProductList"
        IFS=","
        #declare -a ModelArray
        counter="0"
        for v in $(cat "$ProductList")
        do
            Models["${counter}"]="${v//\"}"
            #$(expr "${PoH}" - "${LastSmartTest}" )
            #counter=$((counter + 1))
            counter=`expr $counter + 1`
        done
        IFS=$' \t\n'
        echo -e "\nModels: ${Models[*]}" #old: echo -e "\nModels: ${Models[@]}"
        echo "Downloading In-/Compatibility-lists:"
            echo "set net:connection-limit 20" > "${Script_dir}/comp/lftp.cfg"
            echo "set xfer:clobber yes" >> "${Script_dir}/comp/lftp.cfg"
            for m in "${Models[@]}"
                do
                {
                    #n="${m,,}" #convert to lowercase
                    echo 'echo getting /comp/'"${m}"'_hdds_compatible.json'
                    echo 'get "https://www.synology.com/api/compatibility/findHclList?lang=en-global&search_by=products&model='"${m//+/%2B}"'&category=hdds&usage_id=12&recommend=t" -o "'"${Script_dir}"'/comp/'"${m}"'_hdds_compatible.json"'
                    #stat --printf=", Size: %s" "${Script_dir}/comp/${m}_hdds_compatible.json"
                    echo 'echo getting /comp/'"${m}"'_hdds_incompatible.json'
                    echo 'get "https://www.synology.com/api/compatibility/findHclList?lang=en-global&search_by=products&model='"${m//+/%2B}"'&category=hdds&usage_id=12&recommend=f" -o "'"${Script_dir}"'/comp/'"${m}"'_hdds_incompatible.json"'
                    #stat --printf=", Size: %s" "${Script_dir}/comp/${m}_hdds_compatible.json"
                } >> "${Script_dir}/comp/lftp.cfg"
                done
            echo "bye" >> "${Script_dir}/comp/lftp.cfg"
            lftp -f "${Script_dir}/comp/lftp.cfg"
            echo "done.";
            sed -e "s/\\\\\///g" -i "${Script_dir}"/comp/*.json #Kingston SSDs: remove "\/"
            #}
        echo "Updating latest package Versions:"
        lftp -c "open https://archive.synology.com/download/Package/spk/; cls" > "${available_packages_pre}"; #download package list
        sed -i '/^enabled$/d' "${available_packages_pre}"
        echo "Number of available Packages: $(cat "${available_packages_pre}" | wc -w)"
            echo "set net:connection-limit 20" > "${Script_dir}/comp/lftp2.cfg"
            echo "set xfer:clobber yes" >> "${Script_dir}/comp/lftp2.cfg"
            cat "${available_packages_pre}" | awk -v OFS="\\\ " '$1=$1' > "${available_packages}"
            declare -a "PackageArray" #??
            readarray -t "PackageArray" < "${available_packages}"
            #echo "Array: ${PackageArray[@]}" #package array, i.e. Java7/
            echo "" > "${package_versions}"
            echo "open https://archive.synology.com/download/Package/spk/" >> "${Script_dir}/comp/lftp2.cfg"
            for v in "${PackageArray[@]}"
            do
                echo "echo -n "\""${v//\/}" \""; cd ${v}; dir | tail -n1 | cut -d \' \'  -f18; cd .." >> "${Script_dir}/comp/lftp2.cfg"
            done
            echo "bye" >> "${Script_dir}/comp/lftp2.cfg"
            lftp -f "${Script_dir}/comp/lftp2.cfg" | tee "${package_versions}"
            cat "${package_versions}"
        fi

echo "Waiting for debug-files..."

log "Verbose logging enabled."

while true;
do
    for file in "${DOWNLOAD_DIR}"/*.dat
    do
        if [[ -f "${file}" ]]
        then
            while [[ -f "${file}".part ]] #wait for file to finish downloading (Firefox)
            do
                #echo "Waiting for Download to finish.."
                sleep $sleep_extract_zip
            done
            time(
            date_now=$(date +"%d. %B %H:%M:%S:")
            echo "$date_now found .dat-file! Timer started now"
            #DATE=$(echo "$(date +"%H%M%S") - ($(date +%S)%10)" | bc)
            DATE=$(date -d @$(( $(date +%s) / 10 * 10 )) +%H%M%S)
            TIMEFORMAT=$'Extractiontime debug.dat: \t\t\t\t\t\t\t\e[36m%Rsec\e[39m'
            time(
            unzip -q "$file" -d "$DOWNLOAD_DIR"/debug_"$DATE"
            )
            if [ $? -eq 0 ] # if successfully extracted
            then
                mv "$file" "$DOWNLOAD_DIR"/debug_"$DATE"
                date_now=$(date +"%d. %B %H:%M:%S:")
                echo "$date_now debug extracted to $DOWNLOAD_DIR/debug_$DATE"
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/packages.list" ]]
                then    DSM=""
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/ha/ha.conf" ]]
                then
                    if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/ha/passive_debug.dat" ]]
                    then
                        sm="$DOWNLOAD_DIR/debug_$DATE/$DSM/sm.log"
                        echo -e "Synology HA: Detected, this is the ACTIVE Server-log" >> "$sm"
                        mv "$DOWNLOAD_DIR/debug_$DATE/$DSM/ha/passive_debug.dat" "$DOWNLOAD_DIR/passive_debugfile.dat"
                    fi
                elif [[ "$file" = "$DOWNLOAD_DIR/passive_debugfile.dat" ]]; then
                    DSM=$(ls "$DOWNLOAD_DIR/debug_$DATE/tmp" )
                    DSM="tmp/${DSM}"
                    sm="$DOWNLOAD_DIR/debug_$DATE/$DSM/sm.log"
                    echo -e "Synology HA: Detected, this is the PASSIVE Server-log" >> "$sm"
                else
                    sm="$DOWNLOAD_DIR/debug_$DATE/$DSM/sm.log"
                    #echo -e "No Synology HA detected" >> "$sm"
                fi
                sg=$DOWNLOAD_DIR/debug_$DATE/$DSM/smartgrep
                hb_debug=$DOWNLOAD_DIR/debug_$DATE/$DSM/hibernation_debug.log
                DEBUG_DIR=$DOWNLOAD_DIR/debug_$DATE
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc.defaults/synoinfo.conf" ]]
                then
                    Synoinfo=$DOWNLOAD_DIR/debug_$DATE/$DSM/etc.defaults/synoinfo.conf
                elif [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf" ]]
                then
                    Synoinfo=$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf
                else
                    log "Synoinfo.conf not found."
                fi


                UpnpModel=$(grep -i "upnpmodelname" "$Synoinfo" | cut -d "\"" -f2)
                UpnpModel_migrated_from=$(grep -i "upnpmodelname" "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf" | cut -d "\"" -f2)
                            #TIMEFORMAT=$'Extractiontime messages.xz and kern.xz:\t\t\t\t\t\t\e[36m%Rsec\e[39m'
                            #time(
                    for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages"*.xz
                        do
                            unxz "${file}"
                        done

                    for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/kern"*.xz
                        do
                            unxz "${file}"
                        done
                                #)

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/df.result" ]]
                then    DF=$DOWNLOAD_DIR/debug_$DATE/$DSM/result/df.result
                        full_number=$(awk '0+$5 >= 90 { count++ } END{print 0+count}' "$DF")
                        if [[ "$full_number" -gt 0 ]]
                        then
                            echo -e "\nMountpoints more than 90% full: (""$full_number"")" >> "$sm"
                            awk '0+$5>90 { printf "\n%s",$0 }' "$DF" >> "$sm"
                            echo -e "\n" >> "$sm"
                            echo -n "Mountpoints more than 90% full: (""$full_number"")" >> "$sg"
                            awk '0+$5>90 { printf "\n%s",$0 }' "$DF" >> "$sg"
                        else
                            echo "Mountpoints more than 90% full: (""$full_number"")" >> "$sg"
                            #echo " No full Mountpoints found." >> "$sm"
                            echo "No full Mountpoints found." >> "$sg"
                        fi
                        echo -e "\n"  >> "$sg"
                fi

                #check for 16Tb Volume limitation
                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/tune2fs/dev.vg"*".result"
                        do
                            [[ -e "$file" ]] || log "No vg files found."
                            [[ -e "$file" ]] || break
                            Volume_Features=$(grep -a "Filesystem features" "$file")
                                if [ "$Volume_Features" ]; then
                                    Volume_x64=$(grep -a "Filesystem features" "$file" | grep 64bit)
                                    if  [ "$Volume_x64" ]; then
                                        log "$(basename -- "$file") has x64"
                                    else
                                        echo -e "$(basename -- "$file" | cut -d '.' -f2) has 16 Terabyte Volume Limitation." >> "$sm"
                                    fi
                                fi
                        done

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/proc/mdstat" ]]
                then    MDSTAT=$DOWNLOAD_DIR/debug_$DATE/$DSM/proc/mdstat
                        cat "$MDSTAT" >> "$sg"
                        cat "$MDSTAT" | egrep 'md[^01]' -A2 | sed -r '/^\s*$/d' >> "$sm"
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/bash_history.log" ]]
                then    Bash_history=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/bash_history.log
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/proc/mounts" ]]
                then    MOUNTS=$DOWNLOAD_DIR/debug_$DATE/$DSM/proc/mounts
                        echo -e "\nMountpoints:" >> "$sg"
                        cat "$MOUNTS" >> "$sg"
                        echo -e " \n"  >> "$sg"
                        echo -e "Mountpoints:" >> "$sm"
                        grepmounts=$(grep -i "volume" "$MOUNTS" | cut -f1 -d",")
                        grepmounts_c=$(grep -i -c "volume" "$MOUNTS" | cut -f1 -d",")
                        if [ "$grepmounts_c" -ne 0 ]
                            then echo "$grepmounts" >> "$sm"
                        else echo "No Volumes mounted." >> "$sm"
                        fi

                fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/ifconfig.result" ]]
                then    IFCONFIG=$DOWNLOAD_DIR/debug_$DATE/$DSM/result/ifconfig.result
                    ipv6_enabled=$(grep eth -A7 "$IFCONFIG" | grep -c "inet6 addr")
                    declare -a ifc_dropped
                    ifc_dropped=$(grep "dropped" "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/ifconfig.result" | sed 's/.*dropped://' | cut -d " " -f1)
                    ifc_dropped_sum=0
                    for i in "${ifc_dropped[@]}"; do
                        let ifc_dropped_sum+=$i
                    done

                    declare -a ifc_error
                    ifc_error=$(grep "errors" "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/ifconfig.result" | sed 's/.*errors://' | cut -d " " -f1)
                    ifc_error_sum=0
                    for i in "${ifc_error[@]}"; do
                        let ifc_error_sum+=$i
                    done
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/ntp.conf" ]]
                then    ntp=$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/ntp.conf
                        ntp_google=$(grep -c time.google.com.conf "$ntp")
                        ntp_pool=$(grep -c pool.ntp.org.conf "$ntp")
                        ntp_other=$(grep -c "server " "$ntp")
                        ntp_other_awk=$(grep "server " "$ntp" | awk ' {print $2 }')
                        if [ "$ntp_google" -gt 0 ]
                            then echo "NTP-Client on NAS is on. Server is time.google.com" >> "$hb_debug"
                        elif [ "$ntp_pool" -gt 0 ]
                            then echo "NTP-Client on NAS is on. Server is pool.ntp.org" >> "$hb_debug"
                        elif [ "$ntp_other" -gt 0 ]
                            then echo -n "NTP-Client on NAS is on. Server is " >> "$hb_debug"
                                 echo "$ntp_other_awk" >> "$hb_debug"
                        else
                            echo "Time set to manual, NTP-Client on NAS is off." >> "$hb_debug"
                        fi
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/usr/syno/etc/synoservice.override/ntpd-server.cfg" ]]
                then    ntpd_server_cfg=$DOWNLOAD_DIR/debug_$DATE/$DSM/usr/syno/etc/synoservice.override/ntpd-server.cfg
                        echo -n "NTP-Server: " >> "$hb_debug"
                        ntp_server_enabled=$(grep -c yes "$ntpd_server_cfg")
                        if [ "$ntp_server_enabled" -gt 0 ]
                            then echo "NTP-Server on NAS is on." >> "$hb_debug"
                        elif [ "$ntp_server_enabled" -eq 0 ]
                            then echo "NTP-Server on NAS is off." >> "$hb_debug"
                        fi
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/hostname" ]]
                then    Hostname=$(cat "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/hostname")
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/usr/syno/etc/synorelayd/synorelayd.conf" ]]
                then    QuickConnect_alias=$(grep '"alias"' "$DOWNLOAD_DIR/debug_$DATE/$DSM/usr/syno/etc/synorelayd/synorelayd.conf" | sed "s/.*: //" | sed 's/\"//g')
                if [[ -z "$QuickConnect_alias" ]]; then
                    QuickConnect_echo="No QuickConnect alias is set"
                    echo "QuickConnect on NAS is off." >> "$hb_debug"
                    else QuickConnect_echo="QuickConnect Hostname: ""$QuickConnect_alias"".quickconnect.to"
                    echo "QuickConnect on NAS is on." >> "$hb_debug"
                fi
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages" ]]
                then    MESSAGES=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages.log
                        mv "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages" "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages.log"
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/ddns.conf" ]]
                then    ddns=$(grep -c "service=true" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/etc/ddns.conf)
                    if [[ $ddns = 1 ]]; then
                        echo "DDNS on NAS is on." >> "$hb_debug"
                    fi
                    if [[ $ddns = 0 ]]; then
                        echo "DDNS on NAS is off." >> "$hb_debug"
                    fi
                fi

                #Analyze ExtensionUnits
                echo -n "ExtensionUnits:" >> "$sm"
                OIFS=$IFS
                IFS=","
                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/sys/class/scsi_host/host"*"/syno_pm_info"
                        do
                            [[ -e "$file" ]] || log "$file not found."
                            [[ -e "$file" ]] || break
                            ExtensionHdds=$(grep -a "syno_device_list" "$file" | cut -d "\"" -f2 | sed 's/\/dev\///g')
                            ExtensionHddsLoopArray=("$ExtensionHdds")
                            for ((i=0; i<${#ExtensionHddsLoopArray[@]}; ++i))
                            do
                                if [ -n "${ExtensionHddsArray[$i]}" ]; then
                                    ExtensionHddsArray=("${ExtensionHddsArray[@]}" "${ExtensionHddsLoopArray[i]}")
                                fi
                            done
                            ExtensionUnit=$(grep "Unique" "$file" | cut -d "\"" -f2)
                            if [ -n "$ExtensionUnit" ]; then
                                echo -e "\n$ExtensionUnit with $ExtensionHdds" >> "$sm"
                            fi
                        done
                IFS=$OIFS
                if [ -z "$ExtensionHdds" ]; then
                    echo -e " none" >> "$sm"
                fi
                if [ "$UpnpModel_migrated_from" != "$UpnpModel" ]; then
                    echo "DSM was possibly migrated from $UpnpModel_migrated_from to $UpnpModel" >> "$sm"
                fi

                #TIMEFORMAT=$'hdd-compatibility-check until opening Sublime took\t\t\t\t\e[36m%Rsec\e[39m'
                            #time(

                log "Extension all hdds-array: ${ExtensionHddsArray[@]}"
               # if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/etc/private/domain_info ]]
               # then    windomain=$(grep "ads:domain_name" $DOWNLOAD_DIR/debug_$DATE/$DSM/etc/private/domain_info)
               # if [[ -z "$windomain" ]]; then
               #     echo "Not in a AD." >> "$sm"
               #     else echo "Domainname: $windomain" >> "$sm"
               # fi
               # fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/uptime.result" ]]
                then    UPTIME=$(cat "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/uptime.result)
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/hibernation.log" ]]
                then    HB=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/hibernation.log
                fi

                declare -a SMART_FILES
                SMART_FILES=( "${DOWNLOAD_DIR}/debug_${DATE}/${DSM}/result/smart"*.result )

                declare -a SMART_neu
                SMART_neu=( "${DOWNLOAD_DIR}/debug_${DATE}/${DSM}/var/log/smart_result/"*.txz )


                if [ "${#SMART_FILES[@]}" -ne "0" ]; then
                log "altsmart#: ${#SMART_FILES[@]}"
                fi
                if [ "${#SMART_neu[@]}" -ne "0" ]; then
                        tar xf "${SMART_neu[*]: -1}" -C "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/"
                        #oder: tar xf "${SMART_neu[*]: -2:1}" -C "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/"
                        #tar xf "${SMART_neu[-1]}" -C "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/" #geht!
                        smarttar=$(ls "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/var/log/smart_result/ )
                        for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/var/log/smart_result/$smarttar/"*
                        do
                            [[ -e "$file" ]] || break #no smart-files
                            filename=$(basename -- "$file")
                            mv "$file" "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/smart_$filename".result
                        done
                        SMART_FILES=( "${DOWNLOAD_DIR}/debug_${DATE}/${DSM}/result/smart"*.result )
                        log "neusmart#: ${#SMART_FILES[@]}"
                else
                    log "No new Smart-files found."
                fi

                counter=0
                declare -a BadSectors_HDD_Array
                declare -a PendingSectors_HDD_Array
                declare -a OfflineUncorrectable_HDD_Array
                files="
                "
                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/smart_"{sd,nv,sas}*.result
                do
                    [[ -e "$file" ]] || break #no smart-files
                    #counter=$((counter + 1))
                    counter=`expr $counter + 1`
                    declare -a BadSectors
                    declare -a PendingSectors
                    declare -a OfflineUncorrectable
                    BadSectors=$(grep -i "Reallocated_Sector_Ct\|Reallocated_Sector_Count" "$file" | awk '{print 0+$10 }')
                    PendingSectors=$(grep -i "Current_Pending_Sector" "$file" | awk '{print 0+$10 }')
                    OfflineUncorrectable=$(grep -i "Offline_Uncorrectable\|Uncorrectable_Error_Count" "$file" | awk '{print 0+$10 }')

                    if [ "${BadSectors[@]}" -gt 0 ] 2>/dev/null; then
                        BadSectors_HDD_Array+=$(basename -- "$file ")
                    fi
                    if [ "${PendingSectors[@]}" -gt 0  ] 2>/dev/null; then
                        PendingSectors_HDD_Array+=$(basename -- "$file ")
                    fi
                    if [ "${OfflineUncorrectable[@]}" -gt 0 ] 2>/dev/null ; then
                        OfflineUncorrectable_HDD_Array+=$(basename -- "$file ")
                    fi
                    for i in "${BadSectors[@]}"; do
                        (( BadSector_sum+="$i" )) &> /dev/null
                    done
                    for i in "${PendingSectors[@]}"; do
                        (( PendingSectors_sum+="$i")) &> /dev/null
                    done
                    for i in "${OfflineUncorrectable[@]}"; do
                        (( OfflineUncorrectable_sum+="$i" ))  &> /dev/null #shows errors, if Offline_uncorrectable not found in a smart-file (Intel SSDs)

                    done
                done
                    # if [ "$OfflineUncorrectable_sum" -gt 0 ]; then
                    #     BadSectors_HDD_Array+=$(basename -- "$file")
                    #     echo "Reallocated_Sector_Ct:" "$BadSector_sum in $(basename -- "$file")" >> "$sm"
                    # fi
                    # if [ "$PendingSectors_sum" -gt 0 ]; then
                    #     PendingSectors_HDD_Array+=$(basename -- "$file")
                    #     echo "Current_Pending_Sector:" "$PendingSectors_sum in $(basename -- "$file")" >> "$sm"
                    # fi
                    # if [ "$OfflineUncorrectable_sum" -gt 0 ]; then
                    #     OfflineUncorrectable_HDD_Array+=$(basename -- "$file")
                    #     echo "Offline_Uncorrectable:" "$OfflineUncorrectable_sum in $(basename -- "$file")" >> "$sm"
                    # fi


                if [ -z "${UpnpModel}" ]; then
                    echo "CPUinfo from txt: no model detected." >> "$sm"
                fi

                log "${UpnpModel}"
                log "${UpnpModel/+/\\+}\S"
                DS_CPU_TXTINFO=$( grep -m1 "CPU-Modell" "$CPU_FILE" )
                DS_CPU_TXT=$( grep "${UpnpModel}[[:space:]]" "$CPU_FILE" )
                {
                echo -e "\nCPUinfo from txt:"
                echo "$DS_CPU_TXTINFO"
                echo -e "$DS_CPU_TXT\n"
                }  >> "$sm"

                #echo -e "\nUPNP Model: $UpnpModel\n$counter HDDs:" >> "$sm"
                if [ -z "${BadSector_sum+x}" ]; then
                    echo "Reallocated_Sector_Ct: error" >> "$sm"
                    elif [[ "${BadSector_sum}" -eq 0 ]]; then
                    echo "Reallocated_Sector_Ct: 0" >> "$sm"
                    else
                    echo "Reallocated_Sector_Ct:" "$BadSector_sum in ${BadSectors_HDD_Array[@]}" >> "$sm"
                fi
                if [ -z "${PendingSectors_sum+x}" ]; then
                    echo "Current_Pending_Sector: error" >> "$sm"
                    elif [[ "${PendingSectors_sum}" -eq 0 ]]; then
                    echo "Current_Pending_Sector: 0" >> "$sm"
                    else
                    echo "Current_Pending_Sector:" "$PendingSectors_sum in ${PendingSectors_HDD_Array[@]}" >> "$sm"
                fi
                if [ -z "${OfflineUncorrectable_sum+x}" ]; then
                    echo "Offline_Uncorrectable: error" >> "$sm"
                    elif [[ "${OfflineUncorrectable_sum}" -eq 0 ]]; then
                    echo "Offline_Uncorrectable: 0" >> "$sm"
                    else
                    echo "Offline_Uncorrectable:" "$OfflineUncorrectable_sum in ${OfflineUncorrectable_HDD_Array[@]}" >> "$sm"
                fi

                UpnpModelCASE=${UpnpModel/rp/RP}
                #hdd-compatibility:
                if [[ -f "${Script_dir}/comp/${UpnpModelCASE}_hdds_compatible.json" ]]; then
                    comp_list="${Script_dir}/comp/${UpnpModelCASE}_hdds_compatible.json"
                    log "\e[32mCompatibility-list for ${UpnpModel} found and set. ($comp_list)\e[0m"
                else
                    echo -e "\e[31mCompatibility-list for ${UpnpModel} not found! should be ${Script_dir}/comp/${UpnpModelCASE}_hdds_compatible.json\e[0m"
                    echo -e "Compatibility-list for ${UpnpModel} not found! should be ${Script_dir}/comp/${UpnpModelCASE}_hdds_compatible.json\nTHE FOLLOWING COMPATIBILITY RESULTS ARE WRONG:" >> "$sm"
                fi

                if [[ -f "${Script_dir}/comp/${UpnpModelCASE}_hdds_incompatible.json" ]]; then
                    incomp_list="${Script_dir}/comp/${UpnpModelCASE}_hdds_incompatible.json"
                    log "\e[32mIncompatibility-list for ${UpnpModel} found and set. ($incomp_list)\e[0m"
                else
                    echo -e "\e[31mIncompatibility-list for ${UpnpModel} not found! should be ${Script_dir}/comp/${UpnpModelCASE}_hdds_incompatible.json\e[0m"
                    echo -e "Incompatibility-list for ${UpnpModel} not found! should be ${Script_dir}/comp/${UpnpModelCASE}_hdds_incompatible.json\nTHE FOLLOWING COMPATIBILITY RESULTS ARE WRONG:" >> "$sm"
                fi

                #declare -a PowerOnHours
                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/smart"*.result
                do
                    [[ -e "$file" ]] || break #no smart-files
                    hddname=$(basename -- "$file")
                    hddname2=$(grep -i "Model Family\|Device Model" "$file" | cut -d " " -f7-20 | sed -r 's/\"/Inch/' | xargs )
                    modelname=$(grep -i "Device Model" "$file" | cut -d " " -f8 | sed -r 's/\"/Inch/' | xargs ) #evtl f7-20
                    modelname_hdd_size=$(grep -i "User Capacity" "$file" | awk -F '[][]+' 'NF && !/\[\[/{print $2}' | sed 's/\..* //' | sed 's/\.* //' ) # i.e.: 3TB or 500GB
                    SectorSize=$(grep -i "Sector Size" "$file" | cut -d ":" -f2 | sed -e 's/^[ \t]*//' | cut -d " " -f1 )
                    if [[ "${modelname}" == "SSD" ]]; then #samsung SSDs!
                        modelname=$(grep -i "Device Model" "$file" | cut -d " " -f9-10 | sed -r 's/\"/Inch/' | xargs)
                        modelname_hdd_size=$(grep -i "Device Model" "$file" | cut -d " " -f11 | xargs)
                        modelname_first_part=$(grep -i "Device Model" "$file" | cut -d " " -f8 | sed -r 's/\"/Inch/' | cut -d "-" -f1 )
                    modelname_first_part=$(grep -i "Device Model" "$file" | cut -d " " -f8 | sed -r 's/\"/Inch/' | cut -d "-" -f1 ) #evtl f7-20
                    fi
                    #to add: include size of HDD/SSD
                    if [[ -z "${modelname}" ]]; then
                        modelname=$(grep -i "Device Model" "$file" | cut -d " " -f7 | sed -r 's/\"/Inch/' | xargs )
                        modelname_first_part=$(grep -i "Device Model" "$file" | cut -d " " -f7 | sed -r 's/\"/Inch/' | cut -d "-" -f1)
                    fi

                    #for SAS in FS2017
                    if [[ -z "${modelname}" ]]; then
                        modelname=$(grep -i "Product" "$file" | cut -d ":" -f2 | xargs )
                        hddname2=$(grep -i "Vendor:\|Product:" "$file" | cut -d ":" -f2 | xargs )
                    fi

                    #Samsung SSDs
                    if [[ -z "${modelname}" ]]; then
                        filename=$(basename -- "$file")
                        model_file=$(echo "$filename" | cut -d "." -f1 | rev | cut -d "_" -f1 | rev)
                        modelname=$(grep -i "$model_file" "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/disk_overview.xml" -m1 | cut -d "\"" -f2 | awk -F 'SSD ' '{print $2 }' | xargs)
                        hddname2=$(grep -i "$model_file" "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/disk_overview.xml" -m1 | cut -d "\"" -f2 | xargs )
                    fi

                    if [[ -z "${modelname}" ]]; then
                        HDDComp=""
                        log "\e[31mHDD-Comp: Modelname empty!\e[0m"
                    elif grep "${modelname}" "${incomp_list}" &> /dev/null; then
                        HDDComp="(incompatible)"
                        log "HDD-INComp: found \"\e[31m${modelname}\e[0m\""
                    elif grep "${modelname//-/ - }" "${incomp_list}" &> /dev/null; then
                        HDDComp="(incompatible)"
                        log "HDD-INComp: found \"\e[31m${modelname//-/ - }\e[0m\""
                    elif grep  "${modelname%-*}" "${incomp_list}" &> /dev/null; then # remove part after "-"; check if two parts first?
                        HDDComp="(incompatible)"
                        log "HDD-INComp: found \"\e[32m${modelname%-*}\e[0m\""
                    elif grep  "${modelname}" "${comp_list}" &> /dev/null; then
                        HDDComp="(compatible)"
                        log "HDD-Comp: found \"\e[32m${modelname}\e[0m\""
                    elif grep  "${modelname//-/ - }" "${comp_list}" &> /dev/null; then
                        HDDComp="(compatible)"
                        log "HDD-Comp: found \"\e[32m${modelname//-/ - }\e[0m\""
                    elif grep  "${modelname%-*}" "${comp_list}" &> /dev/null; then # remove part after "-"; check if two parts first?
                        HDDComp="(compatible)"
                        log "HDD-Comp: found \"\e[32m${modelname%-*}\e[0m\""
                    else
                        HDDComp="(not listed)"
                        log "\e[34mHDD-Comp: \"${modelname}\" not found.\e[0m"
                    fi
                    log "compatibility check for ${hddname} grepped for ${modelname} , ${modelname//-/ - } and ${modelname%-*} ; HDD Size: ${modelname_hdd_size}"
                    echo -n "$hddname: $hddname2 $HDDComp: PowerOnHours: " >> "$sm"
                    PoH=$(grep -iE "Power(_|-)on_(Hours|Hour_Count)" "$file" | sed -e "s/ ([^()]*)//g" | rev | cut -d " " -f1 | rev | sed 's/h.*//' )
                    echo "${PoH}" >> "$sm"
                    echo -n "Last Extended SMART-Test: " >> "$sm"
                    LastSmartTest=$(grep -i -m1 "Extended Offline" "$file" | sed -n '/Extended offline/s/ \+/ /gp' | rev | cut -d " " -f2 | rev )
                    LastSmartResult=$(grep -i -m1 "Extended Offline" "$file" | sed -n '/Extended offline/s/ \+/ /gp' | sed 's/[^0-9]*[0-9] *//' | sed 's/ [0-9].*$//' | sed 's/^Extended offline //' )
                    #old:                     LastSmartResult=$(grep -i -m1 "Extended Offline" "$file" | sed -n '/Extended offline/s/ \+/ /gp' | cut -d " " -f5-7 )
                    re='^[0-9]+$'
                    if ! [[ "${LastSmartTest}" =~ $re ]] ; then
                    LastSmartTest=$(grep -i -m1 "Extended Offline" "$file" | sed -n '/Extended offline/s/ \+/ /gp' | cut -d " " -f8 )
                    LastSmartResult=$(grep -i -m1 "Extended Offline" "$file" | sed -n '/Extended offline/s/ \+/ /gp' | cut -d " " -f4-8 )
                    fi
                    if [[ -z "${LastSmartTest}" ]]; then
                    echo -n "never" >> "$sm"
                    elif [[ -z "${LastSmartTest+x}" ]]; then
                    echo "error"
                        else
                        LastSmartExpr=$(expr "${PoH}" - "${LastSmartTest}" )
                        #log "expr: $PoH und $LastSmarttest"
                        echo -n "$LastSmartExpr" "hours ago, $LastSmartResult" >> "$sm"
                    fi
                    echo -n ", Sectorsize: $SectorSize" >> "$sm"
                    echo ", HDD Size: $modelname_hdd_size" >> "$sm"
                done
                #mehr smart-kram
                #echo -e "\n" >> "$sm"

                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/smart_"{sd,nv,sas}*.result
                do
                    [[ -e "$file" ]] || break #no smart-files
                    grep -i "Model Family\|Device Model" "$file" >> "$sg"
                done
                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/smart_"{sd,nv}*.result
                do
                    [[ -e "$file" ]] || break #no smart-files
                {
                    echo -e "\n"
                    echo "$file"
                    grep -i "overall-health self-assessment\|Model Family\|Device Model\|Serial Number\|Firmware Version\|User Capacity\|Sector Sizes\|Rotation Rate\|ID\#\|Raw_Read_Error_Rate\|Reallocated_Sector_Ct\|Seek_Error_Rate\|Spin_Retry_Count\|Calibration_Retry_Count\|Reallocated_Event_Count\|Current_Pending_Sector\|Offline_Uncorrectable\|UDMA_CRC_Error_Count\|Multi_Zone_Error_Rate\|Power_On_Hours\|Reallocated_Sector_Count\|Power-on_Hours\|Program_Fail_Count_(total)\|Erase_Fail_Count_(total)\|Runtime_Bad_Count_(total)\|Uncorrectable_Error_Count\|Uncorrectable_Error_Cnt\|Airflow_Temperature_Cel\|ECC_Error_Rate\|CRC_Error_Count\|POR_Recovery_Count\|Percent_Lifetime_Remain" "$file"
                            echo " "
                            awk '/SMART Error Log Version: 1/{f=1;next} /Selective self-test flags/{f=0} f' "$file"
                    echo -e " \n \n"
                } >> "$sg"
                done

                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/smart_sas"*.result
                do
                    [[ -e "$file" ]] || break #no smart-files
                {
                    echo -e "\n"
                    echo "$file"
                    grep -i "overall-health self-assessment\|Model Family\|Device Model\|Serial Number\|Firmware Version\|Vendor\|Product\|User Capacity\|Sector Sizes\|Rotation Rate\|Logical block size\|Physical block size\|Rotation Rate\|Form Factor\|Transport protocol\|SMART support is\|SMART support is\|Raw_Read_Error_Rate\|Reallocated_Sector_Ct\|Seek_Error_Rate\|Spin_Retry_Count\|Calibration_Retry_Count\|Reallocated_Event_Count\|Current_Pending_Sector\|Offline_Uncorrectable\|UDMA_CRC_Error_Count\|Multi_Zone_Error_Rate\|Power_On_Hours\|Reallocated_Sector_Count\|Power-on_Hours\|Program_Fail_Count_(total)\|Erase_Fail_Count_(total)\|Runtime_Bad_Count_(total)\|Uncorrectable_Error_Count\|ECC_Error_Rate\|CRC_Error_Count\|POR_Recovery_Count\|Percent_Lifetime_Remain" "$file"
                            echo " "
                            awk '/=== START OF READ SMART DATA SECTION ===/{f=1;next} /END/{f=0} f' "$file"
                            awk '/SMART Error Log Version: 1/{f=1;next} /Selective self-test flags/{f=0} f' "$file"
                } >> "$sg"
                done

                ls -lh "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/space/space_history_"*.xml >> "$DOWNLOAD_DIR/debug_$DATE/$DSM/space.xml"

                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/space/space_history_"*.xml
                do
                    [[ -e "$file" ]] || break #no space-files
                    {
                    echo "$(basename -- "$file")"
                    CountHDDs1=$(awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' "$file" | grep -v "vg" | grep -v "volume" | tr '\n' ' '  | sed 's#  #\n\n#g' | wc -w)
                    #CountHDDs2="$(($CountHDDs1-1))" //entfernen
                    echo -en "############################################\t#HDDs: $(($CountHDDs1-1))\t"
                    awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' "$file" | grep -v "vg" | grep -v "volume" | tr '\n' ' '  | sed 's#  #\n#g'
                    echo "SerialNumbers:"
                    awk -F '"' '/dev_path/ {print $8} /raid>/ {print $5}' "$file" | grep -v "vg" | grep -v "volume" | tr '\n' ' '  | sed 's#  #\n#g'
                    echo -e '\n'
                    #cat "$file" | awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' - | grep -v "vg" | tr '\n' ' '  | sed 's#  #\n\n#g'
                    } >> "$DOWNLOAD_DIR/debug_$DATE/$DSM/space.xml"
                done

                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/space/space_history_"*.xml
                do
                    [[ -e "$file" ]] || break #no space-files
                    {
                    echo "$file"
                    cat "$file"
                    CountHDDs1=$(awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' "$file" | grep -v "vg" | grep -v "volume" | tr '\n' ' '  | sed 's#  #\n\n#g' | wc -w)
                    CountHDDs2="$(($CountHDDs1-1))"
                    echo -e "#HDDs: $CountHDDs2"
                    awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' "$file" | grep -v "vg" | grep -v "volume" | tr '\n' ' '  | sed 's#  #\n\n#g'
                    #cat "$file" | awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' - | grep -v "vg" | tr '\n' ' '  | sed 's#  #\n\n#g'
                    echo -e "\n \n \n \n"
                    } >> "$DOWNLOAD_DIR/debug_$DATE/$DSM/space.xml"
                done

                SPACE_FILES="$DOWNLOAD_DIR/debug_$DATE/$DSM/space.xml"

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/disk_log.xml" ]] && [[ "$(stat --printf='%s' "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/disk_log.xml")" -gt 0 ]]
                then    DiskLog="$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/disk_log.xml"
                elif [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/disk.log" ]] && [[ "$(stat --printf='%s' "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/disk.log")" -gt 0 ]]
                then    DiskLog="$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/disk.log"
                fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/smartgrep" ]]
                then    SMART_GREP="$DOWNLOAD_DIR/debug_$DATE/$DSM/smartgrep"
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmidecode.result" ]]
                then
                    BIOS_V_CUT=$( grep -i "BIOS Information" -A5 "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmidecode.result" | grep -i "Version" | sed "s/.*Version: //" )
                        #DS_MEM=$( grep -A6 "Memory Device Mapped Address" $DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmidecode.result | grep "Range Size" | sed "s/.*Size: //" )
                        re='^[0-9]+$'
                        DS_MEM3=$(grep -A6 "Memory Device$" "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmidecode.result" | grep Size)
                        DS_MEM3_cut=$(grep -A6 "Memory Device$" "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmidecode.result" | grep Size | cut -d " " -f2 |  sed 's/[^0-9]*//g'| sed '/^\s*$/d' | sed ':a;N;$!ba;s/\n//g')
                            if [[ "$DS_MEM3_cut" =~ $re ]] ; then
                            #DS_MEM3_calc=$(grep -A6 "Memory Device$" "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmidecode.result" | grep Size | cut -d " " -f2 | sed 's/[^0-9]*//g' | sed '/^\s*$/d' | sed ':a;N;$!ba;s/\n/+/g' | bc | sed 's/$/\/1024/' | bc)
                            DS_MEM3_calc=$(cat "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmidecode.result" | sed -nr '/^Memory Device$/,/^$/ { /^\s*Size:\s*/ { s///; /No Module/! { s/ //; s/B//; p } } }' | numfmt --from=iec | awk '{ sum += $1 } END{ print sum }' | numfmt --to=iec | sed -r 's/([A-Z])/ \1B/')
                            DS_MEM3_calc_byte=$(cat "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmidecode.result" | sed -nr '/^Memory Device$/,/^$/ { /^\s*Size:\s*/ { s///; /No Module/! { s/ //; s/B//; p } } }' | numfmt --from=iec | awk '{ sum += $1 } END{ print sum }')
                            else
                                DS_MEM3_calc="Error calculating RAM-Size"
                                DS_MEM3_calc_byte="Error"
                                log "Error calculating RAM-Size"
                            fi
                    else
                        DS_MEM3="dmidecode not found, cannot calculate RAM-Size"
                        BIOS_V_CUT="Version not detected."
                        log "dmidecode.result not found!"

                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmesg.result" ]]
                then    Dmesg=$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmesg.result
                        #DS_MEM2=$( grep -i -m1 "Memory: " $Dmesg | sed "s/.*Memory: //" | cut -d " " -f3 )
                        Syno_bios=$( tac "$Dmesg" | grep "synobios: load" -m1 | sed 's/.*load, //' )
                else    log "dmesg.result not found!"
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/free.result" ]]
                then
                        free_mem=$( grep Mem "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print $2 0 0 0 }' )
                        free_mem_nocomma=$( grep Mem "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print 1000+$2 }' | awk '{ split( "KB MB GB" , v ); s=1; while( $1>1000 ){ $1/=1000; s++ } print int($1) v[s] }' | sed -r 's/B//' )
                        free_mem_kbyte=$( grep Mem "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print $2 }')
                        swap_total_kbyte=$( grep Swap "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print $2 }')
                        swap_total=$( grep Swap "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print $2 0 0 0 }' )
                        swap_used_kbyte=$( grep Swap "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print $3 }')
                        swap_used=$( grep Swap "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print $3 0 0 0 }' )
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/route.result" ]]
                then    Route="$DOWNLOAD_DIR/debug_$DATE/$DSM/result/route.result"
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/kern.log" ]]
                then    KERN=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/kern.log
                    DS_HWMODEL=$( grep -ia -m1 'syno_hw_version' "$KERN" | sed 's/.*syno_hw_version=//' | cut -d " " -f1 | sed 's/v.*$//' | sed 's/p\b/+/g') #i.e. DS213j
                    DS_MODEL=$( grep -ia -m1 '] Model:' "$KERN" | sed 's/.*: //' | sed 's/-//g' | sed 's/-//p') #i.e. DS213j
                    if [ -z "$DS_HWMODEL" ]; then
                            log "No DS_Model found, using UPNP-Name."
                            DS_MODEL_v="${UpnpModel}"
                            DS_MODEL_unter="${DS_MODEL_v}_"
                            DS_MODEL_plus="${DS_MODEL_unter//+/%2B}"
                            else DS_HWMODEL_v="${DS_HWMODEL}"
                                DS_MODEL_unter="${DS_HWMODEL_v}_"
                                DS_MODEL_plus="${DS_MODEL_unter//+/%2B}"
                    fi
                    DS_CPU=$( grep -m1 "model name\|Hardware" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/proc/cpuinfo )
                    DS_Cores=$( cat "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/proc/sys/kernel/syno_CPU_info_core )
                    Processor_count=$( grep -i -c "processor" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/proc/cpuinfo ) #CPU Count
                    DS_SN=$( cat "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/proc/sys/kernel/syno_serial )
                    Kernel_version=$( grep -m1 "Linux version" $KERN | awk -F 'Linux version ' '{print $2}')
                    #DS_SN=$( grep -i -m1 "serial number" $DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/kern.log | sed "s/.*[Ss]erial [Nn]umber//" )
                fi
                date_now=$(date +"%d. %B %H:%M:%S:")
                echo "$date_now $UpnpModel, S/N: $DS_SN" #write to sm after this

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages.log" ]]
                then
                    echo -ne "\nMemory Tests: " >> "$sm"
                    Passed_Memtest=$( grep -a "Memtest passed" "$MESSAGES" | sort -u | grep -c "")
                    Failed_Memtest=$( grep -a "Memtest failed" "$MESSAGES" | sort -u | grep -c "")
                    if [ "$Passed_Memtest" -gt 0 ]; then
                        echo "$Passed_Memtest" "Memory tests have passed." >> "$sm"
                        grep -a "Memtest passed" "$MESSAGES" | sort -u >> "$sm"
                    fi
                    if [ "$Failed_Memtest" -gt 0 ]; then
                        echo "Found $Failed_Memtest failed Memtests:" >> "$sm"
                        grep -a "Memtest failed" "$MESSAGES" | sort -u >> "$sm"
                    fi
                    if [[ "$Passed_Memtest" -eq 0 ]] && [[ "$Failed_Memtest" -eq 0 ]]; then #MEMTESTS
                        echo "No Memory tests have been run." >> "$sm"
                    fi
                    DSM_VERSION=$( cat "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc.defaults/VERSION" | grep "productversion" ) #DSM Version
                    DSM_BuildVERSION=$( cat "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc.defaults/VERSION" | grep "buildnumber" )
                    DSM_smallfixVERSION=$( cat "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc.defaults/VERSION" | grep "smallfixnumber" )
                fi

                    #Hardware-specific things
                if [ "$UpnpModel" = "DS216+" ]; then
                    echo -e "\nPossible Known Issue: BIOS: https://cssnew.synology.com/issue/4334" >> "$sm"
                    echo "Bugged Versions are less than M.616" >> "$sm"
                    echo -e "This Machines BIOS-Version: $BIOS_V_CUT" >> "$sm"
                fi
                if [ "$UpnpModel" = "DS718+" ]; then
                    grep_cputemp=$( grep -c "<cpu_temperature> is over" "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/scemd.log" )
                    if [ "$grep_cputemp" -gt 0 ]; then
                    echo -e "\nCPU is overheating, RMA unit: https://cssnew.synology.com/issue/11124" >> "$sm"
                    grep -i "<cpu_temperature> is over" "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/scemd.log" >> "$sm"
                    fi
                fi
                    grep_hddissue=$( grep -c "core_clear_root_int_from_queue Error Interrupt\|Issued IDENTIFY to non-existent device ?!" "$MESSAGES" )
                    if [ "$grep_hddissue" -gt 0 ]; then
                        echo -e "\nKnown Issue: random HDD drops of WD or HGST HDDs, update HDD Firmware: https://cssnew.synology.com/issue/9198" >> "$sm"
                        grep -i "core_clear_root_int_from_queue Error Interrupt: PHY Decoding Error\|Issued IDENTIFY to non-existent device ?!" "$MESSAGES" >> "$sm"
                    fi

                        version_compare_gt() {
                            ! printf "%s\n" "$@" | sort --check --version-sort &> /dev/null
                        }

                if [ "$UpnpModel" = "DS918+" ]; then
                    if version_compare_gt "M.024" "$BIOS_V_CUT"; then
                        {
                            echo -e "\nKnown Issue: BIOS: https://cssnew.synology.com/issue/12026"
                            echo "Update to DSM 6.1.3-15152 Update 7 to update the BIOS."
                            echo -e "This Machines BIOS-Version: $UpnpModel $BIOS_V_CUT"
                        } >> "$sm"
                    else
                            log "installed BIOS bigger than M.024"
                    fi
                fi

                if [ "$UpnpModel" = "DS718+" ]; then
                    if version_compare_gt "M.220" "$BIOS_V_CUT"; then
                        {
                            echo -e "\nKnown Issue: BIOS: https://cssnew.synology.com/issue/12026"
                            echo "Update to DSM 6.1.3-15152 Update 7 to update the BIOS."
                            echo -e "This Machines BIOS-Version: $UpnpModel $BIOS_V_CUT"
                        } >> "$sm"
                    else
                            log "installed BIOS bigger than M.220"
                    fi
                fi

                if [ "$UpnpModel" = "DS218+" ]; then
                    if version_compare_gt "M.124" "$BIOS_V_CUT"; then
                        {
                            echo -e "\nKnown Issue: BIOS: https://cssnew.synology.com/issue/12026"
                            echo "Update to DSM 6.1.3-15152 Update 7 to update the BIOS."
                            echo -e "This Machines BIOS-Version: $UpnpModel $BIOS_V_CUT"
                        } >> "$sm"
                    else
                            log "installed BIOS bigger than M.124"
                    fi
                fi

                if [ "$UpnpModel" = "DS418play" ]; then
                    if version_compare_gt "M.310" "$BIOS_V_CUT"; then
                        {
                            echo -e "\nKnown Issue: BIOS: https://cssnew.synology.com/issue/12026"
                            echo "Update to DSM 6.1.3-15152 Update 7 to update the BIOS."
                            echo -e "This Machines BIOS-Version: $UpnpModel $BIOS_V_CUT"
                        } >> "$sm"
                    else
                            log "installed BIOS bigger than M.310"
                    fi
                fi

                if grep -ia "tn40xx" "$KERN" | grep memory &> /dev/null ; then
                echo -e "\nKnown Issue: with 10GbE E10G15-F1 Card detected." >> "$sm"
                echo "See https://cssnew.synology.com/issue/5206 Issue B" >> "$sm"
                grep -ia "tn40xx" "$KERN" | grep memory | tail -n20 >> "$sm"
                fi

                if grep -ia "tn40xx" "$KERN" | grep Link Up 10G &> /dev/null ; then
                {
                echo -e "\nPossible Known Issue: with 10GbE E10G15-F1 Card detected."
                echo "If Time are above 600s after Boot, please check SOP."
                echo "See https://cssnew.synology.com/issue/5206 Issue A"
                grep -ia "tn40xx" "$KERN" | grep "Link Up 10G\|Link Down" | tail -n20
                } >> "$sm"
                fi

                #https://cssnew.synology.com/issue/13942
                if [ "$UpnpModel" = "DS218j" ] || [ "$UpnpModel" = "RS217" ] || [ "$UpnpModel" = "RS816" ] || [ "$UpnpModel" = "DS416j" ] || [ "$UpnpModel" = "DS416slim" ] || [ "$UpnpModel" = "DS216" ] || [ "$UpnpModel" = "DS216j" ] || [ "$UpnpModel" = "DS116" ]; then
                    grep_Issue_13942=$( grep -ca "Linux processing - Can't refill, try to allocate again in cleanup timer" "$MESSAGES" )
                    if [ "$grep_Issue_13942" -gt 0 ]; then
                    {
                        echo -e "\nKnown Issue: https://cssnew.synology.com/issue/13942"
                        echo "[Cause] The marvell model may suffer from memory allocating issue."
                        echo "[Workaround]Add the following command to a bootup task:"
                        echo "/sbin/sysctl -w vm.min_free_kbytes=16384"
                    } >> "$sm"
                    fi
                fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/scemd.log" ]]
                then
                    grep_disktemp=$( grep -c "temperature> is over" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/var/log/scemd.log )
                        if [ "$grep_disktemp" -gt 0 ]; then
                        echo -e "\nCPU or Disk is overheating:" >> "$sm"
                        grep -ia "temperature> is over" "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/scemd.log" >> "$sm"
                        fi
                fi

                if grep -wi "$UpnpModel" "$srsde" &> /dev/null ; then
                    echo -e "\nNAS can be SRSed in DE! ( enabled )" >> "$sm"
                else
                    echo -e "\nno DE-SRS possible. ( disabled )" >> "$sm"
                fi
                if [ "$ipv6_enabled" -gt 0 ]; then
                    echo "IPv6 enabled" >> "$sm"
                    echo "IPv6 on NAS is on." >> "$hb_debug"
                else echo "IPv6 disabled" >> "$sm"
                     echo "IPv6 on NAS is off." >> "$hb_debug"
                fi
                echo "found ${ifc_dropped_sum} dropped Packages in ifconfig.result." >> "$sm"
                echo "found ${ifc_error_sum} bugged Packages in ifconfig.result." >> "$sm"
                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/ethtool.eth"*.result
                do
                    [[ -e "$file" ]] || break  # handle the case of no *.result files
                    ethresult=$(grep "Speed" -H "$file")
                    echo "${ethresult#$DOWNLOAD_DIR/debug_$DATE/$DSM/result/}" >> "$sm"
                done
                echo "DNS Servers:" >> "$sm"
                if [ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/resolv.conf" ]; then
                cat "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/resolv.conf" | sed ':a;N;$!ba;s/\n/, /g' >> "$sm"
                    else echo "/etc/resolv.conf not found." >> "$sm"
                fi
                cat "$Route" >> "$IFCONFIG"
                #echo -e "\n" >> "$sm"
                smb_enabled_disabled1=$(grep "auto_start" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/usr/syno/etc/synoservice.override/samba.cfg 2>/dev/null | cut -d ":" -f2 )
                smb_enabled_disabled2="${smb_enabled_disabled1%\"}"
                smb_enabled_disabled3="${smb_enabled_disabled2#\"}"
                if [ "$smb_enabled_disabled3" == "yes" ]
                    then echo -ne "Samba is on. \t" >> "$sm"
                elif [ "$smb_enabled_disabled3" == "no" ]
                    then echo -ne "Samba is off.\t" >> "$sm"
                else
                         echo -ne "Samba: Error \t" >> "$sm"
                fi
                nfs_enabled_disabled1=$(grep "auto_start" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/usr/syno/etc/synoservice.override/nfsd.cfg 2>/dev/null | cut -d ":" -f2 )
                nfs_enabled_disabled2="${nfs_enabled_disabled1%\"}"
                nfs_enabled_disabled3="${nfs_enabled_disabled2#\"}"
                if [ "$nfs_enabled_disabled3" == "yes" ]
                    then echo -ne "NFS is on.   \t" >> "$sm"
                elif [ "$nfs_enabled_disabled3" == "no" ]
                    then echo -ne "NFS is off.  \t" >> "$sm"
                else
                         echo -ne "NFS: Error   \t" >> "$sm"
                fi
                afp_enabled_disabled1=$(grep "auto_start" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/usr/syno/etc/synoservice.override/atalk.cfg 2>/dev/null | cut -d ":" -f2 )
                afp_enabled_disabled2="${afp_enabled_disabled1%\"}"
                afp_enabled_disabled3="${afp_enabled_disabled2#\"}"
                if [ "$afp_enabled_disabled3" == "yes" ]
                    then echo "AFP is on.      " >> "$sm"
                elif [ "$afp_enabled_disabled3" == "no" ]
                    then echo "AFP is off.     " >> "$sm"
                else
                         echo "AFP: Error   " >> "$sm"
                fi

                DS_upnp_v="${UpnpModel}"
                DS_upnp_unter="${DS_upnp_v}_"
                DS_upnp_plus="${DS_upnp_unter//+/%2B}"

                LatestBuildNumber=$( grep -i "$DS_upnp_plus" "$rss" | sed -e 's/<[^>]*>//g' | head -n 1 | cut -d "_" -f3 | cut -d "." -f1 ) #_plus
                DSMBuildNumber=$( grep buildnumber "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/etc.defaults/VERSION | cut -d "\"" -f2 )
                if [ "$LatestBuildNumber" -gt "$DSMBuildNumber" ]; then
                    {
                    echo "More current DSM Version available."
                    echo "available Updates (grep ""$DS_MODEL_plus"") :"
                    grep -i "$DS_MODEL_plus" "$rss" | sed -e 's/<[^>]*>//g'
                    } >> "$sm"
                else echo "DSM Version is latest!" >> "$sm"
                fi
                {
                echo "installed VERSION: " "$DSM_VERSION, $DSM_BuildVERSION, $DSM_smallfixVERSION"

                DS_MEM_TXT=$( grep "${UpnpModel}[[:space:]]" "$CPU_FILE" | rev | cut -d ' ' -f1,2 |rev ) #todo: if realRAM > preinstalled then echo
                DS_MEM_TXT_byte=$( grep "${UpnpModel}[[:space:]]" "$CPU_FILE" | rev | cut -d ' ' -f1,2 |rev | tr -d ' B' | numfmt --from=iec)
                DS_MEM_TXT_kbyte=$( grep "${UpnpModel}[[:space:]]" "$CPU_FILE" | rev | cut -d ' ' -f1,2 |rev | tr -d ' B' | numfmt --from=iec | awk '{ number = $1 / 1024; print number }' )
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmidecode.result" ]]
                then
                    if [ "$DS_MEM3_calc_byte" -gt "$DS_MEM_TXT_byte" ];
                    then
                        echo "More RAM installed! $DS_MEM3_calc vs $DS_MEM_TXT preinstalled" >> "$sm"
                    elif [ "$free_mem_kbyte" -gt "$DS_MEM_TXT_kbyte" ];
                    then
                        echo "More RAM installed! $free_mem_nocomma vs $DS_MEM_TXT preinstalled" >> "$sm"
                    elif [ "$DS_MEM3_calc_byte" -eq "$DS_MEM_TXT_byte" ];
                    then
                        echo "same RAM installed as preinstalled!"  >> "$sm"
                    elif [ "$free_mem_kbyte" -eq "$DS_MEM_TXT_kbyte" ];
                    then
                        echo "same RAM installed as preinstalled!"  >> "$sm"
                    else
                        echo "error comparing RAM-Size"  >> "$sm"
                    fi
                fi

                echo "Uptime: " "$UPTIME"
                echo "Hostname: " "$Hostname"
                echo "$QuickConnect_echo"
                }  >> "$sm"
                if [ "$ddns" = 1 ]; then
                    echo -n "DDNS " >> "$sm"
                        grep "hostname" "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/ddns.conf" >> "$sm"
                fi
                {
                echo "BIOS:" "$BIOS_V_CUT"
                #echo "SynoBIOS: " "$Syno_bios"
                echo "Hardware Version: $DS_HWMODEL and Diskstationmodel: $DS_MODEL"
                echo "UPNP Model:" "$UpnpModel"
                echo "Kernel:" "$Kernel_version"
                echo -n "CPU from logs:" "$DS_CPU"
                echo "; Threads: $Processor_count , Cores: $DS_Cores"
                echo "Serialnumber:" "$DS_SN"
                echo -e 'Associated Tickets: \thttps://cssnew.synology.com/ticket?list_type=agent_all&sort_by=update_time&sort_direction=desc&filter=%7B%22search_column%22%3A%5B%22ticket_id%22%2C%22content%22%5D%2C%22sn%22%3A%22'"$DS_SN"'%22%7D'

                swap_percent_kb=$(awk "BEGIN {printf \"%.2f\n\", $swap_used_kbyte/$swap_total_kbyte*100}")
                echo -ne "\nSwap: ($swap_percent_kb%) used " >> "$sm"
                bytesToHuman "$swap_used" >> "$sm"
                echo -ne " of " >> "$sm"
                bytesToHuman "$swap_total" >> "$sm"
                echo -ne "Swap: ($swap_percent_kb%) used ">> "$hb_debug"
                bytesToHuman "$swap_used" >> "$hb_debug"
                echo -ne " of " >> "$hb_debug"
                bytesToHuman "$swap_total" >> "$hb_debug"

                if [[ -z "$DS_MEM3" ]]; then
                    log "$DS_MEM3 is empty."
                else
                    echo -e "\nInstalled RAM-modules:\n$DS_MEM3"
                fi
                if [[ -z "$DS_MEM3_calc" ]]; then
                    log "$DS_MEM3_calc is empty."
                else
                    echo -e "RAM, calced: $DS_MEM3_calc"
                fi
                echo -n "RAM free.result: "
                bytesToHuman "$free_mem"
                echo -e " "
                } >> "$sm"

                #log "$DS_MEM3_calc"
                date_now=$(date +"%d. %B %H:%M:%S: ")
                echo -e $date_now 'Associated Tickets: \nhttps://cssnew.synology.com/ticket?list_type=agent_all&sort_by=update_time&sort_direction=desc&filter=%7B%22search_column%22%3A%5B%22ticket_id%22%2C%22content%22%5D%2C%22sn%22%3A%22'"$DS_SN"'%22%7D'

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/samba/smb.share.conf" ]]
                then    SmbShares=$(grep "path=" "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/samba/smb.share.conf" | tr '\n' '\t')
                            if [[ -z "$SmbShares" ]]; then
                                echo -e "No Samba Shares found.\n" >> "$sm"
                            else
                                echo -e "Found Samba-shares:\n$SmbShares\n" >> "$sm"
                            fi
                fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/usr/syno/etc/iscsi_lun.conf" ]]
                then    LUNs="$DOWNLOAD_DIR/debug_$DATE/$DSM/usr/syno/etc/iscsi_lun.conf"
                            if [[ -z "$LUNs" ]]; then
                                echo -e "\nNo LUN-Config found." >> "$sm"
                            elif [[ $(stat -c%s "$LUNs") -lt 1 ]]; then
                                echo -e "\nLUN-Config-file is empty." >> "$sm"
                            else
                                echo -e "\nFound LUNs:" >> "$sm"
                                cat "$LUNs" >> "$sm"
                                LUNSize_byte="$(grep "bytes=" $LUNs | cut -d "=" -f2 | sed ':a;N;$!ba;s/\n/+/g' | bc)"
                                echo -en "Combined LUN Size: " >> "$sm"
                                bytesToHuman "$LUNSize_byte" >> "$sm"
                                echo -e "\n" >> "$sm"
                            fi
                fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/packages.list" ]]
                then    PACK=$DOWNLOAD_DIR/debug_$DATE/$DSM/packages.list
                        declare -a InstalledPackageArray
                        sed '1d' "${PACK}" | awk '{for(i=NF;i>1;i=i-1) printf "%s ", $i; printf "%s\n", $1}' | cut -d " " -f1 > "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/packages_ver.list

                        synopkgfile="$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/var/log/synopkg.log
                        if [[ $(stat -c%s "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/synopkg.log") -lt 1 ]]; then #if synopkg.log is empty
                            unxz "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/synopkg.log.1.xz"
                            if [ $? -eq 0 ]; then # if successfully extracted
                                synopkgfile="$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/var/log/synopkg.log.1
                            fi
                        fi

                        readarray -t "InstalledPackageArray" < "$DOWNLOAD_DIR/debug_$DATE/$DSM/packages_ver.list"
                        counter=0
                        for i in "${InstalledPackageArray[@]}"
                        do
                            aver=$(grep "^$i " "$package_versions")
                            PureVerAvailable=$(echo "${aver}" | rev | cut -d " " -f1 | rev | sed 's/\-/./g')
                            PureVerInstalled=$(grep -a "$i " "$synopkgfile" | tail -n1 | grep -aoP '(?<='$i' )\S*' | sed 's/\-/./g')
                            log "${InstalledPackageArray[$counter]}: Installed: $PureVerInstalled vs. available: $PureVerAvailable"

                            # "gt" means "greater than"
                            version_compare_gt() {
                                ! printf "%s\n" "$@" | sort --check --version-sort &> /dev/null
                            }

                            if version_compare_gt "$PureVerAvailable" "$PureVerInstalled"; then
                                log "\e[31mUpdate for ${InstalledPackageArray[$counter]} from $PureVerInstalled to $PureVerAvailable available!\e[0m"
                                echo "Update for ${InstalledPackageArray[$counter]} from $PureVerInstalled to $PureVerAvailable available!" >> "$sm"
                            elif version_compare_gt "$PureVerInstalled" "$PureVerAvailable"; then
                                if [[ -z "$PureVerAvailable" ]]; then
                                    log "\e[93mNo latest Version found.\e[0m"
                                else
                                    log "\e[93minstalled Version later than available?!\e[0m"
                                fi
                            elif [[ "$PureVerInstalled" == "$PureVerAvailable" ]] ; then
                                log "\e[32msame Version, package is up to date!\e[0m"
                            else
                                echo -ne "\e[101msome error occured: "
                                echo -e "${InstalledPackageArray[$counter]}: Installed: $PureVerInstalled vs. available: $PureVerAvailable\e[0m"
                            fi

                            #counter=$((counter + 1))
                            counter=`expr $counter + 1`
                        done
                        if [[ $counter -gt 0 ]]; then
                            echo -e "\n" >> "$sm"
                        fi
                        echo -en "Third Party packages:" >> "$sm"
                        third_packages=$(grep -v "AntiVirus\|AudioStation\|Calendar\|CloudStation\|FileStation\|HyperBackup\|LogCenter\|MediaServer\|NoteStation\|PHP[0-9].[0-9]\|PhotoStation\|ProxyServer\|StorageAnalyzer\|SynoFinder\|SynologyApplicationService\|SynologyDrive\|TextEditor\|USBCopy\|VideoStation\|WebDAVServer\|CloudSync\|DownloadStation\|SurveillanceStation\|WebStation\|VPNCenter\|MariaDB\|Chat\|Git\|Node.js_4\|Perl\|ActiveBackup\|ActiveBackup-Office365\|ActiveDirectoryServer\|Apache[0-9].[0-9]\|CMS\|CardDAVServer\|DNSServer\|DiagnosisTool\|Docker\|MailClient\|MailPlus-Server\|OAuthService\|PetaSpace\|PrestoServer\|PythonModule\|SSOServer\|SnapshotReplication\|Spreadsheet\|SynologyMoments\|Virtualization\|iTunesServer\| enabled\|TimeBackup\|Java7\|Java8\|exFAT\|PDFViewer\|DocumentViewer\|MailServer\|MailStation\|phpMyAdmin\|total [[:digit:]]\{,3\}" "$PACK")
                        if [ -z "$third_packages" ]; then
                            echo -e "\tnone" >> "$sm"
                        else
                            echo -e "\n$third_packages\n" >> "$sm"
                        fi
                fi

                btrfserrkern=$(grep -ia "btrfs critical\|btrfs error\|btrfs warning\|btrfs.*failure\|btrfs.*failed\|BTRFS: superblock checksum mismatch" "$KERN")
                ext4errkern=$(grep -ia "ext-3\|ext-4" "$KERN" | grep -v "scripts/ext-3.4")
                btrfserrmsg=$(grep -ia "btrfs critical\|btrfs error\|btrfs warning\|btrfs.*failure\|btrfs.*failed\|BTRFS: superblock checksum mismatch" "$MESSAGES")
                ext4errmsg=$(grep -ia "ext-3\|ext-4" "$MESSAGES" | grep -v "scripts/ext-3.4" )
                if [[ -z "$btrfserrkern" ]] && [[ -z "$ext4errkern" ]] && [[ -z "$ext4errmsg" ]] && [[ -z "$ext4errmsg" ]]; then
                    echo -e "Ext4-/Btrfs-Errs:\t\tnone" >> "$sm"
                else
                    echo -e "\nExt4-/Btrfs-Errors:" >> "$sm"
                    if [[ -n "$btrfserrkern" ]]; then
                        echo -e "$btrfserrkern \n" >> "$sm"

                    fi
                    if [[ -n "$ext4errkern" ]]; then
                        echo -e "$ext4errkern \n" >> "$sm"
                    fi
                    if [[ -n "$btrfserrmsg" ]]; then
                        echo -e "$btrfserrmsg \n" >> "$sm"
                    fi
                    if [[ -n "$ext4errmsg" ]]; then
                        echo -e "$ext4errmsg \n" >> "$sm"
                    fi
                fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/synolog/synosys.log" ]]; then
                    SYSDB="$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/synolog/synosys.log"
                elif [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/synolog/.SYNOSYSDB" ]]; then
                    sqlite3 "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/synolog/.SYNOSYSDB" "select id, datetime(time,'unixepoch','localtime'), username, msg from logs;" >> "$DOWNLOAD_DIR/debug_$DATE/$DSM/SYSDB.log"
                    SYSDB="$DOWNLOAD_DIR/debug_$DATE/$DSM/SYSDB.log"
                    else
                        log "No SYSDB found."
                fi


                    tac "$SYSDB" >> "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/synolog/synosystac.log"
                    SYSDBtac="$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/synolog/synosystac.log"

                    impropershutdown=$(grep -ia "improper shutdown" "$SYSDB")
                    if [[ -z "$impropershutdown" ]]; then
                        echo -e "improper shutdowns:\t\tnone" >> "$sm"
                    else
                        echo -e "improper shutdowns:" >> "$sm"
                        echo "$impropershutdown" >> "$sm"
                        echo -e "\n" >> "$sm"
                    fi

                    volumecrash=$(grep -ia "was crashed" "$SYSDB") #volumecrash
                    if [[ -z "$volumecrash" ]]; then
                        echo -e "Volume crashes:\t\t\tnone" >> "$sm"
                    else
                        echo -e "Volume crashes:" >> "$sm"
                        echo "$volumecrash" >> "$sm"
                        echo -e "\n" >> "$sm"
                    fi

                    degradedvolume=$(grep -ia "degrade" "$SYSDB") #volumecrash
                    if [[ -z "$degradedvolume" ]]; then
                        echo -e "degraded volumes:\t\tnone" >> "$sm"
                    else
                        echo -e "degraded volumes:" >> "$sm"
                        echo "$degradedvolume" >> "$sm"
                        echo -e "\n" >> "$sm"
                    fi

                    generrors=$(grep -ia "error" "$SYSDB" | uniq -u | wc -l) #volumecrash
                    if [[ "$generrors" -eq 0 ]]; then
                        echo -e "generic errs:\t\t\tnone" >> "$sm"
                    else
                        echo -e "$(grep -ia "error" "$SYSDB" | uniq -u | wc -l) times errors:" >> "$sm"
                        echo "$(grep -ia "error" "$SYSDB" | uniq -u)" >> "$sm"
                        echo -e "\n" >> "$sm"
                    fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages.log" ]]; then
                    {
                        DRDYErr=$(grep -ia "DRDY" "$MESSAGES" | uniq -u | wc -l)
                        if [[ "$DRDYErr" -eq 0 ]]; then
                            echo -e "DRDY:\t\t\t\t\tnone"
                        else
                            echo -e "$(grep -ia "DRDY" "$MESSAGES" | uniq -u | wc -l) times DRDY, showing 20 max:"
                            tac "$MESSAGES" | grep -ia -B5 -A10 -m 20 "DRDY" | tac
                            echo -e "\n"
                        fi

                        database_malformed=$(grep -iac "database disk image is malformed" "$MESSAGES")
                        if [[ "$database_malformed" -eq 0 ]]; then
                            echo -e "Database is malformed:\tnone"
                        else
                            echo -e "$(grep -iac "database disk image is malformed" "$MESSAGES") times malformed database:"
                            grep -ia "database disk image is malformed" "$MESSAGES"
                            echo -e "\n"
                        fi

                        crashes=$(grep -iac "crash" "$MESSAGES")
                        if [[ "$crashes" -eq 0 ]]; then
                            echo -e "generic crashes:\t\tnone"
                        else
                            echo -e "$(grep -iac "crash" "$MESSAGES") times generic crashes:"
                            grep -ia "crash" "$MESSAGES"
                            echo -e "\n"
                        fi

                        CallTraces=$(grep -iac "Call Trace" "$MESSAGES")
                        if [[ "$CallTraces" -eq 0 ]]; then
                            echo -e "Call Traces:\t\t\tnone"
                        else
                            echo -e "$(grep -iac "Call Trace" "$MESSAGES") times call traces + next 25 lines:"
                            #grep -ia "Call Trace" "$MESSAGES" -A25
                            grep -ia "Call Trace" "$MESSAGES" | while read l; do
                              # Get seconds-since-startup timestamp from Call Trace line
                              if [[ $l =~ kernel:\ \[\ *([0-9]+)\.[0-9]+\] ]]; then
                                tsecs="${BASH_REMATCH[1]}"
                                # Grep again for anything +/- 1 sec from that timestamp
                                grep -aE "kernel: \[($((tsecs-2))|$((tsecs-1))|${tsecs}|$((tsecs+1))|$((tsecs+2)))\.[0-9]+\]" "$MESSAGES"
                                echo -e "\n"
                              fi
                            done
                        fi
                    } >> "$sm"
                fi
                #write hibernation info:
                satadeepsleep=$(grep -c "satadeepsleeptimer=\"1\"" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/etc/synoinfo.conf)
                if [ "$satadeepsleep" -gt 0 ]
                        then echo -e "\nHibernation on NAS is on." >> "$hb_debug"
                        else echo -e "\nHibernation on NAS is off." >> "$hb_debug"
                fi

                fan_debug_mode=$(grep "enable_fan_debug" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/etc/synoinfo.conf)
                if [ "$?" -gt 0 ]
                    then echo "Fan debug mode on NAS is off." >> "$hb_debug"
                else
                    fan_debug_mode=$(grep "enable_fan_debug" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/etc/synoinfo.conf | cut -d "\"" -f2)
                    fan_debug_mode_dec=$(($fan_debug_mode))
                    if [ "$fan_debug_mode_dec" -gt 0 ]
                            then echo "Fan debug mode on NAS is on." >> "$hb_debug"
                    elif [ "$fan_debug_mode_dec" -eq 0 ]
                            then echo "Fan debug mode on NAS is off." >> "$hb_debug"
                    else
                        echo "Fan debug mode: Error" >> "$hb_debug"
                    fi
                fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf" ]]; then
                kernel_log_max=$(grep -c "kern_log_max=\"yes\"" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/etc/synoinfo.conf)
                    if [ "$kernel_log_max" -gt 0 ]
                            then echo "Extended kernel logging on NAS is on." >> "$hb_debug"
                            else echo "Extended kernel logging on NAS is off." >> "$hb_debug"
                    fi
                fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf" ]]; then
                sys_stat_dump=$(grep "sys_stat_dump" "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf" | cut -d "=" -f2)
                    if [ "$sys_stat_dump" == "yes" ]
                            then echo "Log system status periodically on NAS is on." >> "$hb_debug"
                    elif [ "$sys_stat_dump" == "no" ]
                            then echo "Log system status periodically on NAS is off." >> "$hb_debug"
                    else
                        echo "Log system status periodically: Error" >> "$hb_debug"
                    fi
                else
                    log "smb.conf not found."
                fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/samba/smb.conf" ]]; then
                local_master=$(grep "local master" "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/samba/smb.conf" | cut -d "=" -f2)
                    if [ "$local_master" == "yes" ]
                            then echo "Local Master Browser on NAS is on." >> "$hb_debug"
                    elif [ "$local_master" == "no" ]
                            then echo "Local Master Browser on NAS is off." >> "$hb_debug"
                    else
                        echo "Local Master Browser: Error" >> "$hb_debug"
                    fi
                else
                    log "smb.conf not found."
                fi
                #echo -e "\n" >> "$hb_debug"

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf" ]]; then
                    supportrcpower=$(grep -ia "supportrcpower" "$Synoinfo" | cut -d "\"" -f2)
                    if [[ "$supportrcpower" == "yes" ]];then
                        echo "supportrcpower on NAS is on." >> "$hb_debug"
                    elif [[ "$supportrcpower" == "no" ]];then
                        echo "supportrcpower on NAS is off." >> "$hb_debug"
                    else
                        log "supportrcpower not yes or no."
                    fi
                    enablercpower=$(grep -ia "enableRCPower" "$Synoinfo" | cut -d "\"" -f2)
                    if [[ "$enablercpower" == "yes" ]];then
                        echo "enablercpower on NAS is on." >> "$hb_debug"
                    elif [[ "$enablercpower" == "no" ]];then
                        echo "enablercpower on NAS is off." >> "$hb_debug"
                    else
                        log "enablercpower not yes or no."
                    fi
                fi

                grep "^standbytimer" "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf" >> "$hb_debug"

                echo -n "Packages interfering with Hibernation:" >> "$hb_debug"
                        hb_packages=$(grep "ActiveDirectoryServer\|AudioStation\|CloudStation\|MediaServer\|SynologyDrive\|CloudSync\|DownloadStation\|SurveillanceStation\|CMS\|Docker\|MailClient\|MailPlus\|MailPlus-Server\|PetaSpace\|Virtualization\|PDFViewer\|MailStation" "$PACK")
                        #to add: DocumentViewer?, CloudStation Server, CS ShareSync, CMS, DirectoryServer, MailServer?, Plex Media Server, Drittanbieterpakete
                        #to add: AudioStation protokollierung, Directory server
                        #DownloadStation: emule, Docker-Discourse, Docker-GitLab, Docker-LXQt, Docker-Redmine, Docker-Spree, Document Viewer
                        #Drittanbieterpakete, Asterisk, Bittorrent sync, Cloud Fleet, DVBLink-Server, Egnyte, ElephantDrive, Logitech® Medienserver, minimserver, Odoo8, OpenERP6, OpenERP7, OracleDBXE, PACS, Polkast, Symform Cloud Backup, VirtualHere, Webalizer, Wonderbox, xCloud, Zarafa, Andere Drittanbieter-Software oder Optware, z. B. SABnzbd
                        #usb-geraet angeschlossen
                        if [ -z "$third_packages" ]; then
                            echo -e "\t\tnone." >> "$hb_debug"
                            else
                            echo -e "\n$hb_packages" >> "$hb_debug"
                        fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/power_sched.conf" ]]; then #call power_sched.py
                    echo -e "\n" >> "$hb_debug"
                    cat "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/power_sched.conf" >> "$hb_debug"
                    while read p; do
                        re='^[0-9]+$'
                        if [[ $p =~ $re ]] ; then
                           python "${PShedPy}" "$p" >> "$hb_debug";
                        fi
                        done < "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/power_sched.conf"
                    else
                     echo "power_sched.conf not found." >> "$hb_debug"
                fi


                counter=0
                allpics=$(find "$DOWNLOAD_DIR/debug_${DATE}/" -maxdepth 1 -type f \( -name "*.jpg" -o -name "*.png" -o -name "*.PNG" -o -name "*.JPG" \) 2>/dev/null)
                declare -a PicArray
                for pic in "${allpics}"
                do  PicArray["${counter}"]="${pic}"
                    counter=`expr $counter + 1`
                    #counter=$((counter + 1))
                done

                sleep 0.1
            TIMEFORMAT=$'\nOpening Sublime took: \t\t\t\t\t\t\t\t\e[36m%Rsec\e[39m'
            time(
                source "${Script_dir}/files/config.sh" #load OpenFiles[] Array from config.sh
                #log "Array before unsetting: ${OpenFiles[@]}"
                for i in "${!OpenFiles[@]}"; do #remove empty vars from array [@]
                    [ -n "${OpenFiles[$i]}" ] || log "OpenFiles[$i] unset, because empty!"
                    [ -n "${OpenFiles[$i]}" ] || unset "OpenFiles[$i]"
                done
                for i in "${OpenFiles[@]}"; do # open single files
                    "$subl" "$i" #"$subl" "$(wslpath -w $i)"
                    sleep 0.12
                done
                #"$subl" "${OpenFiles[@]}" #open files defined in config.sh with editor

                echo -n "${subl} "
                echo -n "${subl} " > ~/Dokumente/bash/last_debug.sh
                for arg in "${OpenFiles[@]}"
                    do echo -n "\"$arg\" "
                       echo -n "\"$arg\" " >> ~/Dokumente/bash/last_debug.sh
                done
                #echo -e "\n" #??
                )
                TIMEFORMAT=$'Executiontime: \t\t\t\t\t\t\t\t\t\e[36m%Rsec\e[39m'
                #log "$subl" "${OpenFiles[@]}"
                #$subl "$DEBUG_DIR" "$SMART_GREP" "$PACK" "$Bash_history" "$hb_debug" "$HB" "$DF" "$IFCONFIG" "$SPACE_FILES":10000 "$SYSDBtac":100000 "$sm" "$MESSAGES":1000000 "${PicArray[@]}"
                #"${subl}" "$DEBUG_DIR" "$SMART_GREP" "$PACK" "$Bash_history" "$hb_debug" "$HB" "$DF" "$IFCONFIG" "$SPACE_FILES":10000 "$SYSDBtac":100000 "$sm" "$MESSAGES":1000000 "${PicArray[@]}" #$pics
                #echo "subl \"$DEBUG_DIR\" \"$SMART_GREP\" \"$PACK\" \"$Bash_history\" \"$hb_debug\" \"$HB\" \"$DF\" \"$IFCONFIG\" \"$SPACE_FILES:10000\" \"$SYSDBtac:100000\" \"$sm\" \"$MESSAGES:1000000\" \"${PicArray[@]}\""
                #echo "subl \"$DEBUG_DIR\" \"$SMART_GREP\" \"$PACK\" \"$Bash_history\" \"$hb_debug\" \"$HB\" \"$DF\" \"$IFCONFIG\" \"$SPACE_FILES:10000\" \"$SYSDBtac:100000\" \"$sm\" \"$MESSAGES:1000000\" \"${PicArray[@]}\"" > ~/last_debug.sh
                #echo "Array: ${OpenFiles[@]}"
                # for smart-files: ${SMART_FILES[@]}  $MDSTAT
            else
                mkdir -p "${DOWNLOAD_DIR}/kapott"
                mv "$file" "${DOWNLOAD_DIR}/kapott/debug_$DATE.dat"
                echo "$file" "konnte nicht entpackt werden."
                if [[ "$os" = "win" ]]; then
                    echo "" #maybe add things here
                elif [[ "$os" = "other" ]]; then
                    #statements
                    zenity --error --text="Debug konnte nicht entpackt werden\!" --title="Achtung!" 2> /dev/null
                fi
            fi
            DSM=dsm
            #sha=0
            )
            echo -ne "\n"
        fi
    done
    sleep $sleep_scan_dir
    #echo "$(date +"%H:%M:%S") Rescanning for .dat Files"
done
