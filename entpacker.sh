#!/bin/bash

#for handling spaces in filenames
#IFS=$'\n'

#debugging with times:
#N=`date +%s%N`
#export PS4='+[$(((`date +%s%N`-$N)/1000000))ms][${BASH_SOURCE}:${LINENO}]: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'; set -x;

# set bash option to avoid
# unmatched patterns expand as result values
shopt -s nullglob

#win sub:sudo apt-get  install bc unzip (sqlite3) xmllint
#sudo apt install sqlite3 zenity sublime-text xmllint lftp

sleep_scan_dir=2 #Folder rescan time in seconds
sleep_extract_zip=0.5 #rescan time for finishing download
Script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${Script_dir}/files/config.sh"
DSM=dsm
CPU_FILE="${Script_dir}/files/CPU.txt"
PShedPy="${Script_dir}/files/power_shed.py"
rss="${Script_dir}/tmp/genRSS.php"
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

while getopts ":uvh" opt; do
  case $opt in
    u)
        echo "updating files:" >&2
        echo -e "\nDownloading latest genRSS.php:"
        curl "https://update.synology.com/autoupdate/genRSS.php" -# --output "$rss"
        stat --printf="Size: %s" "$rss"
        echo -e "\nDownloading latest SRS-list:"
        curl "https://www.synology.com/de-de/solution/SRS" -# --output "$srs"
        stat --printf="Size: %s" "$srs"
        awk '/<div class="selected_country">Deutschland<\/div>/{f=1;next} /<div class="selected_country">Griechenland<\/div>/{f=0} f' "$srs" > "$srsde"
        #CommentedOut() { #uncomment this and line 86 to stop downloading hdd-comp on -u
        echo -e "\nGetting available Models:"
        curl "https://www.synology.com/cgi/misc/?action=getProductList_withOEM" -# | grep -oP '(?<=\[).*(?=\])' > "$ProductList" #get all Models listed in Synology API
        stat --printf="Size: %s" "$ProductList"
        IFS=","
        #declare -a ModelArray
        counter="0"
        for v in $(cat "$ProductList")
        do  Models["${counter}"]="${v//\"}"
            counter=$((counter + 1))
        done
        IFS=$' \t\n'
        echo -e "\nModels: ${Models[*]}" #old: echo -e "\nModels: ${Models[@]}"
        echo "Downloading In-/Compatibility-lists:"
            echo "set net:connection-limit 20" > "${Script_dir}/comp/lftp.cfg"
            echo "set xfer:clobber yes" >> "${Script_dir}/comp/lftp.cfg"
            for m in "${Models[@]}"
                do
                {
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


if [[ $(find "${Script_dir}"/tmp/ -name genRSS.php -mtime +2) ]] || [[ -z $(find "${Script_dir}"/tmp/ -name genRSS.php) ]]; then  #update genRSS.php after 2 days or if no file found
        echo "Downloading latest genRSS.php:"
        curl "https://update.synology.com/autoupdate/genRSS.php" -# --output "$rss"
fi

if [[ $(find "${Script_dir}"/tmp/ -name SRS.php -mtime +7) ]] || [[ -z $(find "${Script_dir}"/tmp/ -name SRS.php) ]]; then  #update, if no file found or older than 7 days
        echo "Downloading latest SRS-list:"
        curl "https://www.synology.com/de-de/solution/SRS" -# --output "$srs"
        awk '/<div class="selected_country">Deutschland<\/div>/{f=1;next} /<div class="selected_country">Griechenland<\/div>/{f=0} f' "$srs" > "$srsde"
fi

echo -e "\nWaiting for debug-files..."

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
            DATE=$(echo "$(date +"%H%M%S") - ($(date +%S)%10)" | bc)
            unzip -q "$file" -d "$DOWNLOAD_DIR"/debug_"$DATE"
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
                        #sha=1
                        sm="$DOWNLOAD_DIR/debug_$DATE/$DSM/sm.log"
                        echo -e "Synology HA: Detected, this is the ACTIVE Server-log" >> "$sm"
                        mv "$DOWNLOAD_DIR/debug_$DATE/$DSM/ha/passive_debug.dat" "$DOWNLOAD_DIR/passive_debugfile.dat"
                    fi
                elif [[ "$file" = "$DOWNLOAD_DIR/passive_debugfile.dat" ]]; then
                    #sha=2
                    DSM=$(ls "$DOWNLOAD_DIR/debug_$DATE/tmp" )
                    DSM="tmp/${DSM}"
                    sm="$DOWNLOAD_DIR/debug_$DATE/$DSM/sm.log"
                    echo -e "Synology HA: Detected, this is the PASSIVE Server-log" >> "$sm"
                else
                    sm="$DOWNLOAD_DIR/debug_$DATE/$DSM/sm.log"
                    echo -e "No Synology HA detected" >> "$sm"
                fi
                #sm=$DOWNLOAD_DIR/debug_$DATE/$DSM/sm.log
                sg=$DOWNLOAD_DIR/debug_$DATE/$DSM/smartgrep
                hb_debug=$DOWNLOAD_DIR/debug_$DATE/$DSM/hibernation_debug.log
                DEBUG_DIR=$DOWNLOAD_DIR/debug_$DATE
                Synoinfo=$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf
                    #extract .xz packages:
                            TIMEFORMAT='Extraction of messages.xz archives took %Rsec'
                            time(
                    for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages"*.xz
                        do
                            unxz "${file}"
                        done
                                )
                            TIMEFORMAT='Extraction of kern.xz archives took %Rsec'
                            time(
                    for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/kern"*.xz
                        do
                            unxz "${file}"
                        done
                                )
                      TIMEFORMAT='Executiontime: %Rsec'

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/packages.list" ]]
                then    PACK=$DOWNLOAD_DIR/debug_$DATE/$DSM/packages.list
                        declare -a InstalledPackageArray
                        sed '1d' "${PACK}" | awk '{for(i=NF;i>1;i=i-1) printf "%s ", $i; printf "%s\n", $1}' | cut -d " " -f1 > "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/packages_ver.list
                        readarray -t "InstalledPackageArray" < "$DOWNLOAD_DIR/debug_$DATE/$DSM/packages_ver.list"
                        counter=0
                        for i in "${InstalledPackageArray[@]}"
                        do
                            aver=$(grep "^$i " "$package_versions")
                            PureVerAvailable=$(echo "${aver}" | rev | cut -d " " -f1 | rev | sed 's/\-/./g')
                            PureVerInstalled=$(grep -a "$i " "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/var/log/synopkg.log | tail -n1 | grep -aoP '(?<='$i' )\S*' | sed 's/\-/./g')
                            log "${InstalledPackageArray[$counter]}: Installed: $PureVerInstalled vs. available: $PureVerAvailable"

                            # "gt" means "greater than"
                            version_compare_gt() {
                                ! printf "%s\n" "$@" | sort --check --version-sort &> /dev/null
                            }

                            if version_compare_gt "$PureVerAvailable" "$PureVerInstalled"; then
                                log "\e[31mUpdate for ${InstalledPackageArray[$counter]} from $PureVerInstalled to $PureVerAvailable available!\e[0m"
                                echo "Update for ${InstalledPackageArray[$counter]} from $PureVerInstalled to $PureVerAvailable available!" >> "$sm"
                            elif version_compare_gt "$PureVerInstalled" "$PureVerAvailable"; then
                                log "\e[93minstalled Version later than available?!\e[0m"
                            elif [[ "$PureVerInstalled" == "$PureVerAvailable" ]] ; then
                                log "\e[32msame Version, package is up to date!\e[0m"
                            else
                                echo -ne "\e[101msome error occured: "
                                echo -e "${InstalledPackageArray[$counter]}: Installed: $PureVerInstalled vs. available: $PureVerAvailable\e[0m"
                            fi

                            counter=$((counter + 1))
                        done
                        echo -e "Third Party packages:" >> "$sm"
                        third_packages=$(grep -v "AntiVirus\|AudioStation\|Calendar\|CloudStation\|FileStation\|HyperBackup\|LogCenter\|MediaServer\|NoteStation\|PHP[0-9].[0-9]\|PhotoStation\|ProxyServer\|StorageAnalyzer\|SynoFinder\|SynologyApplicationService\|SynologyDrive\|TextEditor\|USBCopy\|VideoStation\|WebDAVServer\|CloudSync\|DownloadStation\|SurveillanceStation\|WebStation\|VPNCenter\|MariaDB\|Chat\|Git\|Node.js_4\|Perl\|ActiveBackup\|ActiveBackup-Office365\|ActiveDirectoryServer\|Apache[0-9].[0-9]\|CMS\|CardDAVServer\|DNSServer\|DiagnosisTool\|Docker\|MailClient\|MailPlus-Server\|OAuthService\|PetaSpace\|PrestoServer\|PythonModule\|SSOServer\|SnapshotReplication\|Spreadsheet\|SynologyMoments\|Virtualization\|iTunesServer\| enabled\|TimeBackup\|Java7\|Java8\|exFAT\|PDFViewer\|MailStation\|phpMyAdmin\|total [[:digit:]]\{,3\}" "$PACK")
                        if [ -z "$third_packages" ]; then
                            echo "No Third Party Packages found." >> "$sm"
                            else
                            echo "$third_packages" >> "$sm"
                        fi
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/df.result" ]]
                then    DF=$DOWNLOAD_DIR/debug_$DATE/$DSM/result/df.result
                        full_number=$(awk '0+$5 >= 90 { count++ } END{print 0+count}' "$DF")
                        if [[ "$full_number" -gt 0 ]]
                        then
                            echo -en "\nMountpoints more than 90% full: (""$full_number"")" >> "$sm"
                            awk '0+$5>90 { printf "\n%s",$0 }' "$DF" >> "$sm"
                            echo -n "Mountpoints more than 90% full: (""$full_number"")" >> "$sg"
                            awk '0+$5>90 { printf "\n%s",$0 }' "$DF" >> "$sg"
                        else
                            echo -n "Mountpoints more than 90% full: (""$full_number"")" >> "$sg"
                            #echo " No full Mountpoints found." >> "$sm"
                            echo " No full Mountpoints found." >> "$sg"
                        fi
                        echo -e "\n"  >> "$sg"
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/proc/mdstat" ]]
                then    MDSTAT=$DOWNLOAD_DIR/debug_$DATE/$DSM/proc/mdstat
                        cat "$MDSTAT" >> "$sg"
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/bash_history.log" ]]
                then    Bash_history=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/bash_history.log
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/proc/mounts" ]]
                then    MOUNTS=$DOWNLOAD_DIR/debug_$DATE/$DSM/proc/mounts
                        echo -e "\nMountpoints:" >> "$sg"
                        cat "$MOUNTS" >> "$sg"
                        echo -e " \n"  >> "$sg"
                        echo -e "\nMountpoints:" >> "$sm"
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
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/usr/syno/etc/synoservice.override/ntpd-server.cfg" ]]
                then    ntpd_server_cfg=$DOWNLOAD_DIR/debug_$DATE/$DSM/usr/syno/etc/synoservice.override/ntpd-server.cfg
                        echo -n "NTP-Server: " >> "$hb_debug"
                        ntp_server_enabled=$(grep -c yes "$ntpd_server_cfg")
                        if [ "$ntp_server_enabled" -gt 0 ]
                            then echo "NTP-Server on NAS enabled." >> "$hb_debug"
                        elif [ "$ntp_server_enabled" -eq 0 ]
                            then echo "NTP-Server on NAS disabled." >> "$hb_debug"
                        fi
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/hostname" ]]
                then    Hostname=$(cat "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/hostname")
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/usr/syno/etc/synorelayd/synorelayd.conf" ]]
                then    QuickConnect_alias=$(grep '"alias"' "$DOWNLOAD_DIR/debug_$DATE/$DSM/usr/syno/etc/synorelayd/synorelayd.conf" | sed "s/.*: //" | sed 's/\"//g')
                if [[ -z "$QuickConnect_alias" ]]; then
                    QuickConnect_echo="No QuickConnect alias is set"
                    echo "QuickConnect disabled" >> "$hb_debug"
                    else QuickConnect_echo="QuickConnect Hostname: ""$QuickConnect_alias"".quickconnect.to"
                    echo "QuickConnect enabled" >> "$hb_debug"
                fi
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages" ]]
                then    MESSAGES=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages.log
                        mv "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages" "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages.log"
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/ddns.conf" ]]
                then    ddns=$(grep -c "service=true" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/etc/ddns.conf)
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
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/uptime.result" ]]
                then    UPTIME=$(cat "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/uptime.result)
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/hibernation.log" ]]
                then    HB=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/hibernation.log
                # find if NAS is LDAP-Client
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


                if [ "${#SMART_FILES[@]}" -ne "0" ]; then
                log "altsmart#: ${#SMART_FILES[@]}"
                fi
                if [ "${#SMART_neu[@]}" -ne "0" ]; then
                        tar xf "${SMART_neu[-1]}" -C "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/"
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
                    echo "No Smart-files found."
                fi

                counter=0
                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/smart"*.result
                do
                    [[ -e "$file" ]] || break #no smart-files
                    counter=$((counter + 1))
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
                echo -e "\n$counter HDDs:" >> "$sm"
                if [ -z "${BadSector_sum+x}" ]; then
                    echo "Reallocated_Sector_Ct: error" >> "$sm"
                    else
                    echo "Reallocated_Sector_Ct:" "$BadSector_sum" >> "$sm"
                fi
                if [ -z "${PendingSectors_sum+x}" ]; then
                    echo "Current_Pending_Sector: error" >> "$sm"
                    else
                    echo "Current_Pending_Sector:" "$PendingSectors_sum" >> "$sm"
                fi
                if [ -z "${OfflineUncorrectable_sum+x}" ]; then
                    echo "Offline_Uncorrectable: error" >> "$sm"
                    else
                    echo "Offline_Uncorrectable:" "$OfflineUncorrectable_sum" >> "$sm"
                fi

                #hdd-compatibility:
                UpnpModel=$(grep -i "upnpmodelname" "$Synoinfo" | cut -d "\"" -f2)
                if [[ -f "${Script_dir}/comp/${UpnpModel}_hdds_compatible.json" ]]; then
                    comp_list="${Script_dir}/comp/${UpnpModel}_hdds_compatible.json"
                    log "\e[32mCompatibility-list for ${UpnpModel} found and set. ($comp_list)\e[0m"
                else
                    echo "\e[31mCompatibility-list for ${UpnpModel} not found! should be ${Script_dir}/comp/${UpnpModel}_hdds_compatible.json\e[0m"
                fi

                if [[ -f "${Script_dir}/comp/${UpnpModel}_hdds_incompatible.json" ]]; then
                    incomp_list="${Script_dir}/comp/${UpnpModel}_hdds_incompatible.json"
                    log "\e[32mIncompatibility-list for ${UpnpModel} found and set. ($incomp_list)\e[0m"
                else
                    echo "\e[31mIncompatibility-list for ${UpnpModel} not found! should be ${Script_dir}/comp/${UpnpModel}_hdds_incompatible.json\e[0m"
                fi

                #declare -a PowerOnHours
                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/smart"*.result
                do
                    [[ -e "$file" ]] || break #no smart-files
                    hddname=$(basename -- "$file")
                    hddname2=$(grep -i "Model Family\|Device Model" "$file" | cut -d " " -f7-20 | sed -r 's/\"/Inch/' | xargs )
                    modelname=$(grep -i "Device Model" "$file" | cut -d " " -f8 | sed -r 's/\"/Inch/' | xargs ) #evtl f7-20
                    modelname_hdd_size=$(grep -i "User Capacity" "$file" | awk -F '[][]+' 'NF && !/\[\[/{print $2}' | sed 's/\..* //' | sed 's/\.* //' ) # i.e.: 3TB or 500GB
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
                    PoH=$(grep -iE "Power(_|-)on_Hours" "$file" | sed -e "s/ ([^()]*)//g" | rev | cut -d " " -f1 | rev | sed 's/h.*//' )
                    echo "${PoH}" >> "$sm"
                    echo -n "Last Extended SMART-Test: " >> "$sm"
                    LastSmartTest=$(grep -i -m1 "Extended Offline" "$file" | sed -n '/Extended offline/s/ \+/ /gp' | cut -d " " -f9 )
                    LastSmartResult=$(grep -i -m1 "Extended Offline" "$file" | sed -n '/Extended offline/s/ \+/ /gp' | cut -d " " -f5-7 )
                    re='^[0-9]+$'
                    if ! [[ "${LastSmartTest}" =~ $re ]] ; then
                    LastSmartTest=$(grep -i -m1 "Extended Offline" "$file" | sed -n '/Extended offline/s/ \+/ /gp' | cut -d " " -f8 )
                    LastSmartResult=$(grep -i -m1 "Extended Offline" "$file" | sed -n '/Extended offline/s/ \+/ /gp' | cut -d " " -f4-5 )
                    fi
                    if [[ -z "${LastSmartTest}" ]]; then
                    echo -n "never, " >> "$sm"
                    elif [[ -z "${LastSmartTest+x}" ]]; then
                    echo "error"
                        else
                        LastSmartExpr=$(expr "${PoH}" - "${LastSmartTest}" )
                        #log "expr: $PoH und $LastSmarttest"
                        echo -n "$LastSmartExpr" "hours ago, " >> "$sm"
                        echo -n "$LastSmartResult" >> "$sm"
                    fi
                    echo "HDD Size: $modelname_hdd_size" >> "$sm"
                done
                #mehr smart-kram
                echo -e "\n" >> "$sm"

                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/smart"*.result
                do
                    [[ -e "$file" ]] || break #no smart-files
                    grep -i "Model Family\|Device Model" "$file" >> "$sg"
                done
                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/smart"*.result
                do
                    [[ -e "$file" ]] || break #no smart-files
                {
                    echo -e "\n"
                    echo "$file"
                    grep -i "overall-health self-assessment\|Model Family\|Device Model\|Serial Number\|User Capacity\|Sector Sizes\|Rotation Rate\|ID\#\|Raw_Read_Error_Rate\|Reallocated_Sector_Ct\|Seek_Error_Rate\|Spin_Retry_Count\|Calibration_Retry_Count\|Reallocated_Event_Count\|Current_Pending_Sector\|Offline_Uncorrectable\|UDMA_CRC_Error_Count\|Multi_Zone_Error_Rate\|Power_On_Hours\|Reallocated_Sector_Count\|Power-on_Hours\|Program_Fail_Count_(total)\|Erase_Fail_Count_(total)\|Runtime_Bad_Count_(total)\|Uncorrectable_Error_Count\|ECC_Error_Rate\|CRC_Error_Count\|POR_Recovery_Count" "$file"
                            echo " "
                            awk '/SMART Error Log Version: 1/{f=1;next} /Selective self-test flags/{f=0} f' "$file"
                    echo -e " \n \n"
                } >> "$sg"
                done

                ls -lh "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/space/space_history_"*.xml >> "$DOWNLOAD_DIR/debug_$DATE/$DSM/space"
                for file in "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/space/space_history_"*.xml
                do
                    [[ -e "$file" ]] || break #no space-files
                    {
                    echo "$file"
                    cat "$file"
                    awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' "$file" | grep -v "vg" | grep -v "volume" | tr '\n' ' '  | sed 's#  #\n\n#g'
                    #cat "$file" | awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' - | grep -v "vg" | tr '\n' ' '  | sed 's#  #\n\n#g'
                    echo -e "\n \n \n \n"
                    } >> "$DOWNLOAD_DIR/debug_$DATE/$DSM/space"
                done
                SPACE_FILES="$DOWNLOAD_DIR/debug_$DATE/$DSM/space"

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/disk_log.xml" ]] && [ "$(stat --printf='%s' "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/disk_log.xml")" -gt 0 ]
                then    DiskLog="$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/disk_log.xml"
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
                                log "Error calculating RAM-Size"
                            fi
                    else
                        DS_MEM3="dmidecode not found, cannot calculate RAM-Size"
                        log "dmidecode.result not found!"

                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmesg.result" ]]
                then    Dmesg=$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmesg.result
                        #DS_MEM2=$( grep -i -m1 "Memory: " $Dmesg | sed "s/.*Memory: //" | cut -d " " -f3 )
                        Syno_bios=$( tac "$Dmesg" | grep "synobios: load" -m1 | sed 's/.*load, //' )
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/free.result" ]]
                then
                        free_mem=$( grep Mem "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print 1000+$2 }' | awk '{ split( "KB MB GB" , v ); s=1; while( $1>1000 ){ $1/=1000; s++ } print int($1) v[s] }' | sed -r 's/B//' | numfmt --from=iec | numfmt --to=iec )
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/route.result" ]]
                then    Route="$DOWNLOAD_DIR/debug_$DATE/$DSM/result/route.result"
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/kern.log" ]]
                then    KERN=$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/kern.log
                    DS_HWMODEL=$( grep -ia -m1 'syno_hw_version' "$KERN" | sed 's/.*syno_hw_version=//' | cut -d " " -f1 | sed 's/v.*$//' | sed 's/p\b/+/g') #i.e. DS213j
                    DS_MODEL=$( grep -ia -m1 '] Model:' "$KERN" | sed 's/.*: //' | sed 's/-//g' | sed 's/-//p') #i.e. DS213j
                    UpnpModel=$(grep -i "upnpmodelname" "$Synoinfo" | cut -d "\"" -f2)
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
                    #DS_SN=$( grep -i -m1 "serial number" $DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/kern.log | sed "s/.*[Ss]erial [Nn]umber//" )
                fi
                date_now=$(date +"%d. %B %H:%M:%S:")
                echo "$date_now $UpnpModel" #write to sm after this
                    #Hardware-specific things
                    if [ "$UpnpModel" = "DS216+" ]; then
                        echo "Possible BIOS-Issue: https://css.synology.com/issue/4334" >> "$sm"
                        echo "Bugged Versions are less than M.616" >> "$sm"
                        echo -e "This Machines BIOS-Version: $BIOS_V_CUT\n" >> "$sm"
                    fi
                    if [ "$UpnpModel" = "DS718+" ]; then
                        grep_cputemp=$( grep -c "<cpu_temperature> is over" "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/scemd.log" )
                        if [ "$grep_cputemp" -gt 0 ]; then
                        echo "CPU is overheating, RMA unit: https://css.synology.com/issue/11124" >> "$sm"
                        grep -i "<cpu_temperature> is over" "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/scemd.log" >> "$sm"
                        fi
                    fi
                    if [ "$UpnpModel" = "DS718+" ] || [ "$UpnpModel" = "DS918+" ] || [ "$UpnpModel" = "DS218+" ] || [ "$UpnpModel" = "DS418play" ] || [ "$UpnpModel" = "DS718+" ] || [ "$UpnpModel" = "DS918+" ] || [ "$UpnpModel" = "DS218+" ] || [ "$UpnpModel" = "DS418play" ]; then
                    {
                        echo "possible BIOS-Issue: https://css.synology.com/issue/12026"
                        echo "Update to DSM 6.1.3-15152 Update 7 to update the BIOS."
                        echo "Bug is fixed in: DS718+  M.220, DS918+  M.024, DS218+  M.124, DS418play M.310"
                        echo -e "This Machines BIOS-Version: $BIOS_V_CUT\n"
                    } >> "$sm"
                    fi

                    if grep -ia "tn40xx" "$KERN" | grep memory &> /dev/null ; then
                    echo "Known Issue with 10GbE E10G15-F1 Card detected." >> "$sm"
                    echo "See https://cssnew.synology.com/issue/5206 Issue B" >> "$sm"
                    grep -ia "tn40xx" "$KERN" | grep memory | tail -n20 >> "$sm"
                    fi

                    if grep -ia "tn40xx" "$KERN" | grep Link Up 10G &> /dev/null ; then
                    {
                    echo "Possible known Issue with 10GbE E10G15-F1 Card detected."
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
                        echo "Known Issue: https://cssnew.synology.com/issue/13942"
                        echo "[Cause] The marvell model may suffer from memory allocating issue."
                        echo "[Workaround]Add the following command to a bootup task:"
                        echo "/sbin/sysctl -w vm.min_free_kbytes=16384"
                        } >> "$sm"
                        fi
                    fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages.log" ]]
                then
                    echo "Memory Tests: " >> "$sm"
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
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/scemd.log" ]]
                then
                    grep_disktemp=$( grep -c "temperature> is over" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/var/log/scemd.log )
                        if [ "$grep_disktemp" -gt 0 ]; then
                        echo "CPU or Disk is overheating:" >> "$sm"
                        grep -ia "temperature> is over" "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/scemd.log" >> "$sm"
                        fi
                fi

                if grep -wi "$UpnpModel" "$srsde" &> /dev/null ; then
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
                cat "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/resolv.conf" >> "$sm"
                    else echo "/etc/resolv.conf not found." >> "$sm"
                fi
                echo -e "\n" >> "$sm"
                cat "$Route" >> "$IFCONFIG"
                #echo -e "\n" >> "$sm"
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
                echo "installed VERSION: " "$DSM_VERSION, $DSM_BuildVERSION"
                echo -e "\nUptime: " "$UPTIME"
                echo "Hostname: " "$Hostname"
                echo "$QuickConnect_echo"
                }  >> "$sm"
                if [ "$ddns" = 1 ]; then
                    echo -n "DDNS " >> "$sm"
                        grep "hostname" "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/ddns.conf" >> "$sm"
                fi
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf" ]]; then
                    grep -ia "supportrcpower" "$Synoinfo" >> "$sg"
                    grep -ia "enableRCPower" "$Synoinfo" >> "$sg"
                fi
                {
                echo "BIOS:" "$BIOS_V_CUT"
                #echo "SynoBIOS: " "$Syno_bios"
                echo "Hardware Version: $DS_HWMODEL and Diskstationmodel: $DS_MODEL"
                echo "UPNP Model:" "$UpnpModel"
                echo "CPU from logs:" "$DS_CPU"
                echo "Anzahl Threads: $Processor_count , Anzahl Cores: $DS_Cores"
                echo "Seriennummer:" "$DS_SN"
                echo -e 'Associated Tickets: \nhttps://cssnew.synology.com/ticket?list_type=agent_all&sort_by=update_time&sort_direction=desc&filter=%7B%22search_column%22%3A%5B%22ticket_id%22%2C%22content%22%5D%2C%22sn%22%3A%22'"$DS_SN"'%22%7D'
                echo -e "\nArbeitsspeichermodules from logs:\n$DS_MEM3 ??"
                echo -e "\nArbeitsspeicher, calced: $DS_MEM3_calc"
                echo "Arbeitsspeicher free.result: ~$free_mem"
                } >> "$sm"

                #log "$DS_MEM3_calc"
                date_now=$(date +"%d. %B %H:%M:%S: ")
                echo -e $date_now 'Associated Tickets: \nhttps://cssnew.synology.com/ticket?list_type=agent_all&sort_by=update_time&sort_direction=desc&filter=%7B%22search_column%22%3A%5B%22ticket_id%22%2C%22content%22%5D%2C%22sn%22%3A%22'"$DS_SN"'%22%7D'

                if [ -z "${UpnpModel}" ];
                then
                    echo "CPUinfo from txt: no model detected." >> "$sm"
                fi

                DS_CPU_TXTINFO=$( grep -m1 "CPU-Modell" "$CPU_FILE" )
                DS_CPU_TXT=$( grep "${UpnpModel}[[:space:]]" "$CPU_FILE" )
                DS_MEM_TXT=$( grep "${UpnpModel}[[:space:]]" "$CPU_FILE" | rev | cut -d ' ' -f1,2 |rev ) #todo: if realRAM > preinstalled then echo
                DS_MEM_TXT_byte=$( grep "${UpnpModel}[[:space:]]" "$CPU_FILE" | rev | cut -d ' ' -f1,2 |rev | tr -d ' B' | numfmt --from=iec)
                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/result/dmidecode.result" ]]
                then
                    if [ "$DS_MEM3_calc_byte" -gt "$DS_MEM_TXT_byte" ];
                    then
                        echo "More RAM installed! $DS_MEM3_calc vs $DS_MEM_TXT preinstalled" >> "$sm"
                    elif [ "$DS_MEM3_calc_byte" -eq "$DS_MEM_TXT_byte" ];
                    then
                        echo "same RAM installed as preinstalled!"  >> "$sm"
                    else
                        echo "error comparing RAM-Size"  >> "$sm"
                    fi
                fi

                log "${UpnpModel}"
                log "${UpnpModel/+/\\+}\S"
                {
                echo "CPUinfo from txt:"
                echo "$DS_CPU_TXTINFO"
                echo "$DS_CPU_TXT"
                }  >> "$sm"

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/samba/smb.share.conf" ]]
                then    SmbShares=$(grep "path=" "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/samba/smb.share.conf")
                            if [[ -z "$SmbShares" ]]; then
                                echo -e "\nNo Samba Shares found." >> "$sm"
                            else
                                echo -e "\nFound Samba-shares:\n$SmbShares" >> "$sm"
                            fi
                fi


                echo -e "\n\nExt4-/Btrfs-Errors:" >> "$sm"
                grep -i "btrfs critical\|btrfs error\|btrfs warning" "$KERN"  >> "$sm" #btrfs: BTRFS warning (device md2)
                grep -i "ext-4" "$KERN"  >> "$sm" #ext4

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
                    {
                    echo -e "\n\nimproper shutdowns:"
                    grep -i "improper shutdown" "$SYSDB" #improper shutdown
                    echo -e "\n\nVolume crashes:"
                    grep -i "was crashed" "$SYSDB" #volumecrash
                    echo -e "\n\ndegraded volumes:"
                    grep -i "degrade" "$SYSDB" #volume degraded
                    echo -e "\n\nerrors:"
                    grep -i "error" "$SYSDB" #generic Errors
                    } >> "$sm"

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/$DSM/var/log/messages.log" ]]; then
                    {
                    echo -e "\n\nDRDY found "$(grep -ia -ac "DRDY" "$MESSAGES")" times, showing last 45 lines:"
                    grep -ia -B5 -A10 "DRDY" "$MESSAGES" | tail -45
                    echo -e "\n\nmalformed database:"
                    grep -ia "database disk image is malformed" "$MESSAGES"
                    echo -e "\n\ncrashes:"
                    grep -ia "crash" "$MESSAGES"
                    echo -e "\n\nshowing ("$(grep -ac "Call Trace" "$MESSAGES")") call traces + next 25 lines:"
                    grep -a "Call Trace" "$MESSAGES" -A25
                    } >> "$sm"
                fi
                #write hibernation info:
                        echo -e "Packages interfering with Hibernation:" >> "$hb_debug"
                        hb_packages=$(grep "ActiveDirectoryServer\|AudioStation\|CloudStation\|MediaServer\|SynologyDrive\|CloudSync\|DownloadStation\|SurveillanceStation\|CMS\|Docker\|MailClient\|MailPlus\|MailPlus-Server\|PetaSpace\|Virtualization\|PDFViewer\|MailStation" "$PACK")
                        #to add: DocumentViewer?, CloudStation Server, CS ShareSync, CMS, DirectoryServer, MailServer?, Plex Media Server, Drittanbieterpakete
                        #to add: AudioStation protokollierung, Directory server
                        #DownloadStation: emule, Docker-Discourse, Docker-GitLab, Docker-LXQt, Docker-Redmine, Docker-Spree, Document Viewer
                        #Drittanbieterpakete, Asterisk, Bittorrent sync, Cloud Fleet, DVBLink-Server, Egnyte, ElephantDrive, Logitech® Medienserver, minimserver, Odoo8, OpenERP6, OpenERP7, OracleDBXE, PACS, Polkast, Symform Cloud Backup, VirtualHere, Webalizer, Wonderbox, xCloud, Zarafa, Andere Drittanbieter-Software oder Optware, z. B. SABnzbd
                        #usb-geraet angeschlossen
                        if [ -z "$third_packages" ]; then
                            echo "none." >> "$hb_debug"
                            else
                            echo "$hb_packages" >> "$hb_debug"
                        fi
                satadeepsleep=$(grep -c "satadeepsleeptimer=\"1\"" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/etc/synoinfo.conf)
                if [ "$satadeepsleep" -gt 0 ]
                        then echo -e "Hibernation enabled.\n" >> "$hb_debug"
                        else echo -e "Hibernation is disabled.\n" >> "$hb_debug"
                fi
                grep "^standbytimer" "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf" >> "$hb_debug"
                grep "enable_fan_debug" "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/synoinfo.conf" >> "$hb_debug"
                kernel_log_max=$(grep -c "kern_log_max=\"yes\"" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/etc/synoinfo.conf)
                if [ "$kernel_log_max" -gt 0 ]
                        then echo "Extended kernel logging enabled." >> "$hb_debug"
                        else echo "Extended kernel logging disabled." >> "$hb_debug"
                fi
                grep "local master" "$DOWNLOAD_DIR/debug_$DATE/$DSM/etc/samba/smb.conf" >> "$hb_debug"

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

                declare -a PicArray
                counter=0
                allpics=$(find "$DOWNLOAD_DIR/debug_${DATE}/" -type f \( -name "*.jpg" -o -name "*.png" -o -name "*.PNG"-o -name "*.JPG" \) 2>/dev/null)
                for pic in "${allpics}"
                do  PicArray["${counter}"]="${pic}"
                    counter=$((counter + 1))
                done

                sleep 0.1

                source "${Script_dir}/files/config.sh" #load OpenFiles[] Array from config.sh
                #log "Array before unsetting: ${OpenFiles[@]}"
                for i in "${!OpenFiles[@]}"; do #remove empty vars from array [@]
                    [ -n "${OpenFiles[$i]}" ] || log "OpenFiles[$i] unset, because empty!"
                    [ -n "${OpenFiles[$i]}" ] || unset "OpenFiles[$i]"
                done

                "$subl" "${OpenFiles[@]}" #open files defined in config.sh with editor

                echo -n "${subl} "
                echo -n "${subl} " > ~/last_debug.sh
                for arg in "${OpenFiles[@]}"
                    do echo -n "\"$arg\" "
                       echo -n "\"$arg\" " >> ~/last_debug.sh
                done
                echo -e "\n" #??
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
            echo -e "\n"
        fi
    done
    sleep $sleep_scan_dir
    #echo "$(date +"%H:%M:%S") Rescanning for .dat Files"
done
