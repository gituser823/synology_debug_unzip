#!/bin/bash

#for handling spaces in filenames
IFS=$'\n'

# set bash option to avoid
# unmatched patterns expand as result values
shopt -s nullglob

#win sub:sudo apt-get  install bc unzip (sqlite3) xmllint
#sudo apt install (sqlite3) zenity sublime-text xmllint lftp
#DOWNLOAD_DIR=/home/thomas/Downloads/neu

sleep_scan_time=3 #Folder rescan time
sleep_scan_dir="$sleep_scan_time"
sleep_extract_zip=0.5 #rescan time for finished download
Script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${Script_dir}/files/config.sh"
DSM=dsm
CPU_FILE="${Script_dir}/files/CPU.txt"
PShedPy="${Script_dir}/files/power_shed.py"
rss="${Script_dir}/files/genRSS.php"
srs="${Script_dir}/files/SRS.php"
available_packages_pre="${Script_dir}/files/available_packages_pre.txt"
available_packages="${Script_dir}/files/available_packages.txt"
package_versions="${Script_dir}/files/package_versions.txt"
mkdir -p "${Script_dir}/comp"
ProductList="${Script_dir}/comp/ProductList.txt"



while getopts ":uh" opt; do
  case $opt in
    u)
        echo "updating files:" >&2
        echo -e "\nDownloading latest genRSS.php:"
        curl "https://update.synology.com/autoupdate/genRSS.php" -# --output "$rss"
        echo $(stat --printf="Size: %s" "$rss")
        echo -e "\nDownloading latest SRS-list:"
        curl "https://www.synology.com/de-de/solution/SRS" -# --output "$srs"
        echo $(stat --printf="Size: %s" "$srs")
        awk '/<div class="selected_country">Deutschland<\/div>/{f=1;next} /<div class="selected_country">Griechenland<\/div>/{f=0} f' "$srs" > "${Script_dir}/files/SRS-de.php"
        CommenttedOut() {
        echo -e "\nGetting available Models:"
        curl "https://www.synology.com/cgi/misc/?action=getProductList_withOEM" -# | grep -oP '(?<=\[).*(?=\])' > "$ProductList" #get all Models listed in Synolgoy API
        echo $(stat --printf="Size: %s" "$ProductList")
        OLDIFS=$IFS
        IFS=","
        declare -a ModelArray
        counter="0"
        for v in $(cat "$ProductList")
        do  Models["${counter}"]="${v//\"}"
            counter=$((counter + 1))
        done
        IFS=$OLDIFS
        echo -e "\nModels: ${Models[@]}"
        echo "Downloading In-/Compatibility-lists:"
            echo "set net:connection-limit 20" > "${Script_dir}/comp/lftp.cfg"
            echo "set xfer:clobber yes" >> "${Script_dir}/comp/lftp.cfg"
            for m in "${Models[@]}"
                do
                    echo 'echo getting /comp/'"${m}"'_hdds_compatible.txt' >> "${Script_dir}/comp/lftp.cfg"
                    echo 'get "https://www.synology.com/api/compatibility/findHclList?lang=en-global&search_by=products&model='"${m//+/%2B}"'&category=hdds&usage_id=12&recommend=t" -o "'"${Script_dir}"'/comp/'"${m}"'_hdds_compatible.txt"' >> "${Script_dir}/comp/lftp.cfg"
                    #echo $(stat --printf=", Size: %s" "${Script_dir}/comp/${m}_hdds_compatible.txt")
                    echo 'echo getting /comp/'"${m}"'_hdds_incompatible.txt' >> "${Script_dir}/comp/lftp.cfg"
                    echo 'get "https://www.synology.com/api/compatibility/findHclList?lang=en-global&search_by=products&model='"${m//+/%2B}"'&category=hdds&usage_id=12&recommend=f" -o "'"${Script_dir}"'/comp/'"${m}"'_hdds_incompatible.txt"' >> "${Script_dir}/comp/lftp.cfg"
                    #echo $(stat --printf=", Size: %s" "${Script_dir}/comp/${m}_hdds_compatible.txt")
                done
            echo "bye" >> "${Script_dir}/comp/lftp.cfg"
            lftp -f "${Script_dir}/comp/lftp.cfg"
            echo "done.";
        }
        echo "Updating latest package Versions:"
        lftp -c "open https://archive.synology.com/download/Package/spk/; cls" > "${available_packages_pre}"; #download package list
        echo "Number of available Packages: $(cat "${available_packages_pre}" | wc -w)"
        	echo "set net:connection-limit 20" > "${Script_dir}/comp/lftp2.cfg"
        	echo "set xfer:clobber yes" >> "${Script_dir}/comp/lftp2.cfg"
            cat "${available_packages_pre}" | awk -v OFS="\\\ " '$1=$1' > "${available_packages}"
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
        echo -e "\n"
        exit 1
      ;;
    \?)
      echo "Invalid option: -$OPTARG. List all options with -h" >&2
      exit 1
      ;;
  esac
done

if [[ $(find "${Script_dir}"/files/ -name genRSS.php -mtime +2) ]] || [[ -z $(find "${Script_dir}"/files/ -name genRSS.php) ]]; then  #update genRSS.php after 2 days or if no file found
        echo "Downloading latest genRSS.php:"
        curl "https://update.synology.com/autoupdate/genRSS.php" -# --output "$rss"
fi

if [[ $(find "${Script_dir}"/files/ -name SRS.php -mtime +7) ]] || [[ -z $(find "${Script_dir}"/files/ -name SRS.php) ]]; then  #update, if no file found or older than 7 days
        echo "Downloading latest SRS-list:"
        curl "https://www.synology.com/de-de/solution/SRS" -# --output "$srs"
        awk '/<div class="selected_country">Deutschland<\/div>/{f=1;next} /<div class="selected_country">Griechenland<\/div>/{f=0} f' "$srs" > "${Script_dir}"/files/SRS-de.php
fi

echo -e "\nWaiting for debug-files..."

if grep -qE "(Microsoft|WSL)" /proc/version &> /dev/null ; then
    subl=/mnt/c/Program\ Files/Sublime\ Text\ 3/subl.exe
    os=win
else
    subl=subl
    os=other
fi

while true;
do
    for file in "$DOWNLOAD_DIR"/*.dat
    do
        if [[ -f $file ]]
        then
            while [[ -f $file.part ]] #wait for file to finish downloading (Firefox)
            do
                #echo "Waiting for Download to finish.."
                sleep $sleep_extract_zip
            done
            #echo $file
            time(
            date_now=$(date +"%d. %B %H:%M:%S: ")
            echo "$date_now" "found .dat-file! Timer started now"
            DATE=$(echo "$(date +"%H%M%S") - ($(date +%S)%10)" | bc)
            unzip -q "$file" -d "$DOWNLOAD_DIR"/debug_"$DATE"
            if [ $? -eq 0 ] # if successfully extracted
            then
                mv "$file" "$DOWNLOAD_DIR"/debug_"$DATE"
                date_now=$(date +"%d. %B %H:%M:%S: ")
                echo "$date_now" "debug extracted to ""$DOWNLOAD_DIR"/debug_"$DATE"
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/packages.list ]]
                then    DSM=""
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/ha/ha.conf ]]
                then
                    if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/ha/passive_debug.dat ]]
                    then
                        #sha=1
                        sm=$DOWNLOAD_DIR/debug_$DATE/$DSM/sm.log
                        echo -e "Synology HA: Detected, this is the ACTIVE Server-log" >> "$sm"
                        sleep_scan_dir=0.2
                        mv $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/ha/passive_debug.dat $DOWNLOAD_DIR/passive_debugfile.dat
                    fi
                elif [[ "$file" = "$DOWNLOAD_DIR/passive_debugfile.dat" ]]; then
                    #sha=2
                    DSM=$(ls "$DOWNLOAD_DIR"/debug_"$DATE"/tmp )
                    DSM="tmp/${DSM}"
                    sm="$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/sm.log
                    sleep_scan_dir="$sleep_scan_time"
                    echo -e "Synology HA: Detected, this is the PASSIVE Server-log" >> "$sm"
                else
                    sleep_scan_dir="$sleep_scan_time"
                    sm=$DOWNLOAD_DIR/debug_$DATE/$DSM/sm.log
                    echo -e "No Synology HA detected" >> "$sm"
                fi
                sm=$DOWNLOAD_DIR/debug_$DATE/$DSM/sm.log
                sg=$DOWNLOAD_DIR/debug_$DATE/$DSM/smartgrep
                hb_debug=$DOWNLOAD_DIR/debug_$DATE/$DSM/hibernation_debug.log
                DEBUG_DIR=$DOWNLOAD_DIR/debug_$DATE
                Synoinfo=$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/packages.list ]]
                then    PACK=$DOWNLOAD_DIR/debug_$DATE/$DSM/packages.list
                        declare -a InstalledPackageArray
                        cat "${PACK}" | sed '1d' | awk '{for(i=NF;i>1;i=i-1) printf "%s ", $i; printf "%s\n", $1}' | cut -d " " -f1 > "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/packages_ver.list
                        readarray -t "InstalledPackageArray" < "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/packages_ver.list
                        counter=0
                        for i in "${InstalledPackageArray[@]}"
                        do
                            aver=$(grep "$i " "$package_versions")
                            PureVerAvailable=$(echo "${aver}" | rev | cut -d " " -f1 | rev | sed 's/\-/./g')
                            PureVerInstalled=$(grep "$i " "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/var/log/synopkg.log | tail -n1 | grep -oP '(?<='$i' )\S*' | sed 's/\-/./g')
                            echo "${InstalledPackageArray[$counter]}: Installed: $PureVerInstalled vs. available: $PureVerAvailable"
    version_cmp() {
    if (( $# != 3 )) ||
       [[ $1 != +([0-9])*(.+([0-9])) ||
          $2 != @(==|!=|>|>=|<|<=)   ||
          $3 != +([0-9])*(.+([0-9])) ]]; then
        printf 'Usage: version_cmp VERSION { == | != | > | >= | < | <= } VERSION\n' >&2
        return 127
    fi

    local op=$2

    local -a x y
    IFS=. read -r -a x <<<"$1" || return $?
    IFS=. read -r -a y <<<"$3" || return $?

    while (( ${#x[@]} && ${#y[@]} && x[0] == y[0] )); do
        x=( "${x[@]:1}" )
        y=( "${y[@]:1}" )
    done

    # shellcheck disable=SC2086,SC1105,SC2211
    if (( ${#x[@]} && ${#y[@]} )); then
        (( x[0] $op y[0] ))
    else
        (( ${#x[@]} $op ${#y[@]} ))
    fi
}
if version_cmp "${PureVerInstalled}" '==' "${PureVerAvailable}"; then
    echo -e "\e[32msame Version!\e[0m"
elif version_cmp "${PureVerInstalled}" '<' "${PureVerAvailable}"; then
    echo -e "\e[31mnew Version is available\e[0m"
elif version_cmp "${PureVerInstalled}" '>' "${PureVerAvailable}"; then
    echo -e "\e[93minstalled Version later than available?!\e[0m"
else
    echo -ne "\e[101msome error occured: "
    echo -e "${InstalledPackageArray[$counter]}: Installed: $PureVerInstalled vs. available: $PureVerAvailable\e[0m"
fi
                            #if [[ $(echo "$PureVerAvailable > $PureVerInstalled" | bc) ]]
                            #then
                            #    echo "Update for ${InstalledPackageArray[$counter]} to $PureVerAvailable available!"
                            #elif [[ $PureVerAvailable -le $PureVerInstalled ]]
                            #then
                            #    echo "Up to Date!"
                            #else
                            #    echo "Error occured."
                            #fi
                            #echo "counter: $counter"
                            counter=$((counter + 1))
                            #sed -i "'${counter}i\'$abc'" "$package_versions" ##geht nicht.
                        done
                        #echo -e "\n\n\navailable Versions:"
                        #cat "${package_versions}"
                        grep -i "CloudSync\|MailServer\|SurveillanceStation" "$PACK" >> "$hb_debug"
                        #to add: AD Server, AudioStation protokollierung, CloudStation Server, CloudStation Sharesync, Directory server
                        #DownloadStation: emule, Docker-Discourse, Docker-GitLab, Docker-LXQt, Docker-Redmine, Docker-Spree, Document Viewer
                        #MailPlus Server
                        #Drittanbieterpakete, Asterisk, Bittorrent sync, Cloud Fleet, DVBLink-Server, Egnyte, ElephantDrive, Logitech® Medienserver, minimserver, Odoo8, OpenERP6, OpenERP7, OracleDBXE, PACS, Polkast, Symform Cloud Backup, VirtualHere, Webalizer, Wonderbox, xCloud, Zarafa, Andere Drittanbieter-Software oder Optware, z. B. SABnzbd
                        #usb-geraet angeschlossen
                        echo -e "Drittanbieterpakete:" >> "$sm"
                        third_packages=$(grep -v "AntiVirus\|AudioStation\|Calendar\|CloudStation\|FileStation\|HyperBackup\|LogCenter\|MediaServer\|NoteStation\|PHP[0-9].[0-9]\|PhotoStation\|ProxyServer\|StorageAnalyzer\|SynoFinder\|SynologyApplicationService\|SynologyDrive\|TextEditor\|USBCopy\|VideoStation\|WebDAVServer\|CloudSync\|DownloadStation\|SurveillanceStation\|WebStation\|VPNCenter\|MariaDB\|Chat\|Git\|Node.js_4\|Perl\|ActiveBackup\|ActiveBackup-Office365\|ActiveDirectoryServer\|Apache[0-9].[0-9]\|CMS\|CardDAVServer\|DNSServer\|DiagnosisTool\|Docker\|MailClient\|MailPlus-Server\|OAuthService\|PetaSpace\|PrestoServer\|PythonModule\|SSOServer\|SnapshotReplication\|Spreadsheet\|SynologyMoments\|Virtualization\|iTunesServer\| enabled\|TimeBackup\|Java7\|Java8\|exFAT\|PDFViewer\|MailStation\|phpMyAdmin\|total [[:digit:]]\{,3\}" "$PACK")
                        if [ -z "$third_packages" ]; then
                            echo "No Third Party Packages found." >> "$sm"
                            else
                            echo "$third_packages" >> "$sm"
                        fi
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/result/df.result ]]
                then    DF=$DOWNLOAD_DIR/debug_$DATE/$DSM/result/df.result
                        full_number=$(awk '0+$5 >= 90 { count++ } END{print 0+count}' "$DF")
                        echo -en "\nMountpoints more than 90% full: (""$full_number"")" >> "$sm"
                        echo -n "Mountpoints more than 90% full: (""$full_number"")" >> "$sg"
                        if [[ "$full_number" -gt 0 ]]
                        then
                            awk '0+$5>90 { printf "\n%s",$0 }' "$DF" >> "$sm"
                            awk '0+$5>90 { printf "\n%s",$0 }' "$DF" >> "$sg"
                        else
                            echo " No full Mountpoints found." >> "$sm"
                            echo " No full Mountpoints found." >> "$sg"
                        fi
                        echo -e "\n"  >> "$sg"
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/proc/mdstat ]]
                then    MDSTAT=$DOWNLOAD_DIR/debug_$DATE/$DSM/proc/mdstat
                        cat "$MDSTAT" >> "$sg"
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/bash_history.log ]]
                then    Bash_history=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/bash_history.log
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/proc/mounts ]]
                then    MOUNTS=$DOWNLOAD_DIR/debug_$DATE/$DSM/proc/mounts
                        echo -e "\neingehängte Mountpunkte:" >> "$sg"
                        cat "$MOUNTS" >> "$sg"
                        echo -e " \n \n"  >> "$sg"
                        echo -e "\n\neingehängte Mountpunkte:" >> "$sm"
                        grepmounts=$(grep -i "volume" "$MOUNTS" | cut -f1 -d",")
                        grepmounts_c=$(grep -i -c "volume" "$MOUNTS" | cut -f1 -d",")
                        if [ "$grepmounts_c" -ne 0 ]
                            then echo "$grepmounts" >> "$sm"
                        else echo "No Volumes mounted." >> "$sm"
                        fi

                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/result/ifconfig.result ]]
                then    IFCONFIG=$DOWNLOAD_DIR/debug_$DATE/$DSM/result/ifconfig.result
                    ipv6_enabled=$(grep eth -A7 "$IFCONFIG" | grep -c "inet6 addr")
                    declare -a ifc_dropped
                    ifc_dropped=$(grep "dropped" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/result/ifconfig.result | sed 's/.*dropped://' | cut -d " " -f1)
                    ifc_dropped_sum=0
                    for i in "${ifc_dropped[@]}"; do
                        let ifc_dropped_sum+=$i
                    done

                    declare -a ifc_error
                    ifc_error=$(grep "errors" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/result/ifconfig.result | sed 's/.*errors://' | cut -d " " -f1)
                    ifc_error_sum=0
                    for i in "${ifc_error[@]}"; do
                        let ifc_error_sum+=$i
                    done
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/etc/ntp.conf ]]
                then    ntp=$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/ntp.conf
                        ntp_google=$(grep -c time.google.com.conf "$ntp")
                        ntp_pool=$(grep -c pool.ntp.org.conf "$ntp")
                        ntp_other=$(grep -c "server " "$ntp")
                        ntp_other_awk=$(grep "server " "$ntp" | awk ' {print $2 }')
                        if [ "$ntp_google" -gt 0 ]
                            then echo "NTP-Client enabled. Server is time.google.com" >> "$hb_debug"
                        elif [ "$ntp_pool" -gt 0 ]
                            then echo "NTP-Client enabled. Server is pool.ntp.org" >> "$hb_debug"
                        elif [ "$ntp_other" -gt 0 ]
                            then echo -n "NTP-Client enabled. Server is " >> "$hb_debug"
                                 echo "$ntp_other_awk" >> "$hb_debug"
                        else
                            echo "NAS is no NTP-Client, Time set to manual" >> "$hb_debug"
                        fi
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/usr/syno/etc/synoservice.override/ntpd-server.cfg ]]
                then    ntpd_server_cfg=$DOWNLOAD_DIR/debug_$DATE/$DSM/usr/syno/etc/synoservice.override/ntpd-server.cfg
                        echo -n "NTP-Server: " >> "$hb_debug"
                        ntp_server_enabled=$(grep -c yes "$ntpd_server_cfg")
                        if [ "$ntp_server_enabled" -gt 0 ]
                            then echo "NTP-Server on NAS enabled." >> "$hb_debug"
                        elif [ "$ntp_server_enabled" -eq 0 ]
                            then echo "NTP-Server on NAS disabled." >> "$hb_debug"
                        fi
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/etc/hostname ]]
                then    Hostname=$(cat $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/etc/hostname)
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/usr/syno/etc/synorelayd/synorelayd.conf ]]
                then    QuickConnect_alias=$(grep '"alias"' $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/usr/syno/etc/synorelayd/synorelayd.conf | sed "s/.*: //" | sed 's/\"//g')
                if [[ -z "$QuickConnect_alias" ]]; then
                    QuickConnect_echo="No QuickConnect alias is set"
                    echo "QuickConnect disabled" >> "$hb_debug"
                    else QuickConnect_echo="QuickConnect Hostname: ""$QuickConnect_alias"".quickconnect.to"
                    echo "QuickConnect enabled" >> "$hb_debug"
                fi
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages ]]
                then    MESSAGES=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages.log
                        mv $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/var/log/messages $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/var/log/messages.log
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/etc/ddns.conf ]]
                then    ddns=$(grep -c "service=true" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/etc/ddns.conf)
                    if [[ $ddns = 1 ]]; then
                        echo "DDNS enabled" >> "$hb_debug"
                    fi
                    if [[ $ddns = 0 ]]; then
                        echo "DDNS disabled" >> "$hb_debug"
                    fi
                fi
               # if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/etc/private/domain_info ]]
               # then    windomain=$(grep "ads:domain_name" $DOWNLOAD_DIR/debug_$DATE/$DSM/etc/private/domain_info)
               # if [[ -z "$windomain" ]]; then
               #     echo "Not in a AD." >> "$sm"
               #     else echo "Domainname: $windomain" >> "$sm"
               # fi
               # fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/result/uptime.result ]]
                then    UPTIME=$(cat $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/result/uptime.result)
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/hibernation.log ]]
                then    HB=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/hibernation.log
                # find if NAS is LDSP-Client
                #Check if LMB enabled
                #System-Protokoll: Wenn eins der Systemprotokoll-Tools (Support-Center > Support-Dienste > Systemprotokoll-Tools) aktiviert ist (ab DSM 6.0).
                #process synoindexd
                #Windows Media Player: Wenn der Netzwerk-Freigabedienst des Windows Media Players im LAN aktiviert ist.
                #Ihr Synology NAS kann nicht in den Ruhezustand wechseln, wenn gleichzeitig laufende Prozesse Swap-Speicher benötigen, wenn die RAM-Kapazität überschritten wurde und Festplatten vorübergehend für Lese-/Schreibvorgänge verwendet werden.
                fi

                declare -a SMART_FILES
                SMART_FILES=( "${DOWNLOAD_DIR}/debug_${DATE}/${DSM}/result/smart"*.result )

                declare -a SMART_neu
                SMART_neu=( "${DOWNLOAD_DIR}/debug_${DATE}/${DSM}/var/log/smart_result/"*.txz )


                #if [ "${#SMART_FILES[@]}" -ne "0" ]; then
                #echo "altsmart#: ${#SMART_FILES[@]}"
                if [ "${#SMART_neu[@]}" -ne "0" ]; then
                        tar xf "${SMART_neu[-1]}" -C "$DOWNLOAD_DIR/debug_""$DATE""/""$DSM""/result/"
                        smarttar=$(ls "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/var/log/smart_result/ )
                        for file in $(ls $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/result/var/log/smart_result/"$smarttar"/* )
                        do
                            #[[ -e $f ]] || break #no smart-files
                            filename=$(basename -- "$file")
                            mv "$file" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/result/smart_"$filename".result
                        done
                        declare -a SMART_neu_extracted
                        SMART_neu_extracted=( "${DOWNLOAD_DIR}/debug_${DATE}/${DSM}/result/smart"*.result )
                        #echo "neusmart#: ${#SMART_neu_extracted[@]}"
                else
                    echo "No Smart-files found."
                fi

                # ALT: for file in $(ls $DOWNLOAD_DIR/debug_$DATE/$DSM/result/smart*.result)
                for file in $(ls $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/result/smart*.result)
                do
                    #[[ -e $f ]] || break #no smart-files
                    declare -a BadSectors
                    declare -a PendingSectors
                    declare -a OfflineUncorrectable
                    BadSectors=$(grep -i "Reallocated_Sector_Ct\|Reallocated_Sector_Count" "$file" | awk '{print 0+$10 }')
                    PendingSectors=$(grep -i "Current_Pending_Sector" "$file" | awk '{print 0+$10 }')
                    OfflineUncorrectable=$(grep -i "Offline_Uncorrectable\|Uncorrectable_Error_Count" "$file" | awk '{print 0+$10 }')
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
                echo -e "\nHDDs: " >> "$sm"
                echo "Reallocated_Sector_Ct:" $BadSector_sum >> "$sm"
                echo "Current_Pending_Sector:" $PendingSectors_sum >> "$sm"
                echo "Offline_Uncorrectable:" $OfflineUncorrectable_sum >> "$sm"

                #declare -a PowerOnHours
                for file in $(ls $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/result/smart*.result)
                do
                    #[[ -e $f ]] || break #no smart-files
                    hddname=$(basename -- "$file")
                    hddname2=$(grep -i "Model Family\|Device Model" "$file" | cut -d " " -f7-20 | sed -r 's/\"/Inch/' | xargs )
                    echo -n "$hddname: $hddname2: PowerOnHours: " >> "$sm"
                    PoH=$(grep -E "Power(_|-)(O|o)n_Hours" "$file" | sed -e "s/ ([^()]*)//g" | rev | cut -d " " -f1 | rev | sed 's/h.*//' )
                    echo -n "${PoH}"", Last Extended SMART-Test: " >> "$sm"
                    LastSmartTest=$(grep -i -m1 "Extended Offline" "$file" | sed -n '/Extended offline/s/ \+/ /gp' | cut -d " " -f9 )
                    re='^[0-9]+$'
                    if ! [[ ${LastSmartTest} =~ $re ]] ; then
                    LastSmartTest=$(grep -i -m1 "Extended Offline" "$file" | sed -n '/Extended offline/s/ \+/ /gp' | cut -d " " -f8 )
                    fi
                    if [[ -z ${LastSmartTest} ]]; then
                    echo "never, " >> "$sm"
                        else
                        LastSmartExpr=$(expr "${PoH}" - "${LastSmartTest}" )
                        echo "$LastSmartExpr" "hours ago, " >> "$sm"
                    fi
                done
                #mehr smart-kram
                echo -e "\n" >> "$sm"

                for file in $(ls $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/result/smart*.result)
                do
                    #[[ -e $f ]] || break #no smart-files
                    grep -i "Model Family\|Device Model" "$file" >> "$sg"
                done
                for file in $(ls $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/result/smart*.result)
                do
                    #[[ -e $f ]] || break #no smart-files
                    echo -e "\n"  >> "$sg"
                    echo "$file" >> "$sg"
                    grep -i "overall-health self-assessment\|Model Family\|Device Model\|Serial Number\|User Capacity\|Sector Sizes\|ID\#\|Raw_Read_Error_Rate\|Reallocated_Sector_Ct\|Seek_Error_Rate\|Spin_Retry_Count\|Calibration_Retry_Count\|Reallocated_Event_Count\|Current_Pending_Sector\|Offline_Uncorrectable\|UDMA_CRC_Error_Count\|Multi_Zone_Error_Rate\|Power_On_Hours\|Reallocated_Sector_Count\|Power-on_Hours\|Program_Fail_Count_(total)\|Erase_Fail_Count_(total)\|Runtime_Bad_Count_(total)\|Uncorrectable_Error_Count\|ECC_Error_Rate\|CRC_Error_Count\|POR_Recovery_Count" "$file" >> "$sg"
                            echo " "  >> "$sg"
                            awk '/SMART Error Log Version: 1/{f=1;next} /Selective self-test flags/{f=0} f' "$file" >> "$sg"
                    echo -e " \n \n"  >> "$sg"
                done

                ls -lh $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/etc/space/space_history_*.xml >> $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/space
                for file in $(ls $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/etc/space/space_history_*.xml)
                do
                    #[[ -e $f ]] || break #no space-files
                    {
                    echo "$file"
                    cat "$file"
                    echo -e "\n \n \n \n"
                    } >> $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/space
                done
                SPACE_FILES=$DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/space

                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/smartgrep ]]
                then    SMART_GREP=$DOWNLOAD_DIR/debug_$DATE/$DSM/smartgrep
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmidecode.result ]]
                then
                    BIOS_V_CUT=$( grep -i "BIOS Information" -A5 $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/result/dmidecode.result | grep -i "Version" | sed "s/.*Version: //" )
                        #DS_MEM=$( grep -A6 "Memory Device Mapped Address" $DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmidecode.result | grep "Range Size" | sed "s/.*Size: //" )
                        #DS_MEM3=$(grep -A6 "Memory Device$" $DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmidecode.result | grep Size)
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmesg.result ]]
                then    Dmesg=$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmesg.result
                        #DS_MEM2=$( grep -i -m1 "Memory: " $Dmesg | sed "s/.*Memory: //" | cut -d " " -f3 )
                        Syno_bios=$( tac "$Dmesg" | grep "synobios: load" -m1 | sed 's/.*load, //' )
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/result/free.result ]]
                then
                        free_mem=$( grep Mem $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print $2 }' | awk '{ split( "KB MB GB" , v ); s=1; while( $1>1024 ){ $1/=1024; s++ } print int($1) v[s] }' )
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/result/route.result ]]
                then    Route=$DOWNLOAD_DIR/debug_$DATE/$DSM/result/route.result
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/kern.log ]]
                then    KERN=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/kern.log
                    DS_HWMODEL=$( grep -ia -m1 'syno_hw_version' "$KERN" | sed 's/.*syno_hw_version=//' | cut -d " " -f1 | sed 's/v.*$//' | sed 's/p\b/+/g') #i.e. DS213j
                    DS_MODEL=$( grep -ia -m1 '] Model:' "$KERN" | sed 's/.*: //' | sed 's/-//g' | sed 's/-//p') #i.e. DS213j
                    UpnpModel=$(grep -i "upnpmodelname" "$Synoinfo" | cut -d "\"" -f2)
                    if [ -z "$DS_HWMODEL" ]; then
                            echo "No DS_Model found, using UPNP-Name: ""$UpnpModel"
                            DS_MODEL_v="${UpnpModel}"
                            DS_MODEL_unter="${DS_MODEL_v}_"
                            DS_MODEL_plus="${DS_MODEL_unter//+/%2B}"
                            else DS_HWMODEL_v="${DS_HWMODEL}"
                                DS_MODEL_unter="${DS_HWMODEL_v}_"
                                DS_MODEL_plus="${DS_MODEL_unter//+/%2B}"
                    fi
                    DS_CPU=$( grep -m1 "model name\|Hardware" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/proc/cpuinfo )
                    DS_Cores=$( cat $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/proc/sys/kernel/syno_CPU_info_core )
                    Processor_count=$( grep -i -c "processor" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/proc/cpuinfo ) #CPU Count
                    DS_SN=$( cat $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/proc/sys/kernel/syno_serial )
                    #DS_SN=$( grep -i -m1 "serial number" $DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/kern.log | sed "s/.*[Ss]erial [Nn]umber//" )
                fi
                #hdd-compatibility:
                if [[ -f ${Script_dir}/files/comp/"${UpnpModel}"_hdds_compatible.txt ]]; then
                    comp_list=${Script_dir}/files/comp/"${UpnpModel}"_hdds_compatible.txt
                    echo "Compatibility-list for ${UpnpModel} found and set."
                fi
                if [[ -f ${Script_dir}/files/comp/"${UpnpModel}"_hdds_incompatible.txt ]]; then
                    incomp_list=${Script_dir}/files/comp/"${UpnpModel}"_hdds_incompatible.txt
                    echo "Incompatibility-list for ${UpnpModel} found and set."
                fi
                    #Hardware-specific things
                    if [ "$DS_MODEL" = "DS216+" ] || [ "$DS_HWMODEL" = "DS216+" ]; then
                        echo "Possible BIOS-Issue: https://css.synology.com/issue/4334" >> "$sm"
                        echo -e "Bugged Versions are less than M.616 \n" >> "$sm"
                    fi
                    if [ "$DS_MODEL" = "DS718+" ] || [ "$DS_HWMODEL" = "DS718+" ]; then
                        grep_cputemp=$( grep -c "<cpu_temperature> is over" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/var/log/scemd.log )
                        if [ "$grep_cputemp" -gt 0 ]; then
                        echo "CPU is overheating, RMA unit: https://css.synology.com/issue/11124" >> "$sm"
                        grep -i "<cpu_temperature> is over" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/var/log/scemd.log >> "$sm"
                        fi
                    fi
                    if [ "$DS_MODEL" = "DS718+" ] || [ "$DS_MODEL" = "DS918+" ] || [ "$DS_MODEL" = "DS218+" ] || [ "$DS_MODEL" = "DS418play" ] || [ "$DS_HWMODEL" = "DS718+" ] || [ "$DS_HWMODEL" = "DS918+" ] || [ "$DS_HWMODEL" = "DS218+" ] || [ "$DS_HWMODEL" = "DS418play" ]; then
                        echo "possible BIOS-Issue: https://css.synology.com/issue/12026" >> "$sm"
                        echo "Update to DSM 6.1.3-15152 Update 7 to update the BIOS." >> "$sm"
                    fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages.log ]]
                then
                    echo "Memory Tests: " >> "$sm"
                    Passed_Memtest=$( grep -c "Memtest passed" "$MESSAGES" )
                    Failed_Memtest=$( grep -c "Memtest failed" "$MESSAGES" )
                    if [ "$Passed_Memtest" -gt 0 ]; then
                        echo "$Passed_Memtest" "Memory tests have passed." >> "$sm"
                        grep -a "Memtest passed" "$MESSAGES" >> "$sm"
                    fi
                    if [ "$Failed_Memtest" -gt 0 ]; then
                        echo "Found $Failed_Memtest failed Memtests:" >> "$sm"
                        grep -a "Memtest failed" "$MESSAGES" >> "$sm"
                    fi
                    if [[ "$Passed_Memtest" -eq 0 ]] && [[ "$Failed_Memtest" -eq 0 ]]; then #MEMTESTS
                        echo "No Memory tests have been run." >> "$sm"
                    fi
                    DSM_VERSION=$( cat $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/etc.defaults/VERSION ) #DSM Version
                    #echo -e " "  >> "$sm"
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/scemd.log ]]
                then
                    grep_disktemp=$( grep -c "temperature> is over" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/var/log/scemd.log )
                        if [ "$grep_disktemp" -gt 0 ]; then
                        echo "CPU or Disk is overheating:" >> "$sm"
                        grep -i "temperature> is over" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/var/log/scemd.log >> "$sm"
                        fi
                fi
                date_now=$(date +"%d. %B %H:%M:%S: ")
                echo "$date_now" "$DS_MODEL" #write to sm after this

                if grep -wi "$DS_HWMODEL\|$DS_MODEL\|$UpnpModel" "$Script_dir"/files/SRS-de.php &> /dev/null ; then
                    echo -e "NAS can be SRSed in DE! ( enabled )" >> "$sm"
                else
                    echo -e "no DE-SRS possible. ( disabled )" >> "$sm"
                fi
                if [ "$ipv6_enabled" -gt 0 ]; then
                    echo -e "\nIPv6 enabled" >> "$sm"
                    echo "IPv6 enabled" >> "$hb_debug"
                else echo -e "\nIPv6 disabled" >> "$sm"
                     echo "IPv6 disabled" >> "$hb_debug"
                fi
                echo "found" $ifc_dropped_sum "dropped Packages in ifconfig.result." >> "$sm"
                echo "found" $ifc_error_sum "bugged Packages in ifconfig.result." >> "$sm"
                for file in $(ls $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/result/ethtool.eth*.result)
                do
                    [[ -e $file ]] || break  # handle the case of no *.result files
                    ethresult=$(grep "Speed" -H "$file")
                    echo "${ethresult#$DOWNLOAD_DIR/debug_$DATE/$DSM/result/}" >> "$sm"
                done
                echo "DNS Servers:" >> "$sm"
                cat "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/resolv.conf" >> "$sm"
                echo -e "\n" >> "$sm"
                cat "$Route" >> "$IFCONFIG"
                #echo -e "\n" >> "$sm"
                DS_upnp_v="${UpnpModel}"
                DS_upnp_unter="${DS_upnp_v}_"
                DS_upnp_plus="${DS_upnp_unter//+/%2B}"
                LatestBuildNumber=$( grep -i "$DS_upnp_plus" "$rss" | sed -e 's/<[^>]*>//g' | head -n 1 | cut -d "_" -f3 | cut -d "." -f1 ) #_plus
                DSMBuildNumber=$( grep buildnumber $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/etc.defaults/VERSION | cut -d "\"" -f2 )
                if [ "$LatestBuildNumber" -gt "$DSMBuildNumber" ]; then
                    {
                    echo "More current DSM Version available."
                    echo "available Updates (grep ""$DS_MODEL_plus"") :"
                    grep -i "$DS_MODEL_plus" "$rss" | sed -e 's/<[^>]*>//g'
                    } >> "$sm"
                else echo "DSM Version is latest!" >> "$sm"
                fi
                {
                echo "installed VERSION: " $DSM_VERSION
                echo -e "\nUptime: " "$UPTIME"
                echo "Hostname: " "$Hostname"
                echo "$QuickConnect_echo"
                }  >> "$sm"
                if [ "$ddns" = 1 ]; then
                    echo -n "DDNS " >> "$sm"
                        grep "hostname" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/etc/ddns.conf >> "$sm"
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf ]]; then
                    grep -ia "supportrcpower" "$Synoinfo" >> "$sg"
                    grep -ia "enableRCPower" "$Synoinfo" >> "$sg"
                fi
                {
                echo "BIOS:" "$BIOS_V_CUT"
                echo "SynoBIOS: " "$Syno_bios"
                echo "Hardware Version:" "$DS_HWMODEL"
                echo "Diskstationmodel:" "$DS_MODEL"
                echo "UPNP Model:" "$UpnpModel"
                echo "CPU from logs:" "$DS_CPU"
                echo "Anzahl Threads:" "$Processor_count"
                echo "Anzahl Cores:" "$DS_Cores"
                echo "Seriennummer:" "$DS_SN"
                 # hwversion before: $DS_HWMODEL DS_MODEL_plus
                #echo -e 'Associated Tickets: \nhttps://css.synology.com/ticket?list_type=group_all&sort_by=update_time&sort_direction=desc&filter=%7B%22search%22%3A%22'"$DS_SN"'%22%7D' >> "$sm"
                #date_now=$(date +"%d. %B %H:%M:%S: ")
                #echo -e "$date_now" 'Associated Tickets: \nhttps://css.synology.com/ticket?list_type=group_all&sort_by=update_time&sort_direction=desc&filter=%7B%22search%22%3A%22'"$DS_SN"'%22%7D'
                #echo -e "\nArbeitsspeicher from logs:" $DS_MEM "or" $DS_MEM2 >> "$sm"
                echo -e "\nArbeitsspeicher free.result:" "$free_mem""+"
                } >> "$sm"

                if [ -z "${UpnpModel}" ];
                then
                    echo "CPUinfo from txt: no model detected." >> "$sm"
                fi

                DS_CPU_TXTINFO=$( grep -m1 "CPU-Modell" "$CPU_FILE" )
                UpnpModel_plusgrep=$( echo $UpnpModel | sed -r 's/[+]/\\+/g' | sed 's/$/\\s/' )
                DS_CPU_TXT=$( grep -Ew "$UpnpModel_plusgrep" "$CPU_FILE" )
                DS_MEM_TXT=$( grep -Ew "$UpnpModel_plusgrep" "$CPU_FILE" | rev | cut -d ' ' -f1,2 |rev ) #todo: if realRAM > preinstalled then echo
                {
                echo "CPUinfo from txt:"
                echo "$DS_CPU_TXTINFO"
                echo "$DS_CPU_TXT"
                echo -e "\n"
                }  >> "$sm"
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/synolog/synosys.log ]]; then
                #if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/synolog/.SYNOSYSDB ]]; then
                #    sqlite3 $DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/synolog/.SYNOSYSDB "select id, datetime(time,'unixepoch','localtime'), username, msg from logs;" >> $DOWNLOAD_DIR/debug_$DATE/$DSM/SYSDB
                    #SYSDB=$DOWNLOAD_DIR/debug_$DATE/$DSM/SYSDB
                    SYSDB=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/synolog/synosys.log
                    tac "$SYSDB" >> $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/var/log/synolog/synosystac.log
                    SYSDBtac=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/synolog/synosystac.log
                    {
                    echo "improper shutdowns:"
                    grep -i "improper shutdown" "$SYSDB" #improper shutdown
                    echo "Volume crashes:"
                    grep -i "was crashed" "$SYSDB" #volumecrash
                    echo "degraded volumes:"
                    grep -i "degrade" "$SYSDB" #volume degraded
                    echo "errors:"
                    grep -i "error" "$SYSDB" #generic Errors
                    } >> "$sm"
                fi
                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages.log ]]; then
                    {
                    echo "DRDY:"
                    grep -ia -B5 -A10 "DRDY" "$MESSAGES"
                    echo "malformed database:"
                    grep -ia "database disk image is malformed" "$MESSAGES"
                    echo "crashes:"
                    grep -ia "crash" "$MESSAGES"
                    echo "call traces + next 25 lines:"
                    grep -a "Call Trace" "$MESSAGES" -A25
                    } >> "$sm"
                fi
                #write hibernation info:
                satadeepsleep=$(grep -c "satadeepsleeptimer=\"1\"" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/etc/synoinfo.conf)
                if [ "$satadeepsleep" -gt 0 ]
                        then echo -e "Hibernation enabled.\n" >> "$hb_debug"
                        else echo -e "Hibernation is disabled.\n" >> "$hb_debug"
                fi
                grep "^standbytimer" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/etc/synoinfo.conf >> "$hb_debug"
                grep "enable_fan_debug" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/etc/synoinfo.conf >> "$hb_debug"
                kernel_log_max=$(grep -c "kern_log_max=\"yes\"" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/etc/synoinfo.conf)
                if [ "$kernel_log_max" -gt 0 ]
                        then echo "Extended kernel logging enabled." >> "$hb_debug"
                        else echo "Extended kernel logging disabled." >> "$hb_debug"
                fi
                grep "local master" $DOWNLOAD_DIR/debug_"$DATE"/"$DSM"/etc/samba/smb.conf >> "$hb_debug"

                if [[ -f $DOWNLOAD_DIR/debug_$DATE/$DSM/etc/power_sched.conf ]]; then #call power_sched.py
                    echo -e "\n" >> "$hb_debug"
                    cat $DOWNLOAD_DIR/debug_$DATE/$DSM/etc/power_sched.conf >> "$hb_debug"
                    while read p; do
                        re='^[0-9]+$'
                        if [[ $p =~ $re ]] ; then
                           python "${PShedPy}" $p >> "$hb_debug";
                        fi
                        done < $DOWNLOAD_DIR/debug_$DATE/$DSM/etc/power_sched.conf
                    els
                     echo "power_sched.conf not found." >> "$hb_debug"
                fi
                #LDAP: Wenn Ihr Synology NAS als LDAP-Client fungiert (ab DSM 6.0.1)
                declare -a PicArray
                counter=0
                allpics=$(find "$DOWNLOAD_DIR/debug_${DATE}/" -type f \( -name "*.jpg" -o -name "*.png" \))
                for pic in $allpics
                do  PicArray["${counter}"]="${pic}"
                    counter=$((counter + 1))
                done

                sleep 1
                $subl "$DEBUG_DIR" "$SMART_GREP" "$PACK" "$Bash_history" "$hb_debug" "$HB" "$DF" "$IFCONFIG" "$SPACE_FILES":10000 "$SYSDBtac":100000 "$sm" "$MESSAGES":1000000 "${PicArray[@]}" #$pics
                echo "subl \"$DEBUG_DIR\" \"$SMART_GREP\" \"$PACK\" \"$Bash_history\" \"$hb_debug\" \"$HB\" \"$DF\" \"$IFCONFIG\" \"$SPACE_FILES:10000\" \"$SYSDBtac:100000\" \"$sm\" \"$MESSAGES:1000000\" \"${PicArray[@]}\""
                echo "subl \"$DEBUG_DIR\" \"$SMART_GREP\" \"$PACK\" \"$Bash_history\" \"$hb_debug\" \"$HB\" \"$DF\" \"$IFCONFIG\" \"$SPACE_FILES:10000\" \"$SYSDBtac:100000\" \"$sm\" \"$MESSAGES:1000000\" \"${PicArray[@]}\"" > ~/last_debug.sh
                # for smart-files: ${SMART_FILES[@]}  $MDSTAT
            else
                mkdir -p $DOWNLOAD_DIR/kapott
                mv "$file" $DOWNLOAD_DIR/kapott/debug_"$DATE".dat
                echo "$file" "konnte nicht entpackt werden."
                if [[ $os = "win" ]]; then
                    echo "" #maybe add things here
                elif [[ $os = "other" ]]; then
                    #statements
                    zenity --error --text="Debug konnte nicht entpackt werden\!" --title="Achtung!" 2> /dev/null
                fi
            fi
            DSM=dsm
            #sha=0
            )
            echo -e "\n"
        fi
    done
    sleep $sleep_scan_dir
    #Scan_time=$(date +"%H:%M:%S")
    #echo $Scan_time "Rescanning for .dat Files"
done
IFS="$OIFS"
