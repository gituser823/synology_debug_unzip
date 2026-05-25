#!/usr/bin/env bash
#by Thomas Feldmann

#DOWNLOAD_DIR= #uncomment this and set path

ThomasModus=0
if [ "$ThomasModus" -eq 1 ]; then
 	DOWNLOAD_DIR=/home/thomas/Downloads/neu #change this to the path of the download folder or use -d "/path"
 	writeLastDebugToFile=1 	#write last debug to LastDebugFile? open with "bash ~/Dokumente/bash/last_debug.sh"
    LastDebugFile=/home/thomas/Dokumente/bash/last_debug.sh
 	verbose=1
    trap "/usr/bin/env bash" SIGINT SIGTERM #catch CTRL+C and start bash
fi


required_packages="bsdtar lftp jq sqlite3 ps unzip"
for package in $required_packages; do
    command -v "$package" > /dev/null || {
        echo "Please install $package to proceed."
        exit 1
    }
done

#debugging with times:
#N=`date +%s%N`
#export PS4='+[$(((`date +%s%N`-$N)/1000000))ms][${BASH_SOURCE}:${LINENO}]: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'; set -x;

# set bash option to avoid
# unmatched patterns expand as result values
shopt -s nullglob

sleep_scan_dir=6 #Folder rescan time in seconds
sleep_extract_zip=0.5 #rescan time for finishing download
Script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" #Scriptdirectory
DSM=dsm
CPU_FILE="${Script_dir}/tmp/CPU.txt"
rss="${Script_dir}/tmp/genRSS.php"
available_packages_pre="${Script_dir}/tmp/available_packages_pre.txt"
available_packages="${Script_dir}/tmp/available_packages.txt"
package_versions="${Script_dir}/tmp/package_versions.txt"
mkdir -p "${Script_dir}/comp"
mkdir -p "${Script_dir}/tmp"
mkdir -p "${Script_dir}/tmp/lftp"
confpath="${Script_dir}/tmp/lftp"
declare -a confs
confs=( "${confpath}/lftp_no_"{00..8}.cfg ) #increase {00..X} X to increase number of simultaneous downloads for UpdateCompatibilityLists()
ProductList="${Script_dir}/tmp/ProductList.json"
sleep_scan_dir_backup=$sleep_scan_dir

log() {
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
        (( s++ ))
    done
    echo -n "$b$d ${S[$s]}"
}

spinDot(){
  while true
  do
    echo -ne "."
    sleep 0.2
  done
}

# Converts a power_sched.conf integer value to a human-readable schedule.
# Reimplements files/power_shed.py in pure Bash (no python3 required).
decode_power_sched() {
    local val=$1
    local hex
    hex=$(printf '%07x' "$val")
    local enabled="${hex:0:1}"
    local daybyte="${hex:1:2}"
    local hour_hex="${hex:3:2}"
    local min_hex="${hex:5:2}"
    local weekdays=("Saturday" "Friday" "Thursday" "Wednesday" "Tuesday" "Monday" "Sunday")
    printf "\nPowerSchedule for %d:\n" "$val"
    if [[ "$enabled" != "0" ]]; then
        echo "Power Schedule enabled"
    else
        echo "Power Schedule disabled"
    fi
    local dayval=$((16#$daybyte))
    for i in {0..6}; do
        local bit=$(( (dayval >> (6 - i)) & 1 ))
        [[ $bit -eq 1 ]] && printf "%s:\tx\n" "${weekdays[$i]}" || printf "%s:\n" "${weekdays[$i]}"
    done
    printf "Scheduled Time: %02d:%02d\n" "$((16#$hour_hex))" "$((16#$min_hex))"
}

# Render sectioned sm.log from collected $_sm_raw + shell variables.
# Heuristically buckets lines of $_sm_raw into sections by content patterns.
render_sm_log() {
    [[ -z "${sm:-}" || -z "${_sm_raw:-}" ]] && return 0
    [[ ! -f "$_sm_raw" ]] && return 0

    local border
    border=$(printf '═%.0s' {1..80})

    # Build per-section buffers in awk by routing $_sm_raw lines
    local raw_sections
    raw_sections=$(awk -v border="$border" '
        function flush() {
            if (cur != "") buf[cur] = buf[cur] line "\n"
        }
        BEGIN {
            cur = "storage"
        }
        {
            line = $0
            lower = tolower($0)
            if (lower ~ /16 terabyte volume limitation/ ||
                l ~ /^md[0-9]/ || l ~ /extensionunits/ ||
                l ~ /mountpoints/ || l ~ /no volumes mounted/ ||
                l ~ /^\/dev/ || l ~ /dsm was migrated/ ||
                l ~ /^mountpoints more than/) cur = "storage"
            else if (lower ~ /more recent dsm version available/ ||
                     l ~ /available major updates/ || l ~ /dsm version is latest/ ||
                     l ~ /installed version:/) cur = "updates"
            else if (lower ~ /cpuinfo from txt/ || l ~ /cpu-model/ ||
                     l ~ /reallocated_sector_ct/ || l ~ /current_pending_sector/ ||
                     l ~ /offline_uncorrectable/ ||
                     l ~ /poweronhours|powerOnHours/ ||
                     l ~ /last extended smart-test/ ||
                     l ~ /^sd[a-z]+(\.result)?:/ ||
                     l ~ /^smart_/ || l ~ /^nv[a-z]/ || l ~ /^sas[0-9]/) cur = "smart"
            else if (lower ~ /ipv6 (en|dis)abled/ ||
                     l ~ /dropped packages|bugged packages/ ||
                     l ~ /^ethtool\./ ||
                     l ~ /dns servers:/ || l ~ /^nameserver/ ||
                     l ~ /quickconnect/ || l ~ /^ddns / ||
                     l ~ /samba is|nfs is|afp is/ || l ~ /samba status|nfs status|afp status/ ||
                     l ~ /network bonding/) cur = "net"
            else if (lower ~ /third party packages/ || l ~ /update for / ||
                     l ~ /found samba-shares|no samba shares/ ||
                     l ~ /lun-config|found luns|combined lun|iscsi mapping|iscsi targets/) cur = "pkgs"
            else if (lower ~ /^overview:/ || l ~ /^improper shutdowns:[\t ]+(none|[0-9])/ ||
                     l ~ /^volume crashes:[\t ]+(none|[0-9])/ ||
                     l ~ /^degraded volumes:[\t ]+(none|[0-9])/ ||
                     l ~ /^generic errs:[\t ]+(none|[0-9])/ ||
                     l ~ /^drdy:[\t ]+(none|[0-9])/ ||
                     l ~ /^database is malformed:[\t ]+(none|[0-9])/ ||
                     l ~ /^out of memory kills:[\t ]+(none|[0-9])/ ||
                     l ~ /^generic crashes:[\t ]+(none|[0-9])/ ||
                     l ~ /^call traces:[\t ]+(none|[0-9])/ ||
                     l ~ /^authentication failures:[\t ]+/ ||
                     l ~ /^btrfs qgroup warnings:[\t ]+/ ||
                     l ~ /^non-system users:[\t ]+/ ||
                     l ~ /^encrypted shares:[\t ]+/ ||
                     l ~ /^memory tests/ || l ~ /memory tests have passed/ ||
                     l ~ /no memory tests/ || l ~ /failed memtests/ ||
                     l ~ /^ext4-\/btrfs-errs:[\t ]+(none|[0-9])/) cur = "overview"
            else if (lower ~ /^docker containers seen/) cur = "docker"
            else if (lower ~ /^extended diagnostics:/ ||
                     l ~ /raid (active )?rebuild/ ||
                     l ~ /^volume layout:/ ||
                     l ~ /hdd temperature|hdd age|hdd vendor distribution/ ||
                     l ~ /btrfs scrub/ ||
                     l ~ /disk health prediction/ ||
                     l ~ /failed dpkg upgrades/ ||
                     l ~ /last dsm update activity/ ||
                     l ~ /auth failures:/ ||
                     l ~ /^ups events|^hyperbackup tasks/ ||
                     l ~ /^dsm region/ ||
                     l ~ /smart self-test schedule/ ||
                     l ~ /smart tests in history/ ||
                     l ~ /high load average|elevated load average/ ||
                     l ~ /more ram installed|same ram installed/ ||
                     l ~ /uptime: |hostname: |bios:|hardware version|upnp model|^kernel:|cpu from logs|serialnumber:|associated tickets|swap:|installed ram-modules|ram, calced|ram free.result/) cur = "extended"
            else if (lower ~ /known issue|possible known issue|^cpu is overheating|^cpu or disk is overheating/ ||
                     l ~ /^ext4-\/btrfs-errors:/ ||
                     l ~ /^improper shutdowns:$/ ||
                     l ~ /^volume crashes:$/ ||
                     l ~ /^degraded volumes:$/ ||
                     l ~ /generic errs:$/ ||
                     l ~ /database is malformed:/ && l ~ /total/ ||
                     l ~ /^drdy:/ && l ~ /total/ ||
                     l ~ /^out of memory kills:/ && l ~ /total/ ||
                     l ~ /^generic crashes:/ && l ~ /total/ ||
                     l ~ /call traces, showing/) cur = "issues"
            flush()
        }
        END {
            for (k in buf) {
                printf "===SECTION:%s===\n%s", k, buf[k]
            }
        }
    ' "$_sm_raw")

    # Compute formatted header values
    local productver buildnum smallfix dsm_full cpu_clean
    productver=$(echo "$DSM_VERSION" | grep -oE '"[^"]+"' | head -1 | tr -d '"')
    buildnum=$(echo "$DSM_BuildVERSION" | grep -oE '"[^"]+"' | head -1 | tr -d '"')
    smallfix=$(echo "$DSM_smallfixVERSION" | grep -oE '"[^"]+"' | head -1 | tr -d '"')
    dsm_full="$productver"
    [[ -n "$buildnum" ]] && dsm_full="${dsm_full}-${buildnum}"
    [[ -n "$smallfix" && "$smallfix" != "0" ]] && dsm_full="${dsm_full} Update ${smallfix}"
    cpu_clean=$(echo "$DS_CPU" | sed 's/.*:\s*//')

    # Uptime + load
    local up_str load_str
    if [[ "$UPTIME" =~ up[[:space:]]+(.*),[[:space:]]*load[[:space:]]average:[[:space:]]+(.*) ]]; then
        up_str="${BASH_REMATCH[1]}"
        load_str="${BASH_REMATCH[2]}"
    else
        up_str="$UPTIME"
        load_str=""
    fi

    # RAM
    local ram_str swap_pct
    ram_str=$(bytesToHuman $((${free_mem_kbyte:-0} * 1024)) 2>/dev/null)
    if [[ -n "$swap_total_kbyte" && "$swap_total_kbyte" -gt 0 ]]; then
        swap_pct=$(awk "BEGIN {printf \"%.2f\", ${swap_used_kbyte:-0}/${swap_total_kbyte}*100}")
        local swap_used_h swap_total_h
        swap_used_h=$(bytesToHuman $((swap_used_kbyte * 1024)))
        swap_total_h=$(bytesToHuman $((swap_total_kbyte * 1024)))
        ram_str="${ram_str}  ·  Swap: ${swap_pct}% (${swap_used_h} / ${swap_total_h})"
    fi

    # Helper to render one section
    _emit_section() {
        local key="$1" title="$2"
        local content
        content=$(awk -v key="$key" '
            /^===SECTION:/ {
                in_sec = ($0 == "===SECTION:" key "===")
                next
            }
            in_sec { print }
        ' <<< "$raw_sections")
        # Section header
        local pad=$(( 79 - ${#title} - 3 ))
        (( pad < 2 )) && pad=2
        local dashes
        dashes=$(printf '─%.0s' $(seq 1 $pad))
        echo ""
        echo "── ${title} ${dashes}"
        if [[ -z "$content" ]]; then
            return
        fi
        while IFS= read -r ln; do
            [[ -z "$ln" ]] && { echo ""; continue; }
            if [[ "$ln" =~ ^[[:space:]]{2,} ]]; then
                echo "$ln"
            else
                echo "  $ln"
            fi
        done <<< "$content"
    }

    # Write the formatted sm.log
    {
        # HA/UC prefix from raw (first non-storage routing-special lines)
        local prefix
        prefix=$(grep -m1 -E "^Synology (HA|UC): Detected" "$_sm_raw" 2>/dev/null || true)
        if [[ -n "$prefix" ]]; then
            echo "$prefix"
            echo ""
        fi

        echo "$border"
        local title_parts="${UpnpModel}"
        [[ -n "$Hostname" ]] && title_parts="${title_parts}  |  ${Hostname}"
        [[ -n "$DS_SN" ]] && title_parts="${title_parts}  |  S/N: ${DS_SN}"
        echo "  ${title_parts}"
        echo "$border"
        echo "  DSM:    ${dsm_full}"
        echo "  Kernel: ${Kernel_version}"
        local cpu_line="  CPU:    ${cpu_clean}"
        [[ -n "${Processor_count:-}" && -n "${DS_Cores:-}" ]] && \
            cpu_line="${cpu_line}  ·  ${Processor_count} Threads / ${DS_Cores} Cores"
        echo "$cpu_line"
        echo "  RAM:    ${ram_str}"
        local up_line="  Uptime: ${up_str}"
        [[ -n "$load_str" ]] && up_line="${up_line}  ·  Load: ${load_str}"
        echo "$up_line"
        [[ -n "$BIOS_V_CUT" ]] && echo "  BIOS:   ${BIOS_V_CUT}"
        [[ -n "${DS_HWMODEL:-}" || -n "${DS_MODEL:-}" ]] && \
            echo "  HW:     ${DS_HWMODEL}  ·  Model: ${DS_MODEL}"
        echo "$border"

        _emit_section "updates"  "DSM UPDATES"
        _emit_section "storage"  "STORAGE"
        _emit_section "smart"    "SMART"
        _emit_section "net"      "NETZWERK"
        _emit_section "pkgs"     "PAKETE"
        _emit_section "overview" "OVERVIEW"
        _emit_section "docker"   "DOCKER"
        _emit_section "extended" "EXTENDED DIAGNOSTICS"
        _emit_section "issues"   "PROBLEME & BEKANNTE FEHLER"
        echo "$border"
    } > "$sm"
}

convertJson() {
    while ps aux | grep -v grep | grep -q lftp ; do #wait for lftp to finish downloading
    sleep 1
    done
	printf "Converting Json-files"
	spinDot & #"..."-animation
    pid=$! #set process id to kill (spinDot)
	for file in "${Script_dir}"/comp/*.json
	do
        sed -e "s/\\\\\///g" -i "${file}" #Kingston SSDs: remove "\/"
        mv "${file}" "${file}".old
        if jq '.' "${file}".old > "${file}"; then
       		rm "${file}".old 2>/dev/null
        else
    		log "Error converting ${file}"
        fi
    done
    kill $pid #end "..."-animation
    wait $! 2>/dev/null #send Terminated message to /dev/null
    echo "done"
}


updateCPUList() {
    echo -n "Updating CPU list from Synology KB..."
    local url="https://kb.synology.com/de-de/DSM/tutorial/What_kind_of_CPU_does_my_NAS_have"
    local tmpraw
    tmpraw=$(mktemp)
    curl -s "$url" > "$tmpraw" || { echo " error: curl failed"; rm -f "$tmpraw"; return; }
    local errmsg
    errmsg=$(python3 -c "
import sys, re, json
raw = open(sys.argv[1]).read()
pos = raw.find('\"content\":')
if pos < 0:
    print('error: content key not found', file=sys.stderr); sys.exit(1)
pos += len('\"content\":')
try:
    content, _ = json.JSONDecoder().raw_decode(raw[pos:])
except Exception as e:
    print(f'error: JSON decode failed: {e}', file=sys.stderr); sys.exit(1)
rows = re.findall(r'<tr>(.*?)<\/tr>', content, re.S)
print('System Model\tCPU-Model\tCores\tThreads\tFPU\tArchitecture\tRAM')
count = 0
for row in rows:
    cells = re.findall(r'<td>(.*?)<\/td>', row, re.S)
    cells = [re.sub(r'<[^>]+>', '', c).strip() for c in cells]
    if len(cells) >= 7:
        fpu = 'Ja' if '&check;' in cells[4] or chr(10003) in cells[4] else 'Nein'
        print(f\"{cells[0]}\t{cells[1]}\t{cells[2]}\t{cells[3]}\t{fpu}\t{cells[5]}\t{cells[6]}\")
        count += 1
print(f'done ({count} models)', file=sys.stderr)
" "$tmpraw" 2>&1 >"${CPU_FILE}")
    rm -f "$tmpraw"
    echo " ${errmsg:-done}"
}

updateDSMUpdatesList() {
    	echo -en "Downloading latest genRSS.php..."
        curl "https://update.synology.com/autoupdate/genRSS.php" -s --output "$rss" #for progress add -#
        if [ "$ThomasModus" -eq 1 ]; then
        stat --printf=" Size: %s " "$rss"
    	fi
    	echo "done"
}

updateLatestPackageVersionsList() {
        lftp -c "open https://archive.synology.com/download/Package/; cls" > "${available_packages_pre}"; #download package list
        sed -i '/^enabled$/d' "${available_packages_pre}"
        echo "Number of available Packages: $(cat "${available_packages_pre}" | wc -w)"
		printf "Updating latest package Versions"
			spinDot & #"..."-animation
    		pid2=$! #set process id to kill (spinDot)
        echo "set ssl:verify-certificate false" > "${Script_dir}/tmp/lftp2.cfg"
        echo "set net:connection-limit 20" >> "${Script_dir}/tmp/lftp2.cfg"
        echo "set xfer:clobber yes" >> "${Script_dir}/tmp/lftp2.cfg"
        awk -v OFS="\\\ " '$1=$1' "${available_packages_pre}" > "${available_packages}"
        rm "${available_packages_pre}"
        declare -a "PackageArray"
        readarray -t "PackageArray" < "${available_packages}"
        #echo "Array: ${PackageArray[@]}" #package array, i.e. Java7/
        echo "" > "${package_versions}"
        for v in "${PackageArray[@]}"
        do
            echo "open https://archive.synology.com/download/Package/${v//+/%2B}/; echo -n "\""${v//\/}" \""; dir | sed \'s/.* //\' | grep -E \'^[0-9]\' | sort -V -r | head -n1" >> "${Script_dir}/tmp/lftp2.cfg"
        done
        echo "bye" >> "${Script_dir}/tmp/lftp2.cfg"
        if [[ "$verbose" == 1 ]]; then
            lftp -f "${Script_dir}/tmp/lftp2.cfg" | tee "${package_versions}"
        else
            lftp -f "${Script_dir}/tmp/lftp2.cfg" | tee "${package_versions}" 1>/dev/null
        fi
        kill $pid2 #end "..."-animation
        wait $! 2>/dev/null #send Terminated message to /dev/null
        echo "done"
}

updateCompatibilityLists() {
		echo -en "Getting available Models..."
        curl "https://www.synology.com/cgi/misc/?action=getProductList_withOEM" -s | grep -oP '(?<=\[).*(?=\])' > "$ProductList" #get all Models listed in Synology API
        echo "done"
        if [ "$ThomasModus" -eq 1 ]; then
        stat --printf="Size: %s" "$ProductList"
        fi
        IFS=","
        counter=0
        for v in $(< "$ProductList")
        do  m="${v//\"}"
            [[ "$m" == PSU\ * || "$m" == ioSafe\ * || "$m" == "Power Cord"* || "$m" == FAN\ * || "$m" == "Disk Tray"* || "$m" == "Drive Tray"* || "$m" == Adapter\ * || "$m" == CPU\ * || "$m" == Cable\ * ]] && continue
            Models["${counter}"]="$m"
            (( counter++ ))
        done
        IFS=$' \t\n'

        if [ "$ThomasModus" -eq 1 ]; then
        echo -e "\nModels: ${Models[*]}"
    	fi

        echo "Downloading In-/Compatibility-lists...done" #done is a lie, lftp continues to run in the background
        {
        echo "set ssl:verify-certificate false"
        echo "set net:connection-limit 40"
        echo "set xfer:clobber yes"
        }|tee  "${confs[@]}" 1>/dev/null
            ind=0
            for m in "${Models[@]}"
                do
                    {
                    echo 'get "https://www.synology.com/api/compatibility/findHclList?lang=en-global&tab=drives&model='"${m//+/%2B}"'&category=hdds_no_ssd_trim&recommend=t" -o "'"${Script_dir}"'/comp/'"${m}"'_hdds_compatible.json"'
                    echo 'get "https://www.synology.com/api/compatibility/findHclList?lang=en-global&tab=drives&model='"${m//+/%2B}"'&category=hdds_no_ssd_trim&recommend=f" -o "'"${Script_dir}"'/comp/'"${m}"'_hdds_incompatible.json"'
                    } >> "${confs[$ind]}"
                    if [[ "$verbose" == 1 ]]; then
                        echo "  [verbose] ${m}_hdds_compatible.json"
                        echo "  [verbose] ${m}_hdds_incompatible.json"
                    fi
                    (( ind++ ))
                    [ "$ind" -ge ${#confs[@]} ] && ind=0 #split to multiple files in confs[@]
                done
            echo "bye" |tee -a "${confs[@]}" 1>/dev/null
                for conf in "${confs[@]}";do
                    if [ "$ThomasModus" -eq 1 ]; then
                        lftp -f "$conf" &
                    else
                        lftp -f "$conf" 1>/dev/null &
                    fi
                done
}


version_compare_gt() {
        ! printf "%s\n" "$@" | sort --check --version-sort &> /dev/null
}

serviceIsEnabled () {
    name=$1
    config_file=$2

    status=$(grep auto_start "$debug_dsm/usr/syno/etc/synoservice.override/$config_file" 2>/dev/null)

    status=${status#*:}
    status=${status%%:*}
    status=${status#\"}
    status=${status%\"}

    case "$status" in
        yes)    printf "%s\n" "$name is on"
        ;;
        no)    printf "%s\n" "$name is off"
        ;;
        *)    printf "%s\n" "$name status unknown"
    esac
}

usage() {
	echo -e "Usage $(basename -- "$0"):\t[-d \"/absolute/directory/path/of/download/directory\"] [-h show help]" 1>&2; exit 1;
}

install_sublime_packages() {
    # Skip on WSL or if Sublime Text is not installed
    if grep -qE "(Microsoft|WSL)" /proc/version 2>/dev/null; then return; fi

    local base=""
    if flatpak info com.sublimehq.SublimeText &>/dev/null 2>&1; then
        base="$HOME/.var/app/com.sublimehq.SublimeText/config/sublime-text"
    elif command -v subl &>/dev/null || command -v sublime_text &>/dev/null; then
        base="$HOME/.config/sublime-text"
    else
        return
    fi

    local pkg_dir="$base/Installed Packages"
    local pkg_file="$pkg_dir/Package Control.sublime-package"
    local settings_dir="$base/Packages/User"
    local settings_file="$settings_dir/Package Control.sublime-settings"

    mkdir -p "$pkg_dir" "$settings_dir"

    if [[ ! -f "$pkg_file" ]]; then
        echo "Installing Sublime Package Control..."
        wget -q -O "$pkg_file" \
            "https://packagecontrol.io/Package%20Control.sublime-package" \
            || { echo "Package Control download failed."; rm -f "$pkg_file"; }
    fi

    if [[ ! -f "$settings_file" ]]; then
        echo '{"installed_packages": ["Log Highlight"]}' > "$settings_file"
        echo "Sublime: Log Highlight added to Package Control queue."
    elif ! grep -q "Log Highlight" "$settings_file"; then
        python3 - "$settings_file" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    data = json.loads(open(path).read())
except Exception:
    data = {}
pkgs = data.get("installed_packages", [])
if "Log Highlight" not in pkgs:
    pkgs.append("Log Highlight")
    data["installed_packages"] = pkgs
    open(path, "w").write(json.dumps(data, indent=4) + "\n")
    print("Sublime: Log Highlight added to Package Control queue.")
PYEOF
    fi
}

while getopts ":uhvd:" opt; do
  case ${opt} in
    u)
        echo "updating files:" >&2
        updateDSMUpdatesList
        updateCompatibilityLists
        updateLatestPackageVersionsList
        convertJson
        updateCPUList
    	;;
    h)
        echo -e "\navailable commandline-arguments are:\n"
        echo -e "\t-h : Show this help"
        echo -e "\t-u : Update DSM-Updates, HDD-(in-)compatibility-lists, package updates"
        echo -e "\t-v : Be Verbose"
        echo -e "\t-d : Set Download directory to scan (use absolute path) [required]"
        echo -e "\t     example: synology_debug_unzip.sh -d \"/home/thomas/Downloads/neu\""
        echo -e "\t     alternatively set variable DOWNLOAD_DIR in $(basename -- "$0")"
        echo -e "\n"
        exit 1
    	;;
    v)
        verbose=1
    	;;
    d)
		DOWNLOAD_DIR=${OPTARG}
		if [[ -d "${DOWNLOAD_DIR}" ]]; then
			echo "download directory set to ${DOWNLOAD_DIR}"
		else
			echo "${DOWNLOAD_DIR} is not a valid directory"
			exit 1
		fi
    	;;
    \?)
    	echo "Invalid option: -$OPTARG. List all options with -h" >&2
    	exit 1
    	;;
    *)
		usage
		;;
  esac
done
shift $((OPTIND-1))

if [ -z "${DOWNLOAD_DIR}" ]; then
    usage
fi

install_sublime_packages

if [[ "$(find "${Script_dir}"/tmp/ -name genRSS.php -mmin +600)" ]] || [[ -z "$(find "${Script_dir}"/tmp/ -name genRSS.php)" ]]; then  #update, if no file found or older than 10 hours
        touch "${Script_dir}/tmp/genRSS.php"
        updateDSMUpdatesList
fi

if [[ "$(find "${Script_dir}"/tmp/ -name CPU.txt -mmin +1440)" ]] || [[ -z "$(find "${Script_dir}"/tmp/ -name CPU.txt)" ]]; then  #update, if no file found or older than 24 hours
        touch "${Script_dir}/tmp/CPU.txt"
        updateCPUList
fi

if [[ "$(find "${Script_dir}"/tmp/lftp/ -name config_no_00.cfg -mmin +1440)" ]] || [[ -z "$(find "${Script_dir}"/tmp/lftp/ -name config_no_00.cfg)" ]]; then  #update, if no file found or older than 24 hours
        touch "${Script_dir}/tmp/lftp/config_no_00.cfg"
        updateCompatibilityLists
        updateLatestPackageVersionsList
        convertJson
fi


process_dat_file() {
    local file="$1"
    while [[ -f "${file}.part" ]]; do
        sleep "$sleep_extract_zip"
    done
    time(
    date_now=$(date +"%d. %B %H:%M:%S:")
            echo "$date_now found .dat-file! Timer started now"
            DATE=$(date -d @$(( $(date +%s) / 10 * 10 )) +%H%M%S)
            TIMEFORMAT=$'Extractiontime debug.dat: \t\t\t\t\t\t\t\e[36m%Rsec\e[39m'
            time(
            filetype=$(file "$file")
            if echo "$filetype" | grep "gzip";
            then
                mkdir -p "$DOWNLOAD_DIR"/debug_"$DATE"
                bsdtar xf "$file" -C "$DOWNLOAD_DIR"/debug_"$DATE"
            else
                unzip -q "$file" -d "$DOWNLOAD_DIR"/debug_"$DATE" #remove?
            fi
            )
            if [ $? -eq 0 ] # if successfully extracted
            then
                mv "$file" "$DOWNLOAD_DIR"/debug_"$DATE"
                date_now=$(date +"%d. %B %H:%M:%S:")
                echo "$date_now debug extracted to $DOWNLOAD_DIR/debug_$DATE"
                TemporaryWorkaround=0
                if [[ -d "$DOWNLOAD_DIR/debug_$DATE/root" ]]
                    then SupportFormVar=$(find "$DOWNLOAD_DIR/debug_$DATE/root/@tmp/" -maxdepth 1 -mindepth 1 -exec basename {} ';')
                        DatPresent=$(ls -l "$DOWNLOAD_DIR/debug_$DATE/root/@tmp/$SupportFormVar/"*.dat 2>/dev/null | wc -l)
                		if [[ "$DatPresent" != 0 ]]
                		then
                            if [[ -f "$DOWNLOAD_DIR/debug_$DATE/cap_debug.dat" ]]
                            then
                                log "cap_debug found"
                                else
                    			mv "$DOWNLOAD_DIR/debug_$DATE/root/@tmp/$SupportFormVar/"*.dat "$DOWNLOAD_DIR/"
                                log "rootpath, moved *.dat-files"
                                mv "$DOWNLOAD_DIR/debug_$DATE/root" "$DOWNLOAD_DIR/debug_$DATE/root_old"
                                sleep 10
                                break
                            fi
                    		else
                            	mv "$DOWNLOAD_DIR/debug_$DATE/root/@tmp/$SupportFormVar/"* "$DOWNLOAD_DIR/debug_$DATE/"
                                log "rootpath, moved all files"
                     	fi
                    log "rootpath, Var is: $SupportFormVar"
                fi
                if [[ -d "$DOWNLOAD_DIR/debug_$DATE/volumeUSB1" ]]
                    then RouterUSBShareVar=$(find "$DOWNLOAD_DIR/debug_$DATE/volumeUSB1/" -maxdepth 1 -mindepth 1 -exec basename {} ';')
                         SupportFormVar=$(find "$DOWNLOAD_DIR/debug_$DATE/volumeUSB1/$RouterUSBShareVar/@tmp/" -maxdepth 1 -mindepth 1 -exec basename {} ';')
                        if [[ "$SupportFormVar" == *"SupportFormAttach"* ]]
                		then
                            mv "$DOWNLOAD_DIR/debug_$DATE/volumeUSB1/$RouterUSBShareVar/@tmp/$SupportFormVar/"* "$DOWNLOAD_DIR/debug_$DATE/"
                			log "not breaking loop"
                			log "$DOWNLOAD_DIR/debug_$DATE"
                			sleep 10
                			sleep_scan_dir=12
                		else
                			log "dsmdir: $DOWNLOAD_DIR/debug_$DATE/volumeUSB1/dsm"
                		 for volumeUSB1Datfile in "$DOWNLOAD_DIR/debug_$DATE/volumeUSB1/$RouterUSBShareVar/@tmp/$SupportFormVar/"*.dat
    					 	do 	mv "$volumeUSB1Datfile" "$DOWNLOAD_DIR"
                            log "file: $volumeUSB1Datfile, dir: $DOWNLOAD_DIR"
    					 		sleep 2
    					 		#break 2 #break out of 2 levels of loops
    					 	done
                         	mv "$DOWNLOAD_DIR/debug_$DATE/volumeUSB1/$RouterUSBShareVar/@tmp/$SupportFormVar/"* "$DOWNLOAD_DIR/debug_$DATE/"*
                         	rm -rf "$DOWNLOAD_DIR/debug_$DATE/volumeUSB1"
                    		log "Routerpath, Vars are: $RouterUSBShareVar and $SupportFormVar"
                    		#log "breaking out of loop..."
                    		sleep 10
                    		#break
                    	fi
                    else
                    	sleep_scan_dir=$sleep_scan_dir_backup
                fi
                if [[ -d "$DOWNLOAD_DIR/debug_$DATE/volume1/@tmp/" ]]
                    then SupportFormVar=$(find "$DOWNLOAD_DIR/debug_$DATE/volume1/@tmp/" -maxdepth 1 -mindepth 1 -exec basename {} ';')
                         mv "$DOWNLOAD_DIR/debug_$DATE/volume1/@tmp/$SupportFormVar/dsm/"* "$DOWNLOAD_DIR/debug_$DATE/"
                    log "tmppath, Var is: $SupportFormVar"
                    TemporaryWorkaround=0
                    echo -e "\e[5;49;31mWarning! This is an old DSM-Versions debug. Data after 'Overview' may not be reliable.\e[0m"
                else
                	log "$DOWNLOAD_DIR/debug_$DATE/volume1/@tmp/ not detected"
                fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/packages.list" ]]
                then    DSM=""
                fi

                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/HighAvailability/ha.conf" ]]
                then
                    if [[ -f "$DOWNLOAD_DIR/debug_$DATE/HighAvailability/passive_debug.dat" ]]
                    then
                        _sm_raw="$DOWNLOAD_DIR/debug_$DATE/$DSM/_sm_raw"; : > "$_sm_raw" 2>/dev/null
                        echo -e "Synology HA: Detected, this is the ACTIVE Server-log\n" >> "$_sm_raw"
                        mv "$DOWNLOAD_DIR/debug_$DATE/HighAvailability/passive_debug.dat" "$DOWNLOAD_DIR/passive_debugfile.dat" #"$DOWNLOAD_DIR/passive_debugfile.dat"
                        sleep 2
                    fi
                fi
                if [[ "$file" = "$DOWNLOAD_DIR/passive_debugfile.dat" ]]; then #passive debug of HA-Cluster
                    DSM=dsm
                    _sm_raw="$DOWNLOAD_DIR/debug_$DATE/$DSM/_sm_raw"; : > "$_sm_raw" 2>/dev/null
                    echo -e "Synology HA: Detected, this is the PASSIVE Server-log\n" >> "$_sm_raw"
                else
                    _sm_raw="$DOWNLOAD_DIR/debug_$DATE/$DSM/_sm_raw"; : > "$_sm_raw" 2>/dev/null
                fi


                if [[ -f "$DOWNLOAD_DIR/debug_$DATE/remote.debug.dat" ]] #for UC3200
                then
                    _sm_raw="$DOWNLOAD_DIR/debug_$DATE/$DSM/_sm_raw"; : > "$_sm_raw" 2>/dev/null
                    echo -e "Synology UC: Detected, this is the ACTIVE Server-log\n" >> "$_sm_raw"
                    mv "$DOWNLOAD_DIR/debug_$DATE/remote.debug.dat" "$DOWNLOAD_DIR/passive_UC.dat"
                    sleep 2
                fi

                if [[ "$file" = "$DOWNLOAD_DIR/passive_UC.dat" ]]; then #passive debug of UC3200
                    DSM=dsm
                    _sm_raw="$DOWNLOAD_DIR/debug_$DATE/$DSM/_sm_raw"; : > "$_sm_raw" 2>/dev/null
                    echo -e "Synology UC: Detected, this is the PASSIVE Server-log\n" >> "$_sm_raw"
                else
                    _sm_raw="$DOWNLOAD_DIR/debug_$DATE/$DSM/_sm_raw"; : > "$_sm_raw" 2>/dev/null
                fi


                debug_dsm="$DOWNLOAD_DIR/debug_$DATE/$DSM"
                sg="$debug_dsm/smartgrep"
                hb_debug="$debug_dsm/hibernation_debug.log"
                sm="$debug_dsm/sm.log"
                mkdir -p "$(dirname "$_sm_raw")" 2>/dev/null
                DEBUG_DIR="$DOWNLOAD_DIR/debug_$DATE"
                if [[ -f "$debug_dsm/etc.defaults/synoinfo.conf" ]]
                then
                    Synoinfo=$debug_dsm/etc.defaults/synoinfo.conf
                elif [[ -f "$debug_dsm/etc/synoinfo.conf" ]]
                then
                    Synoinfo=$debug_dsm/etc/synoinfo.conf
                else
                    log "Synoinfo.conf not found."
                fi

                #most important variables should be set from here on

                UpnpModel=$(grep -i "upnpmodelname" "$Synoinfo" | cut -d "\"" -f2)
                UpnpModel_migrated_from=$(grep -i "upnpmodelname" "$debug_dsm/etc/synoinfo.conf" | cut -d "\"" -f2)
                    for messagefile in "$debug_dsm/var/log/messages"*.xz
                        do
                            unxz "${messagefile}"
                            cat "${messagefile%.*}" "$debug_dsm/var/log/messages" 2>/dev/null > "$debug_dsm/var/log/messages_temp"
                            mv "$debug_dsm/var/log/messages_temp" "$debug_dsm/var/log/messages"
                    	done

                    for kernfile in "$debug_dsm/var/log/kern"*.xz
                        do
                            unxz "${kernfile}"
                            cat "${kernfile%.*}" "$debug_dsm/var/log/kern.log" 2>/dev/null > "$debug_dsm/var/log/kern_temp"
                            mv "$debug_dsm/var/log/kern_temp" "$debug_dsm/var/log/kern.log"
                        done

                    for dmesgfile in "$debug_dsm/var/log/dmesg"*.xz
                        do
                            unxz "${dmesgfile}"
                            cat "${dmesgfile%.*}" "$debug_dsm/var/log/dmesg" 2>/dev/null > "$debug_dsm/var/log/dmesg_temp"
                            mv "$debug_dsm/var/log/dmesg_temp" "$debug_dsm/var/log/dmesg"
                        done

                if [[ -f "$debug_dsm/result/df.result" ]]
                then    DF=$debug_dsm/result/df.result
                        full_number=$(awk '0+$5 >= 90 { count++ } END{print 0+count}' "$DF")
                        if [[ "$full_number" -gt 0 ]]
                        then
                            echo -e "Mountpoints more than 90% full: (""$full_number"")" >> "$_sm_raw"
                            awk '0+$5>90 { printf "%s\n",$0 }' "$DF" >> "$_sm_raw"
                            echo -e "\n" >> "$_sm_raw"
                            echo -n "Mountpoints more than 90% full: (""$full_number"")" >> "$sg"
                            awk '0+$5>90 { printf "\n%s",$0 }' "$DF" >> "$sg"
                        else
                            echo "Mountpoints more than 90% full: (""$full_number"")" >> "$sg"
                            #echo " No full Mountpoints found." >> "$_sm_raw"
                            echo "No full Mountpoints found." >> "$sg"
                        fi
                        echo -e "\n"  >> "$sg"
                fi

                if [[ -f "$debug_dsm/result/du-h-d1-rootmnt.result" ]]
                then    DU="$debug_dsm/result/du-h-d1-rootmnt.result"
            			#export $DU
                fi

                #check for 16Tb Volume limitation
                for vgfile in "$debug_dsm/var/log/tune2fs/dev.vg"*".result"
                        do
                            [[ -e "$vgfile" ]] || log "No vg files found."
                            [[ -e "$vgfile" ]] || break
                            Volume_Features=$(grep -a "Filesystem features" "$vgfile")
                                if [ "$Volume_Features" ]; then
                                    Volume_x64=$(grep -a "Filesystem features" "$vgfile" | grep 64bit)
                                    if  [ "$Volume_x64" ]; then
                                        log "$(basename -- "$vgfile") has x64"
                                    else
                                        echo -e "$(basename -- "$vgfile" | cut -d '.' -f2) has 16 Terabyte Volume Limitation.\n" >> "$_sm_raw"
                                    fi
                                fi
                        done

                if [[ -f "$debug_dsm/proc/mdstat" ]]
                then    MDSTAT=$debug_dsm/proc/mdstat
                        cat "$MDSTAT" >> "$sg"
                        if grep -E 'md0' -A2 "$MDSTAT" | grep -q 'E'; then
                            grep -E 'md0' -A2 "$MDSTAT" >> "$_sm_raw"
                        fi
                        grep -E 'md[^01]' -A2 "$MDSTAT" | sed -r '/^\s*$/d' >> "$_sm_raw"
                fi
                if [[ -f "$debug_dsm/var/log/bash_history.log" ]]
                then    Bash_history=$debug_dsm/var/log/bash_history.log
                fi
                if [[ -f "$debug_dsm/proc/mounts" ]]
                then    MOUNTS=$debug_dsm/proc/mounts
                        echo -e "\nMountpoints:" >> "$sg"
                        cat "$MOUNTS" >> "$sg"
                        echo -e " \n"  >> "$sg"
                        echo -e "Mountpoints:" >> "$_sm_raw"
                        grepmounts=$(grep -i "volume" "$MOUNTS" | cut -f1 -d",")
                        grepmounts_c=$(grep -i -c "volume" "$MOUNTS" | cut -f1 -d",")
                        if [ "$grepmounts_c" -ne 0 ]
                            then echo "$grepmounts" >> "$_sm_raw"
                        else echo "No Volumes mounted." >> "$_sm_raw"
                        fi

                fi

                if [[ -f "$debug_dsm/result/ifconfig.result" ]]
                then    IFCONFIG=$debug_dsm/result/ifconfig.result
                    ipv6_enabled=$(grep eth -A7 "$IFCONFIG" | grep -c "inet6 addr")
                    declare -a ifc_dropped
                    ifc_dropped_sum=0
                    while IFS= read -r val; do
                        (( ifc_dropped_sum += val ))
                    done < <(grep "dropped" "$debug_dsm/result/ifconfig.result" | sed 's/.*dropped://' | cut -d " " -f1)

                    ifc_error_sum=0
                    while IFS= read -r val; do
                        (( ifc_error_sum += val ))
                    done < <(grep "errors" "$debug_dsm/result/ifconfig.result" | sed 's/.*errors://' | cut -d " " -f1)
                fi
                if [[ -f "$debug_dsm/etc/ntp.conf" ]]
                then    ntp=$debug_dsm/etc/ntp.conf
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

                serviceIsEnabled NTPServer ntpd-server.cfg  >> "$hb_debug"

                if [[ -f "$debug_dsm/etc/hostname" ]]
                then    Hostname=$(cat "$debug_dsm/etc/hostname")
                fi
                if [[ -f "$debug_dsm/usr/syno/etc/synorelayd/synorelayd.conf" ]]
                then    QuickConnect_alias=$(grep '"alias"' "$debug_dsm/usr/syno/etc/synorelayd/synorelayd.conf" | sed "s/.*: //" | sed 's/\"//g')
                if [[ -z "$QuickConnect_alias" ]]; then
                    QuickConnect_echo="No QuickConnect alias is set"
                    echo "QuickConnect on NAS is off." >> "$hb_debug"
                    else QuickConnect_echo="QuickConnect Hostname: ""$QuickConnect_alias"".quickconnect.to"
                    echo "QuickConnect on NAS is on." >> "$hb_debug"
                fi
                fi
                if [[ -f "$debug_dsm/var/log/messages" ]]
                then    MESSAGES=$debug_dsm/var/log/messages.log
                        mv "$debug_dsm/var/log/messages" "$debug_dsm/var/log/messages.log"
                fi
                if [[ -f "$debug_dsm/etc/ddns.conf" ]]
                then    ddns=$(grep -c "service=true" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/etc/ddns.conf)
                    if [[ $ddns = 1 ]]; then
                        echo "DDNS on NAS is on." >> "$hb_debug"
                    fi
                    if [[ $ddns = 0 ]]; then
                        echo "DDNS on NAS is off." >> "$hb_debug"
                    fi
                fi

                #Analyze ExtensionUnits
                ExtCt=0
                echo "ExtensionUnits:" >> "$_sm_raw"
                OIFS=$IFS
                IFS=","
                for pmfile in "$debug_dsm/sys/class/scsi_host/host"*"/syno_pm_info"
                        do
                            [[ -e "$pmfile" ]] || log "$pmfile not found."
                            [[ -e "$pmfile" ]] || break
                            ExtensionHdds=$(grep -a "syno_device_list" "$pmfile" | tr '\0' '\n' | cut -d "\"" -f2 | sed 's/\/dev\///g' )
                            ExtensionHddsLoopArray=("$ExtensionHdds")
                            for ((i=0; i<${#ExtensionHddsLoopArray[@]}; ++i))
                            do
                                if [ -n "${ExtensionHddsArray[$i]}" ]; then
                                    ExtensionHddsArray=("${ExtensionHddsArray[@]}" "${ExtensionHddsLoopArray[i]}")
                                fi
                            done
                            ExtensionUnit=$(grep "Unique" "$pmfile" | cut -d "\"" -f2)
                            if [ -n "$ExtensionUnit" ]; then
                                echo "$ExtensionUnit with $ExtensionHdds" >> "$_sm_raw"
                                echo "$ExtensionUnit:$ExtensionHdds" >> "$debug_dsm/Ext_plain"
                                (( ExtCt++ ))
                            fi
                        done
                IFS=$OIFS
                if [ "$ExtCt" -eq 0 ]; then
                    echo "none" >> "$_sm_raw"
                fi

                if [ "$UpnpModel_migrated_from" != "$UpnpModel" ]; then
                    echo "DSM was migrated from $UpnpModel_migrated_from to $UpnpModel" >> "$_sm_raw"
                fi

                log "ExtensionHDDs: $ExtensionHdds"
                if [[ -f "$debug_dsm/result/uptime.result" ]]
                then    UPTIME=$(cat "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/uptime.result)
                fi
                if [[ -f "$debug_dsm/var/log/hibernation.log" ]]
                then    HB=$debug_dsm/var/log/hibernation.log
                fi

                declare -a SMART_FILES
                SMART_FILES=( "${DOWNLOAD_DIR}/debug_${DATE}/${DSM}/result/sd"* )

                declare -a SMART_neu
                SMART_neu=( "${DOWNLOAD_DIR}/debug_${DATE}/${DSM}/var/log/smart_result/"*.txz )


                if [ "${#SMART_FILES[@]}" -ne "0" ]; then
                log "altsmart#: ${#SMART_FILES[@]}"
                fi
                if [ "${#SMART_neu[@]}" -ne "0" ]; then
                        tar xf "${SMART_neu[*]: -1}" -C "$debug_dsm/result/"
                        #oder: tar xf "${SMART_neu[*]: -2:1}" -C "$debug_dsm/result/"
                        #tar xf "${SMART_neu[-1]}" -C "$debug_dsm/result/" #geht!
                        smarttar=$(ls "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/var/log/smart_result/ 2>/dev/null)
                        for smarttarfile in "$debug_dsm/result/var/log/smart_result/$smarttar/"*
                        do
                            [[ -e "$smarttarfile" ]] || break #no smart-files
                            filename=$(basename -- "$smarttarfile")
                            mv "smarttar$file" "$debug_dsm/result/sd_$filename".result
                            #mv "$file" "$debug_dsm/result/sd_$filename".result
                        done
                        SMART_FILES=( "${DOWNLOAD_DIR}/debug_${DATE}/${DSM}/result/sd"*.result )
                        log "neusmart#: ${#SMART_FILES[@]}"
                else
                    log "No new Smart-files found."
                fi

                counter=0
                declare -a BadSectors_HDD_Array
                declare -a PendingSectors_HDD_Array
                declare -a OfflineUncorrectable_HDD_Array
                smartResultfile="
                " #remove?
                #for file in "$debug_dsm/result/smart"{sd,nv,sas}*
                for smartResultfile in "$debug_dsm/result/"{sd,smart,nv,sas[0-9]}*
                do
                    [[ -e "$smartResultfile" ]] || break #no smart-files
                    (( counter++ ))
                    declare -a BadSectors
                    declare -a PendingSectors
                    declare -a OfflineUncorrectable
                    BadSectors=$(grep -i "Reallocated_Sector_Ct\|Reallocated_Sector_Count" "$smartResultfile" | awk '{print 0+$10 }')
                    PendingSectors=$(grep -i "Current_Pending_Sector" "$smartResultfile" | awk '{print 0+$10 }')
                    OfflineUncorrectable=$(grep -i "Offline_Uncorrectable\|Uncorrectable_Error_Count\|Off-Line_Scan_Uncorrectable_Sector_Count" "$smartResultfile" | awk '{print 0+$10 }')

                    if [ "${BadSectors[@]}" -gt 0 ] 2>/dev/null; then
                        BadSectors_HDD_Array+=$(basename -- "$smartResultfile ")
                    fi
                    if [ "${PendingSectors[@]}" -gt 0  ] 2>/dev/null; then
                        PendingSectors_HDD_Array+=$(basename -- "$smartResultfile ")
                    fi
                    if [ "${OfflineUncorrectable[@]}" -gt 0 ] 2>/dev/null ; then
                        OfflineUncorrectable_HDD_Array+=$(basename -- "$smartResultfile ")
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

                if [ -z "${UpnpModel}" ]; then
                    echo "CPUinfo from txt: no model detected." >> "$_sm_raw"
                fi

                log "${UpnpModel}"
                #log "${UpnpModel/+/\\+}\S"
                DS_CPU_TXTINFO=$( grep -m1 "CPU-Model" "$CPU_FILE" )
                DS_CPU_TXT=$( grep -i "${UpnpModel}[[:space:]]" "$CPU_FILE" )
                {
                echo -e "\nCPUinfo from txt:"
                echo "$DS_CPU_TXTINFO"
                echo -e "$DS_CPU_TXT\n"
                }  >> "$_sm_raw"

                #echo -e "\nUPNP Model: $UpnpModel\n$counter HDDs:" >> "$_sm_raw"
                if [ -z "${BadSector_sum+x}" ]; then
                    echo "Reallocated_Sector_Ct: error" >> "$_sm_raw"
                    elif [[ "${BadSector_sum}" -eq 0 ]]; then
                    echo "Reallocated_Sector_Ct: 0" >> "$_sm_raw"
                    else
                    echo "Reallocated_Sector_Ct:" "$BadSector_sum on ${BadSectors_HDD_Array[@]}" >> "$_sm_raw"
                fi
                if [ -z "${PendingSectors_sum+x}" ]; then
                    echo "Current_Pending_Sector: error" >> "$_sm_raw"
                    elif [[ "${PendingSectors_sum}" -eq 0 ]]; then
                    echo "Current_Pending_Sector: 0" >> "$_sm_raw"
                    else
                    echo "Current_Pending_Sector:" "$PendingSectors_sum on ${PendingSectors_HDD_Array[@]}" >> "$_sm_raw"
                fi
                if [ -z "${OfflineUncorrectable_sum+x}" ]; then
                    echo "Offline_Uncorrectable: error" >> "$_sm_raw"
                    elif [[ "${OfflineUncorrectable_sum}" -eq 0 ]]; then
                    echo "Offline_Uncorrectable: 0" >> "$_sm_raw"
                    else
                    echo "Offline_Uncorrectable:" "$OfflineUncorrectable_sum on ${OfflineUncorrectable_HDD_Array[@]}" >> "$_sm_raw"
                fi


                for smartResultfile in "$debug_dsm/result/"{sd,nv,smart,sas[0-9]}*
                do
                    [[ -e "$smartResultfile" ]] || break #no smart-files
                    hddname=$(basename -- "$smartResultfile")
                    hddname2=$(grep -i "Model Family\|Device Model" "$smartResultfile" | cut -d " " -f7-20 | sed -r 's/\"/Inch/' | xargs )
                    modelname=$(grep -i "Device Model" "$smartResultfile" | cut -d " " -f8 | sed -r 's/\"/Inch/' | xargs ) #evtl f7-20
                    modelname_hdd_size=$(grep -i "User Capacity" "$smartResultfile" | awk -F '[][]+' 'NF && !/\[\[/{print $2}' ) # i.e.: 3.00TB or 500.00GB
                    SectorSize=$(grep -i "Sector Size\|Logical block size" "$smartResultfile" | cut -d ":" -f2 | sed -e 's/^[ \t]*//' | cut -d " " -f1 ) #evtl -f1,f2
                    if [[ "${modelname}" == "SSD" ]]; then #samsung SSDs!
                        modelname=$(grep -i "Device Model" "$smartResultfile" | cut -d " " -f9-10 | sed -r 's/\"/Inch/' | xargs)
                        modelname_hdd_size=$(grep -i "Device Model" "$smartResultfile" | cut -d " " -f11 | xargs)
                        modelname_first_part=$(grep -i "Device Model" "$smartResultfile" | cut -d " " -f8 | sed -r 's/\"/Inch/' | cut -d "-" -f1 )
                    modelname_first_part=$(grep -i "Device Model" "$smartResultfile" | cut -d " " -f8 | sed -r 's/\"/Inch/' | cut -d "-" -f1 ) #evtl f7-20
                    fi
                    #to add: include size of HDD/SSD
                    if [[ -z "${modelname}" ]]; then
                        modelname=$(grep -i "Device Model" "$smartResultfile" | cut -d " " -f7 | sed -r 's/\"/Inch/' | xargs )
                        modelname_first_part=$(grep -i "Device Model" "$smartResultfile" | cut -d " " -f7 | sed -r 's/\"/Inch/' | cut -d "-" -f1)
                    fi

                    #for SAS in FS2017
                    if [[ -z "${modelname}" ]]; then
                        modelname=$(grep -i "Product" "$smartResultfile" | cut -d ":" -f2 | xargs )
                        hddname2=$(grep -i "Vendor:\|Product:" "$smartResultfile" | cut -d ":" -f2 | xargs )
                    fi

                    #Samsung SSDs
                    if [[ -z "${modelname}" ]]; then
                        filename=$(basename -- "$smartResultfile")
                        model_file=$(echo "$filename" | cut -d "." -f1 | rev | cut -d "_" -f1 | rev)
                        modelname=$(grep -i "$model_file" "$debug_dsm/var/log/disk_overview.xml" -m1 | cut -d "\"" -f2 | awk -F 'SSD ' '{print $2 }' | xargs)
                        hddname2=$(grep -i "$model_file" "$debug_dsm/var/log/disk_overview.xml" -m1 | cut -d "\"" -f2 | xargs )
                    fi

                    UpnpModelCASE=${UpnpModel/rp/RP}

                    if [ "$ExtCt" -gt 0 ]; then
                        hddprefix_base=$(basename -- "$smartResultfile")
                        hddprefix=${hddprefix_base%_*}
                        {
                        log "prefix: $hddprefix for $smartResultfile"
                        } >&3
                        if grep -q "$hddprefix" "$debug_dsm/Ext_plain"; then
                            ExtensionUnit_plain=$(grep "$hddprefix" "$debug_dsm/Ext_plain" |cut -d':' -f1)
                            UpnpModelCASE=${ExtensionUnit_plain/rp/RP}
                            #log "checked Extensions, plain: $ExtensionUnit_plain"
                        fi
                    fi

                    #hdd-compatibility:
                    if [[ -f "${Script_dir}/comp/${UpnpModelCASE}_hdds_compatible.json" ]]; then
                        comp_list="${Script_dir}/comp/${UpnpModelCASE}_hdds_compatible.json"
                        {
                        #log "\e[32mCompatibility-list for ${UpnpModelCASE} found and set. ($comp_list)\e[0m"
                        log " "
                        } >&3
                    else
                        echo -e "\e[31mCompatibility-list for ${UpnpModelCASE} not found! should be ${Script_dir}/comp/${UpnpModelCASE}_hdds_compatible.json\e[0m"
                        echo -e "Compatibility-list for ${UpnpModelCASE} not found! should be ${Script_dir}/comp/${UpnpModelCASE}_hdds_compatible.json\nTHE FOLLOWING COMPATIBILITY RESULTS ARE WRONG:" >> "$_sm_raw"
                    fi

                    if [[ -f "${Script_dir}/comp/${UpnpModelCASE}_hdds_incompatible.json" ]]; then
                        incomp_list="${Script_dir}/comp/${UpnpModelCASE}_hdds_incompatible.json"
                        {
                        #log "\e[32mIncompatibility-list for ${UpnpModelCASE} found and set. ($incomp_list)\e[0m"
                        log " "
                        } >&3
                    else
                        echo -e "\e[31mIncompatibility-list for ${UpnpModelCASE} not found! should be ${Script_dir}/comp/${UpnpModelCASE}_hdds_incompatible.json\e[0m"
                        echo -e "Incompatibility-list for ${UpnpModelCASE} not found! should be ${Script_dir}/comp/${UpnpModelCASE}_hdds_incompatible.json\nTHE FOLLOWING COMPATIBILITY RESULTS ARE WRONG:" >> "$_sm_raw"
                    fi

                    if [[ -z "${modelname}" ]]; then
                        HDDComp=""
                        {
                        log "\e[31mHDD-Comp: Modelname empty!\e[0m"
                        } >&3
                    elif grep "${modelname}" "${incomp_list}" &> /dev/null; then
                        HDDComp="(incompatible)"
                        jq_found=$(jq '.list[] | {model_number: .model_number, recognized_name: .dsm_recognized_name}' "${incomp_list}" | grep "${modelname}")
                        {
                        log "\"\e[1;31m${modelname}\e[0m\" found in ${incomp_list##*/}"
                        log "jq: $jq_found"
                        } >&3
                    elif grep "${modelname//-/ - }" "${incomp_list}" &> /dev/null; then
                        HDDComp="(incompatible)"
                        jq_found=$(jq '.list[] | {model_number: .model_number, recognized_name: .dsm_recognized_name}' "${incomp_list}" | grep "${modelname//-/ - }")
                        {
                        log "$\"\e[32m${modelname//-/ - }\e[0m\" found in ${incomp_list##*/}"
                        log "jq: $jq_found"
                        } >&3
                    elif grep  "${modelname}" "${comp_list}" &> /dev/null; then
                        HDDComp="(compatible)"
                        jq_found=$(jq '.list[] | {model_number: .model_number, recognized_name: .dsm_recognized_name}' "${comp_list}" | grep "${modelname}")
                        {
                        log "\"\e[32m${modelname}\e[0m\" found in ${comp_list##*/}"
                        log "jq: $jq_found"
                        } >&3
                    elif grep  "${modelname//-/ - }" "${comp_list}" &> /dev/null; then
                        HDDComp="(compatible)"
                        jq_found=$(jq '.list[] | {model_number: .model_number, recognized_name: .dsm_recognized_name}' "${comp_list}" | grep "${modelname//-/ - }")
                        {
                        log "$\"\e[32m${modelname//-/ - }\e[0m\" found in ${comp_list##*/}"
                        log "jq: $jq_found"
                        } >&3
                    elif grep  "${modelname%-*}" "${incomp_list}" &> /dev/null; then # remove part after "-"
                        HDDComp="(incompatible)"
                        jq_found=$(jq '.list[] | {model_number: .model_number, recognized_name: .dsm_recognized_name}' "${incomp_list}" | grep "${modelname%-*}")
                        {
                        log "\"\e[1;31m${modelname%-*}\e[0m\" found in ${incomp_list##*/}"
                        log "jq: $jq_found"
                        } >&3
                    elif grep  "${modelname%-*}" "${comp_list}" &> /dev/null; then # remove part after "-"
                        HDDComp="(compatible)"
                        jq_found=$(jq '.list[] | {model_number: .model_number, recognized_name: .dsm_recognized_name}' "${comp_list}" | grep "${modelname%-*}")
                        {
                        log "\"\e[32m${modelname%-*}\e[0m\" found in ${comp_list##*/}"
                        log "jq: $jq_found"
                        } >&3
                    else
                        HDDComp="(not listed)"
                        {
                        log "\e[36mHDD-Comp: \"${modelname}\" not found.\e[0m"
                        } >&3
                    fi

                    PoH=$(grep -iE "Power(_|-)on(_|-)(Hours|Hour_Count|Time)" "$smartResultfile" | sed -e "s/ ([^()]*)//g" | rev | cut -d " " -f1 | rev | sed 's/h.*//' )
                    echo -e "$hddname: $hddname2\t$HDDComp: PowerOnHours: ${PoH}" #>> "$_sm_raw"
                    echo -n "Last Extended SMART-Test: " #>> "$_sm_raw"
                    LastSmartTest=$(grep -i -m1 "Extended Offline" "$smartResultfile" | sed -n '/Extended offline/s/ \+/ /gp' | rev | cut -d " " -f2 | rev )
                    LastSmartResult=$(grep -i -m1 "Extended Offline" "$smartResultfile" | sed -n '/Extended offline/s/ \+/ /gp' | sed 's/[^0-9]*[0-9] *//' | sed 's/ [0-9].*$//' | sed 's/^Extended offline //' )
                    re='^[0-9]+$'
                    if ! [[ "${LastSmartTest}" =~ $re ]] ; then
                    LastSmartTest=$(grep -i -m1 "Extended Offline" "$smartResultfile" | sed -n '/Extended offline/s/ \+/ /gp' | cut -d " " -f8 )
                    LastSmartResult=$(grep -i -m1 "Extended Offline" "$smartResultfile" | sed -n '/Extended offline/s/ \+/ /gp' | cut -d " " -f4-8 )
                    fi
                    if [[ -z "${LastSmartResult}" ]]; then
                    LastSmartResult=$(grep -i -m1 "Background long" "$smartResultfile" | sed -e 's/^.*Background long\s\{3,\}//' | cut -d " " -f1-4 | sed -e 's/[[:space:]]*$//' ) #for sas hdds
                        if [[ -n "${LastSmartResult}" ]]; then #if LastSmartResult was successfully set by previous command
                            LastSmartTest="sas-drive"
                            CalculatePoH=0
                        fi
                    fi

                    if [[ -z "${LastSmartTest}" ]]; then
                    echo -n "never"
                    elif [[ -z "${LastSmartTest+x}" ]]; then
                    echo -n "error"
                    else
                        if [[ "$CalculatePoH" != 0 ]];then
                            LastSmartExpr=$(expr "${PoH}" - "${LastSmartTest}" )
                            echo -n "$LastSmartExpr hours ago" #>> "$_sm_raw"
                        else
                            echo -n "unknown when run" #>> "$_sm_raw"
                        fi
                    fi
                    if [[ -n "${LastSmartResult}" ]]; then
                        echo -n ", $LastSmartResult" #>> "$_sm_raw"
                    fi
                    if [[ -n "${SectorSize}" ]]; then
                        echo -n ", Sectors: $SectorSize" #>> "$_sm_raw"
                    fi
                    echo ", Size: $modelname_hdd_size" #>> "$_sm_raw"
                done 3>&1 > >(column -t -s$'\t' >> "$_sm_raw") | cat
                #done | column -t -s$'\t' >> "$_sm_raw"
                #done 3>&1 >> "$_sm_raw" | column -t -s$'\t' >> "$_sm_raw"
                for smartfile3 in "$debug_dsm/result/"{sd,nv,sas[0-9],smart}*
                do
                    [[ -e "$smartfile3" ]] || break #no smart-files
                    grep -i "Model Family\|Device Model\|User Capacity" "$smartfile3" >> "$sg"
                done
                for smartfile4 in "$debug_dsm/result/"{sd,nv,smart}*
                do
                    [[ -e "$smartfile4" ]] || break #no smart-files
                {
                    echo -e "\n"
                    echo "$smartfile4"
                    grep -i "overall-health self-assessment\|Model Family\|Device Model\|Serial Number\|Firmware Version\|User Capacity\|Sector Sizes\|Rotation Rate\|ID\#\|Raw_Read_Error_Rate\|Reallocated_Sector_Ct\|Seek_Error_Rate\|Spin_Retry_Count\|Calibration_Retry_Count\|Reallocated_Event_Count\|Current_Pending_Sector\|Offline_Uncorrectable\|UDMA_CRC_Error_Count\|Multi_Zone_Error_Rate\|Power_On_Hours\|Reallocated_Sector_Count\|Power-on_Hours\|Program_Fail_Count_(total)\|Erase_Fail_Count_(total)\|Runtime_Bad_Count_(total)\|Uncorrectable_Error_Count\|Uncorrectable_Error_Cnt\|Off-Line_Scan_Uncorrectable_Sector_Count\|Airflow_Temperature_Cel\|ECC_Error_Rate\|CRC_Error_Count\|POR_Recovery_Count\|Percent_Lifetime_Remain" "$smartfile4"
                            echo " "
                            awk '/SMART Error Log Version: 1/{f=1;next} /Selective self-test flags/{f=0} f' "$smartfile4"
                    echo -e " \n \n"
                } >> "$sg"
                done

                for smartfile5 in "$debug_dsm/result/"{smart_sas,sas[0-9]}*
                do
                    [[ -e "$smartfile5" ]] || break #no smart-files
                {
                    echo -e "\n"
                    echo "$smartfile5"
                    grep -i "Vendor\|Product\|Revision\|Compliance\|User Capacity\|block size\|Rotation\|Form Factor\|Serial Number\|SMART support is\|Temperature Warning" "$smartfile5"
                            echo " "
                } >> "$sg"
                done

                if [[ -d "$debug_dsm/etc/space" ]]
                then ls -lh "$debug_dsm/etc/space/space_history_"*.xml >> "$debug_dsm/space.xml"

                for spaceFile in "$debug_dsm/etc/space/space_history_"*.xml
                do
                    [[ -e "$spaceFile" ]] || break #no space-files
                    {
                    echo "$(basename -- "$spaceFile")"
                    CountHDDs1=$(awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' "$spaceFile" | grep -v "vg" | grep -v "volume" | tr '\n' ' '  | sed 's#  #\n\n#g' | wc -w)
                    #CountHDDs2="$(($CountHDDs1-1))" //entfernen
                    echo -en "############################################\t#HDDs: $(($CountHDDs1-1))\t"
                    awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' "$spaceFile" | grep -v "vg" | grep -v "volume" | tr '\n' ' '  | sed 's#  #\n#g'
                    echo "SerialNumbers:"
                    awk -F '"' '/dev_path/ {print $8} /raid>/ {print $5}' "$spaceFile" | grep -v "vg" | grep -v "volume" | tr '\n' ' '  | sed 's#  #\n#g'
                    echo -e '\n'
                    #cat "$file" | awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' - | grep -v "vg" | tr '\n' ' '  | sed 's#  #\n\n#g'
                    } >> "$debug_dsm/space.xml"
                done

                for spaceHistoryFile in "$debug_dsm/etc/space/space_history_"*.xml
                do
                    [[ -e "$spaceHistoryFile" ]] || break #no space-files
                    {
                    echo "$spaceHistoryFile"
                    cat "$spaceHistoryFile"
                    CountHDDs1=$(awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' "$spaceHistoryFile" | grep -v "vg" | grep -v "volume" | tr '\n' ' '  | sed 's#  #\n\n#g' | wc -w)
                    CountHDDs2="$(($CountHDDs1-1))"
                    echo -e "#HDDs: $CountHDDs2"
                    awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' "$spaceHistoryFile" | grep -v "vg" | grep -v "volume" | tr '\n' ' '  | sed 's#  #\n\n#g'
                    #cat "$file" | awk -F '"' '/dev_path/ {print $4} /raid path/ {print $2} /raid>/ {print $5}' - | grep -v "vg" | tr '\n' ' '  | sed 's#  #\n\n#g'
                    echo -e "\n \n \n \n"
                    } >> "$debug_dsm/space.xml"
                done

                SPACE_FILES="$debug_dsm/space.xml"
                fi

                if [[ -f "$debug_dsm/var/log/disk_log.xml" ]] && [[ "$(stat --printf='%s' "$debug_dsm/var/log/disk_log.xml")" -gt 0 ]]
                then    DiskLog="$debug_dsm/var/log/disk_log.xml"
                elif [[ -f "$debug_dsm/var/log/disk.log" ]] && [[ "$(stat --printf='%s' "$debug_dsm/var/log/disk.log")" -gt 0 ]]
                then    DiskLog="$debug_dsm/var/log/disk.log"
                fi

                if [[ -f "$debug_dsm/smartgrep" ]]
                then    SMART_GREP="$debug_dsm/smartgrep"
                fi
                if [[ -f "$debug_dsm/result/dmidecode.result" ]]
                then
                    BIOS_V_CUT=$( grep -i "BIOS Information" -A5 "$debug_dsm/result/dmidecode.result" | grep -i "Version" | sed "s/.*Version: //" )
                        #DS_MEM=$( grep -A6 "Memory Device Mapped Address" $debug_dsm/result/dmidecode.result | grep "Range Size" | sed "s/.*Size: //" )
                        re='^[0-9]+$'
                        DS_MEM3=$(grep -A6 "Memory Device$" "$debug_dsm/result/dmidecode.result" | grep Size)
                        DS_MEM3_cut=$(grep -A6 "Memory Device$" "$debug_dsm/result/dmidecode.result" | grep Size | cut -d " " -f2 |  sed 's/[^0-9]*//g'| sed '/^\s*$/d' | sed ':a;N;$!ba;s/\n//g')
                            if [[ "$DS_MEM3_cut" =~ $re ]] ; then
                            DS_MEM3_calc=$(sed -nr '/^Memory Device$/,/^$/ { /^\s*Size:\s*/ { s///; /No Module/! { s/ //; s/B//; p } } }' "$debug_dsm/result/dmidecode.result" | numfmt --from=iec | awk '{ sum += $1 } END{ print sum }' | numfmt --to=iec | sed -r 's/([A-Z])/ \1B/')
                            DS_MEM3_calc_byte=$(sed -nr '/^Memory Device$/,/^$/ { /^\s*Size:\s*/ { s///; /No Module/! { s/ //; s/B//; p } } }' "$debug_dsm/result/dmidecode.result" | numfmt --from=iec | awk '{ sum += $1 } END{ print sum }')
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
                if [[ -f "$debug_dsm/result/dmesg.result" ]]
                then    Dmesg=$debug_dsm/result/dmesg.result
                        #DS_MEM2=$( grep -i -m1 "Memory: " $Dmesg | sed "s/.*Memory: //" | cut -d " " -f3 )
                        Syno_bios=$( tac "$Dmesg" | grep "synobios: load" -m1 | sed 's/.*load, //' )
                else    log "dmesg.result not found!"
                fi
                if [[ -f "$debug_dsm/result/free.result" ]]
                then
                        free_mem=$( grep Mem "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print $2 0 0 0 }' )
                        free_mem_nocomma=$( grep Mem "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print 1000+$2 }' | awk '{ split( "KB MB GB" , v ); s=1; while( $1>1000 ){ $1/=1000; s++ } print int($1) v[s] }' | sed -r 's/B//' )
                        free_mem_kbyte=$( grep Mem "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print $2 }')
                        swap_total_kbyte=$( grep Swap "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print $2 }')
                        swap_total=$( grep Swap "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print $2 0 0 0 }' )
                        swap_used_kbyte=$( grep Swap "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print $3 }')
                        swap_used=$( grep Swap "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/result/free.result | awk '{ print $3 0 0 0 }' )
                fi
                if [[ -f "$debug_dsm/result/route.result" ]]
                then    Route="$debug_dsm/result/route.result"
                fi
                if [[ -f "$debug_dsm/var/log/kern.log" ]]
                then    KERN=$debug_dsm/var/log/kern.log
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
                    Kernel_version=$( grep -m1 "Linux version" "$KERN"| awk -F 'Linux version ' '{print $2}')
                    #DS_SN=$( grep -i -m1 "serial number" $debug_dsm/var/log/kern.log | sed "s/.*[Ss]erial [Nn]umber//" )
                fi
                date_now=$(date +"%d. %B %H:%M:%S:")
                echo "$date_now $UpnpModel, S/N: $DS_SN" #write to sm after this

                if [[ -f "$debug_dsm/var/log/messages.log" ]]
                then
                    echo -ne "\nMemory Tests: " >> "$_sm_raw"
                    Passed_Memtest=$( grep -a "Memtest passed" "$MESSAGES" | sort -u | grep -c "")
                    Failed_Memtest=$( grep -a "Memtest failed" "$MESSAGES" | sort -u | grep -c "")
                    if [ "$Passed_Memtest" -gt 0 ]; then
                        echo "$Passed_Memtest" "Memory tests have passed." >> "$_sm_raw"
                        grep -a "Memtest passed" "$MESSAGES" | sort -u >> "$_sm_raw"
                    fi
                    if [ "$Failed_Memtest" -gt 0 ]; then
                        echo "Found $Failed_Memtest failed Memtests:" >> "$_sm_raw"
                        grep -a "Memtest failed" "$MESSAGES" | sort -u >> "$_sm_raw"
                    fi
                    if [[ "$Passed_Memtest" -eq 0 ]] && [[ "$Failed_Memtest" -eq 0 ]]; then #MEMTESTS
                        echo "No Memory tests have been run." >> "$_sm_raw"
                    fi
                    DSM_VERSION=$( grep "productversion" "$debug_dsm/etc.defaults/VERSION" ) #DSM Version
                    DSM_BuildVERSION=$( grep "buildnumber" "$debug_dsm/etc.defaults/VERSION" )
                    DSM_smallfixVERSION=$( grep "smallfixnumber" "$debug_dsm/etc.defaults/VERSION" )
                fi

                    #Hardware-specific things

                if [ "$UpnpModel" = "DS216+" ]; then
                    echo -e "\nPossible Known Issue: BIOS:" >> "$_sm_raw"
                    echo "Bugged Versions are less than M.616" >> "$_sm_raw"
                    echo -e "This Machines BIOS-Version: $BIOS_V_CUT" >> "$_sm_raw"
                fi

                if [ "$UpnpModel" = "DS718+" ]; then
                    grep_cputemp=$( grep -c "<cpu_temperature> is over" "$debug_dsm/var/log/scemd.log" )
                    if [ "$grep_cputemp" -gt 0 ]; then
                    echo -e "\nCPU is overheating, RMA unit:" >> "$_sm_raw"
                    grep -i "<cpu_temperature> is over" "$debug_dsm/var/log/scemd.log" >> "$_sm_raw"
                    fi
                fi

                grep_hddissue=$( grep -c "core_clear_root_int_from_queue Error Interrupt\|Issued IDENTIFY to non-existent device ?!" "$MESSAGES" )
                if [ "$grep_hddissue" -gt 0 ]; then
                    echo -e "\nKnown Issue: random HDD drops of WD or HGST HDDs, update HDD Firmware:" >> "$_sm_raw"
                    grep -ia "core_clear_root_int_from_queue Error Interrupt: PHY Decoding Error\|Issued IDENTIFY to non-existent device ?!" "$MESSAGES" >> "$_sm_raw"
                fi


                if [ "$UpnpModel" = "DS918+" ]; then
                    if version_compare_gt "M.024" "$BIOS_V_CUT"; then
                        {
                            echo -e "\nKnown Issue: BIOS:"
                            echo "Update to DSM 6.1.3-15152 Update 7 to update the BIOS."
                            echo -e "This Machines BIOS-Version: $UpnpModel $BIOS_V_CUT"
                        } >> "$_sm_raw"
                    else
                            log "installed BIOS version ĺater than M.024"
                    fi
                fi

                if [ "$UpnpModel" = "DS718+" ]; then
                    if version_compare_gt "M.220" "$BIOS_V_CUT"; then
                        {
                            echo -e "\nKnown Issue: BIOS:"
                            echo "Update to DSM 6.1.3-15152 Update 7 to update the BIOS."
                            echo -e "This Machines BIOS-Version: $UpnpModel $BIOS_V_CUT"
                        } >> "$_sm_raw"
                    else
                            log "installed BIOS version ĺater than M.220"
                    fi
                fi

                if [ "$UpnpModel" = "DS218+" ]; then
                    if version_compare_gt "M.124" "$BIOS_V_CUT"; then
                        {
                            echo -e "\nKnown Issue: BIOS:"
                            echo "Update to DSM 6.1.3-15152 Update 7 to update the BIOS."
                            echo -e "This Machines BIOS-Version: $UpnpModel $BIOS_V_CUT"
                        } >> "$_sm_raw"
                    else
                            log "installed BIOS version ĺater than M.124"
                    fi
                fi

                if [ "$UpnpModel" = "DS418play" ]; then
                    if version_compare_gt "M.310" "$BIOS_V_CUT"; then
                        {
                            echo -e "\nKnown Issue: BIOS:"
                            echo "Update to DSM 6.1.3-15152 Update 7 to update the BIOS."
                            echo -e "This Machines BIOS-Version: $UpnpModel $BIOS_V_CUT"
                        } >> "$_sm_raw"
                    else
                            log "installed BIOS version ĺater than M.310"
                    fi
                fi

                if grep -ia "tn40xx" "$KERN" | grep memory &> /dev/null ; then
                {
                echo -e "\nKnown Issue: with 10GbE E10G15-F1 Card detected."
                echo "See"
                grep -ia "tn40xx" "$KERN" | grep memory | tail -n20
                } >> "$_sm_raw"
                fi

                if grep -ia "tn40xx" "$KERN" | grep Link Up 10G &> /dev/null ; then
                {
                echo -e "\nKnown Issue: with 10GbE E10G15-F1 Card detected."
                echo "If Times are above 600s after Boot, please check SOP."
                echo "See"
                grep -ia "tn40xx" "$KERN" | grep "Link Up 10G\|Link Down" | tail -n20
                } >> "$_sm_raw"
                fi

                if grep -ia '"faulty_communication":true' "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/var/log/ha.log &> /dev/null ; then
                Issue25154Ct=$(grep -iac '"faulty_communication":true' "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/var/log/ha.log)
                echo -e "\nKnown Issue: Lots of error messages 'High system usage detected' show up under HA Manager." >> "$_sm_raw"
                echo "Showing only latest of $Issue25154Ct occurences." >> "$_sm_raw"
                echo "See" >> "$_sm_raw"
                grep -ia '"faulty_communication":true' "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/var/log/ha.log | tail -n1 >> "$_sm_raw"
                fi

                if grep -ia "btrfs_wait_pending_ordered" "$MESSAGES" &> /dev/null; then
                {
                echo -e "\nPossible Known Issue:"
                echo "After updating to DSM6.2.2, the volume might get stuck and with the specific hung task."
                grep -ia "btrfs_wait_pending_ordered" "$MESSAGES"
                } >> "$_sm_raw"
                fi

                if [ "$UpnpModel" = "DS218j" ] || [ "$UpnpModel" = "RS217" ] || [ "$UpnpModel" = "RS816" ] || [ "$UpnpModel" = "DS416j" ] || [ "$UpnpModel" = "DS416slim" ] || [ "$UpnpModel" = "DS216" ] || [ "$UpnpModel" = "DS216j" ] || [ "$UpnpModel" = "DS116" ]; then
                    grep_Issue_13942=$( grep -ca "Linux processing - Can't refill, try to allocate again in cleanup timer" "$MESSAGES" )
                    if [ "$grep_Issue_13942" -gt 0 ]; then
                    {
                        echo -e "\nKnown Issue:"
                        echo "[Cause] The marvell model may suffer from memory allocating issue."
                        echo "[Workaround]Add the following command to a bootup task:"
                        echo "/sbin/sysctl -w vm.min_free_kbytes=16384"
                    } >> "$_sm_raw"
                    fi
                fi

                if [ "$UpnpModel" = "DS715" ] || [ "$UpnpModel" = "DS1515" ] || [ "$UpnpModel" = "DS1517" ] || [ "$UpnpModel" = "DS2015xs" ] || [ "$UpnpModel" = "DS416" ] || [ "$UpnpModel" = "DS215+" ]; then
                    grep_Issue_13942=$( grep -ca "failed to alloc buffer for rx queue 2" "$MESSAGES" )
                    if [ "$grep_Issue_13942" -gt 0 ]; then
                    {
                        echo -e "\nKnown Issue:"
                        echo "[Cause] The marvell model may suffer from memory allocating issue."
                        echo "[Workaround]Add the following command to a bootup task:"
                        echo "/sbin/sysctl -w vm.min_free_kbytes=131072"
                    } >> "$_sm_raw"
                    fi
                fi


                if [[ -f "$debug_dsm/var/log/scemd.log" ]]
                then
                    grep_disktemp=$( grep -c "temperature> is over" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/var/log/scemd.log )
                        if [ "$grep_disktemp" -gt 0 ]; then
                        echo -e "\nCPU or Disk is overheating:" >> "$_sm_raw"
                        grep -ia "temperature> is over" "$debug_dsm/var/log/scemd.log" >> "$_sm_raw"
                        fi
                fi

                if [ "$ipv6_enabled" -gt 0 ]; then
                    echo "IPv6 enabled" >> "$_sm_raw"
                    echo "IPv6 on NAS is on." >> "$hb_debug"
                else echo "IPv6 disabled" >> "$_sm_raw"
                     echo "IPv6 on NAS is off." >> "$hb_debug"
                fi
                echo "found ${ifc_dropped_sum} dropped Packages in ifconfig.result." >> "$_sm_raw"
                echo "found ${ifc_error_sum} bugged Packages in ifconfig.result." >> "$_sm_raw"
                for ethFile in "$debug_dsm/result/"{ethtool.eth,ethtool.bond}*.result
                do
                    [[ -e "$ethFile" ]] || break  # handle the case of no *.result files
                    ethresult=$(grep "Speed" -H "$ethFile")
                    echo "${ethresult#$debug_dsm/result/}" >> "$_sm_raw"
                done
                echo "DNS Servers:" >> "$_sm_raw"
                if [ -f "$debug_dsm/etc/resolv.conf" ]; then
                sed ':a;N;$!ba;s/\n/, /g' "$debug_dsm/etc/resolv.conf" >> "$_sm_raw"
                    else echo "/etc/resolv.conf not found." >> "$_sm_raw"
                fi
                cat "$Route" >> "$IFCONFIG"

                serviceIsEnabled Samba samba.cfg  >> "$_sm_raw"
                serviceIsEnabled Samba samba.cfg  >> "$hb_debug"
                serviceIsEnabled NFS nfsd.cfg  >> "$_sm_raw"
                serviceIsEnabled AFP atalk.cfg  >> "$_sm_raw"

                DS_upnp_v="${UpnpModel}"
                DS_upnp_unter="${DS_upnp_v}_"
                DS_upnp_plus="${DS_upnp_unter//+/%2B}"

                LatestBuildNumber=$( grep -i "$DS_upnp_plus" "$rss" | sed -e 's/<[^>]*>//g' | head -n 1 | cut -d "_" -f3 | cut -d "." -f1 ) #_plus
                DSMBuildNumber=$( grep buildnumber "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/etc.defaults/VERSION | cut -d "\"" -f2 )
                if [ "$LatestBuildNumber" -gt "$DSMBuildNumber" ]; then
                    {
                    echo "More recent DSM Version available."
                    echo "available major updates:"
                    grep -i "$DS_MODEL_plus" "$rss" | sed -e 's/<[^>]*>//g'
                    echo -e " "
                    } >> "$_sm_raw"
                else echo "DSM Version is latest!" >> "$_sm_raw"
                fi
                {
                echo "installed VERSION: " "$DSM_VERSION, $DSM_BuildVERSION, $DSM_smallfixVERSION"

                DS_MEM_TXT=$( grep "${UpnpModel}[[:space:]]" "$CPU_FILE" | rev | cut -d ' ' -f1,2 |rev )
                DS_MEM_TXT_byte=$( grep "${UpnpModel}[[:space:]]" "$CPU_FILE" | rev | cut -d ' ' -f1,2 |rev | tr -d ' B' | numfmt --from=iec)
                DS_MEM_TXT_kbyte=$( grep "${UpnpModel}[[:space:]]" "$CPU_FILE" | rev | cut -d ' ' -f1,2 |rev | tr -d ' B' | numfmt --from=iec | awk '{ number = $1 / 1024; print number }' )
                if [[ -f "$debug_dsm/result/dmidecode.result" ]]
                then
                    if [ "$DS_MEM3_calc_byte" -gt "$DS_MEM_TXT_byte" ];
                    then
                        echo "More RAM installed! $DS_MEM3_calc vs $DS_MEM_TXT preinstalled" >> "$_sm_raw"
                    elif [ "$free_mem_kbyte" -gt "$DS_MEM_TXT_kbyte" ];
                    then
                        echo "More RAM installed! $free_mem_nocomma vs $DS_MEM_TXT preinstalled" >> "$_sm_raw"
                    elif [ "$DS_MEM3_calc_byte" -eq "$DS_MEM_TXT_byte" ];
                    then
                        echo "same RAM installed as preinstalled!"  >> "$_sm_raw"
                    elif [ "$free_mem_kbyte" -eq "$DS_MEM_TXT_kbyte" ];
                    then
                        echo "same RAM installed as preinstalled!"  >> "$_sm_raw"
                    else
                        echo "error comparing RAM-Size"  >> "$_sm_raw"
                    fi
                fi

                echo "Uptime: " "$UPTIME"
                echo "Hostname: " "$Hostname"
                echo "$QuickConnect_echo"
                }  >> "$_sm_raw"
                if [ "$ddns" = 1 ]; then
                    echo -n "DDNS " >> "$_sm_raw"
                        grep "hostname" "$debug_dsm/etc/ddns.conf" >> "$_sm_raw"
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
                echo "Associated Tickets: $DS_SN"

                swap_percent_kb=$(awk "BEGIN {printf \"%.2f\n\", $swap_used_kbyte/$swap_total_kbyte*100}")
                echo -ne "\nSwap: ($swap_percent_kb%) used " >> "$_sm_raw"
                bytesToHuman "$swap_used" >> "$_sm_raw"
                echo -ne " of " >> "$_sm_raw"
                bytesToHuman "$swap_total" >> "$_sm_raw"
                echo -ne "Swap: ($swap_percent_kb%) used ">> "$hb_debug"
                bytesToHuman "$swap_used" >> "$hb_debug"
                echo -ne " of " >> "$hb_debug"
                bytesToHuman "$swap_total" >> "$hb_debug"

                if [[ -z "$DS_MEM3" ]]; then
                    log "DS_MEM3 is empty."
                else
                    echo -e "\nInstalled RAM-modules:\n$DS_MEM3"
                fi
                if [[ -z "$DS_MEM3_calc" ]]; then
                    log "DS_MEM3_calc is empty."
                else
                    echo -e "RAM, calced: $DS_MEM3_calc"
                fi
                echo -n "RAM free.result: "
                bytesToHuman "$free_mem"
                echo -e " "
                } >> "$_sm_raw"

                #log "$DS_MEM3_calc"
                date_now=$(date +"%d. %B %H:%M:%S: ")
                echo -e "$date_now Associated Tickets: $DS_SN"

                if [[ -f "$debug_dsm/etc/samba/smb.share.conf" ]]
                then    SmbShares=$(grep "path=" "$debug_dsm/etc/samba/smb.share.conf" | tr '\n' '\t')
                            if [[ -z "$SmbShares" ]]; then
                                echo -e "No Samba Shares found.\n" >> "$_sm_raw"
                            else
                                echo -e "Found Samba-shares:\n$SmbShares\n" >> "$_sm_raw"
                            fi
                fi

                if [[ -f "$debug_dsm/usr/syno/etc/iscsi_lun.conf" ]]
                then    LUNs="$debug_dsm/usr/syno/etc/iscsi_lun.conf"
                            if [[ -z "$LUNs" ]]; then
                                echo -e "\nNo LUN-Config found." >> "$_sm_raw"
                            elif [[ $(stat -c%s "$LUNs") -lt 1 ]]; then
                                echo -e "\nLUN-Config-file is empty." >> "$_sm_raw"
                            else
                                echo -e "\nFound LUNs:" >> "$_sm_raw"
                                cat "$LUNs" >> "$_sm_raw"
                                LUNSize_bytesToAdd="$(grep "bytes=" "$LUNs" | cut -d "=" -f2 | sed ':a;N;$!ba;s/\n/+/g')"
                                LUNSize_byte="$(($LUNSize_bytesToAdd))"
                                echo -en "Combined LUN Size: " >> "$_sm_raw"
                                bytesToHuman "$LUNSize_byte" >> "$_sm_raw"
                                echo -e "\n" >> "$_sm_raw"
                            fi
                fi

                if [[ -f "$debug_dsm/usr/syno/etc/iscsi_mapping.conf" ]]
                then    echo "iSCSI Mapping:" >> "$_sm_raw"
                        cat "$debug_dsm/usr/syno/etc/iscsi_mapping.conf" >> "$_sm_raw"
                fi

                if [[ -f "$debug_dsm/usr/syno/etc/iscsi_target.conf" ]]
                then    echo "iSCSI Targets:" >> "$_sm_raw"
                        cat "$debug_dsm/usr/syno/etc/iscsi_target.conf" >> "$_sm_raw"
                fi

                if [[ -f "$debug_dsm/packages.list" ]]
                then    PACK=$debug_dsm/packages.list
                        declare -a InstalledPackageArray
                        awk '{for(i=NF;i>1;i=i-1) printf "%s ", $i; printf "%s\n", $1}' "${PACK}" | tail -n +2 | cut -d " " -f1 > "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/packages_ver.list

                        #synopkgfile="$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/var/log/synopkg.log
                        if [[ -f "$debug_dsm/var/log/synopkg.log" ]]; then
                            synopkgfile="$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/var/log/synopkg.log
                            if [[ $(stat -c%s "$debug_dsm/var/log/synopkg.log") -eq 0 ]]; then #if synopkg.log is empty
                                if unxz "$debug_dsm/var/log/synopkg.log.1.xz"; then # if successfully extracted
                                    synopkgfile="$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/var/log/synopkg.log.1
                                fi
                            fi
                        fi

                        cat "$debug_dsm/packages_ver.list" > "$debug_dsm/packages_onoff.list"
                        readarray -t "InstalledPackageArray" < "$debug_dsm/packages_ver.list"
                        counter=0
                        for i in "${InstalledPackageArray[@]}"
                        do
                            #tac "$synopkgfile" | grep -ia "${InstalledPackageArray[$counter]}:" | grep -ia "start version\|stop version" | grep -ia -m1 "successfully" >> "$debug_dsm/packages_onoff.list"
                            grep -ia "${InstalledPackageArray[$counter]}" "$debug_dsm/result/syno_service.result" >> "$debug_dsm/packages_onoff.list" 2>/dev/null
                            PACK_ONOFF="$debug_dsm/packages_onoff.list"
                            aver=$(grep "^$i " "$package_versions")
                            PureVerAvailable=$(echo "${aver}" | rev | cut -d " " -f1 | rev | sed 's/\-/./g')
                            PureVerInstalled=$(grep -a "$i " "$synopkgfile" | tail -n1 | grep -aoP '(?<='$i' )\S*' | sed 's/\-/./g')
                            log "${InstalledPackageArray[$counter]}: Installed: $PureVerInstalled vs. available: $PureVerAvailable"

                            if version_compare_gt "$PureVerAvailable" "$PureVerInstalled"; then
                                log "\e[1;31mUpdate for ${InstalledPackageArray[$counter]} from $PureVerInstalled to $PureVerAvailable available!\e[0m"
                                echo "Update for ${InstalledPackageArray[$counter]} from $PureVerInstalled to $PureVerAvailable available!" >> "$_sm_raw"
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

                            (( counter++ ))
                        done
                        if [[ $counter -gt 0 ]]; then
                            echo -e "\n" >> "$_sm_raw"
                        fi

                        echo -e "Overview:" >> "$_sm_raw"
                        if [[ "$TemporaryWorkaround" = 1 ]]; then
                            echo -e "(Data may be unreliable, because of old DSM Version)" >> "$_sm_raw"
                        fi
                        echo -en "Third Party packages:" >> "$_sm_raw"
                        third_packages=$(grep -v "AntiVirus\|AudioStation\|Calendar\|CloudStation\|FileStation\|HyperBackup\|LogCenter\|MediaServer\|NoteStation\|PHP[0-9].[0-9]\|PhotoStation\|ProxyServer\|StorageAnalyzer\|SynoFinder\|SynologyApplicationService\|SynologyDrive\|TextEditor\|USBCopy\|VideoStation\|WebDAVServer\|CloudSync\|DownloadStation\|SurveillanceStation\|WebStation\|VPNCenter\|MariaDB\|Chat\|Git\|Node.js_4\|Perl\|ActiveBackup\|ActiveBackup-Office365\|ActiveDirectoryServer\|Apache[0-9].[0-9]\|CMS\|CardDAVServer\|DNSServer\|DiagnosisTool\|Docker\|MailClient\|MailPlus-Server\|OAuthService\|PetaSpace\|PrestoServer\|PythonModule\|SSOServer\|SnapshotReplication\|Spreadsheet\|SynologyMoments\|Virtualization\|iTunesServer\| enabled\|TimeBackup\|Java7\|Java8\|exFAT\|PDFViewer\|DocumentViewer\|HighAvailability\|MailServer\|MailStation\|phpMyAdmin\|synocli-disk\|synocli-file\|synocli-monitor\|synocli-net\|SynologyPhotos\|SynoOnlinePack_v2\|QuickConnect\|total [[:digit:]]\{,3\}" "$PACK")
                        if [ -z "$third_packages" ]; then
                            echo -e "\tnone" >> "$_sm_raw"
                        else
                            third_packages_count=$(echo "$third_packages" | uniq -u | wc -l)
                            echo -e "\t$third_packages_count" >> "$_sm_raw"
                        fi
                        echo -en "Ext4-/Btrfs-Errs:" >> "$_sm_raw"
                        btrfserrckern=$(grep -ia "btrfs critical\|btrfs error\|btrfs warning\|btrfs.*failure\|btrfs.*failed\|BTRFS: superblock checksum mismatch" "$KERN" | wc -l)
                        ext4errckern=$(grep -ia "ext-3\|ext-4" "$KERN" | grep -v "scripts/ext-3.4" | wc -l)
                        btrfserrcmsg=$(grep -ia "btrfs critical\|btrfs error\|btrfs warning\|btrfs.*failure\|btrfs.*failed\|BTRFS: superblock checksum mismatch" "$MESSAGES" | wc -l)
                        ext4errcmsg=$(grep -ia "ext-3\|ext-4" "$MESSAGES" | grep -v "scripts/ext-3.4" | wc -l)
                        fserrorct=$(("$btrfserrckern" + "$ext4errckern" + "$btrfserrcmsg" + "$ext4errcmsg"))
                        if [[ -z "$fserrorct" || "$fserrorct" == "0" ]]; then
                            echo -e "\t\tnone" >> "$_sm_raw"
                        else
                            echo -e "\t\t$fserrorct" >> "$_sm_raw"
                        fi

                        if [[ -f "$debug_dsm/var/log/synolog/synosys.log" ]]; then
                            SYSDB="$debug_dsm/var/log/synolog/synosys.log"
                        elif [[ -f "$debug_dsm/var/log/synolog/.SYNOSYSDB" ]]; then
                            sqlite3 "$debug_dsm/var/log/synolog/.SYNOSYSDB" "select id, datetime(time,'unixepoch','localtime'), username, msg from logs;" >> "$debug_dsm/SYSDB.log"
                            SYSDB="$debug_dsm/SYSDB.log"
                            else
                                log "No SYSDB found."
                        fi
                        impropershutdown=$(grep -ia "improper shutdown" "$SYSDB")
                        if [[ -z "$impropershutdown" ]]; then
                            echo -e "improper shutdowns:\t\tnone" >> "$_sm_raw"
                        else
                            echo -ne "improper shutdowns:\t\t" >> "$_sm_raw"
                            grep -iac "improper shutdown" "$SYSDB" >> "$_sm_raw"
                        fi
                        volumecrash=$(grep -ia "was crashed" "$SYSDB") #volumecrash
                        if [[ -z "$volumecrash" ]]; then
                            echo -e "Volume crashes:\t\t\tnone" >> "$_sm_raw"
                        else
                            echo -ne "Volume crashes:\t\t\t" >> "$_sm_raw"
                            grep -iac "was crashed" "$SYSDB" >> "$_sm_raw"
                        fi

                        degradedvolume=$(grep -ia "degrade" "$SYSDB") #volumecrash
                        if [[ -z "$degradedvolume" ]]; then
                            echo -e "degraded volumes:\t\tnone" >> "$_sm_raw"
                        else
                            echo -ne "degraded volumes:\t\t" >> "$_sm_raw"
                            grep -iac "degrade" "$SYSDB" >> "$_sm_raw"
                        fi

                        generrors=$(grep -ia "error" "$SYSDB" | grep -v "Failed to send email" | uniq -u | wc -l) #volumecrash
                        if [[ "$generrors" -eq 0 ]]; then
                            echo -e "generic errs:\t\t\tnone" >> "$_sm_raw"
                        else
                            echo -e "generic errs:\t\t\t$(grep -ia "error" "$SYSDB" | uniq -u | wc -l)" >> "$_sm_raw"
                        fi

                        DRDYErr=$(grep -ia "DRDY" "$MESSAGES" | uniq -u | wc -l)
                        if [[ "$DRDYErr" -eq 0 ]]; then
                            echo -e "DRDY:\t\t\t\t\tnone" >> "$_sm_raw"
                        else
                            echo -e "DRDY:\t\t\t\t\t$(grep -ia "DRDY" "$MESSAGES" | uniq -u | wc -l)" >> "$_sm_raw"
                        fi
                        database_malformed=$(grep -iac "database disk image is malformed" "$MESSAGES")
                        if [[ "$database_malformed" -eq 0 ]]; then
                            echo -e "Database is malformed:\tnone" >> "$_sm_raw"
                        else
                            echo -e "Database is malformed:\t$(grep -iac "database disk image is malformed" "$MESSAGES")"  >> "$_sm_raw"
                        fi

                        oom_kills=$(grep -iac "out_of_memory" "$MESSAGES")
                        if [[ "$oom_kills" -eq 0 ]]; then
                            echo -e "Out of Memory kills:\tnone"  >> "$_sm_raw"
                        else
                            echo -e "Out of Memory kills:\t$(grep -iac "out_of_memory" "$MESSAGES")" >> "$_sm_raw"
                        fi

                        crashes=$(grep -iac "crash" "$MESSAGES")
                        if [[ "$crashes" -eq 0 ]]; then
                            echo -e "generic crashes:\t\tnone" >> "$_sm_raw"
                        else
                            echo -e "generic crashes:\t\t$(grep -iac "crash" "$MESSAGES")" >> "$_sm_raw"
                        fi
                        CallTraces=$(grep -iac "Call Trace" "$MESSAGES")
                        if [[ "$CallTraces" -eq 0 ]]; then
                            echo -e "Call Traces:\t\t\tnone" >> "$_sm_raw"
                        else
                            echo -e "Call Traces:\t\t\t$(grep -iac "Call Trace" "$MESSAGES")" >> "$_sm_raw"
                        fi

                        # ── auth failures count ─────────────────────────────
                        AUTH_LOG="$debug_dsm/var/log/auth.log"
                        if [[ -f "$AUTH_LOG" ]]; then
                            auth_fail_ct=$(grep -ic "Failed password\|authentication failure\|Invalid user" "$AUTH_LOG")
                        else
                            auth_fail_ct=0
                        fi
                        if [[ "$auth_fail_ct" -eq 0 ]]; then
                            echo -e "Authentication failures:\tnone" >> "$_sm_raw"
                        else
                            echo -e "Authentication failures:\t$auth_fail_ct" >> "$_sm_raw"
                        fi

                        # ── BTRFS qgroup warnings ───────────────────────────
                        qgroup_ct=$(grep -ic "qgroup.*\(over\|exceed\|limit reach\)" "$MESSAGES" "$KERN" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')
                        if [[ "$qgroup_ct" -eq 0 ]]; then
                            echo -e "BTRFS qgroup warnings:\tnone" >> "$_sm_raw"
                        else
                            echo -e "BTRFS qgroup warnings:\t$qgroup_ct" >> "$_sm_raw"
                        fi

                        # ── docker container count ──────────────────────────
                        docker_ct=$(ls "$debug_dsm/result/ethtool.docker"*[a-f0-9]*.result 2>/dev/null | wc -l)
                        if [[ "$docker_ct" -gt 0 ]]; then
                            echo -e "Docker containers seen:\t$docker_ct" >> "$_sm_raw"
                        else
                            echo -e "Docker containers seen:\tnone" >> "$_sm_raw"
                        fi

                        # ── non-system users / encrypted shares ─────────────
                        PWD_FILE="$debug_dsm/etc/passwd"
                        if [[ -f "$PWD_FILE" ]]; then
                            users_ct=$(awk -F: '$3>=1000 && $1!="nobody"' "$PWD_FILE" | wc -l)
                            echo -e "Non-system users:\t\t$users_ct" >> "$_sm_raw"
                        fi
                        SHARE_DIR="$debug_dsm/etc/synoshare"
                        if [[ -d "$SHARE_DIR" ]]; then
                            enc_share_ct=$(grep -lE 'encryption[[:space:]]*=[[:space:]]*"?(yes|true|1)"?' "$SHARE_DIR"/* 2>/dev/null | wc -l)
                            echo -e "Encrypted shares:\t\t$enc_share_ct" >> "$_sm_raw"
                        fi

                        echo "" >> "$_sm_raw"

                        # ── Extended Diagnostics block ──────────────────────
                        echo "Extended Diagnostics:" >> "$_sm_raw"

                        # 1. RAID rebuild/resync/check
                        raid_rebuild=$(grep -E "(recovery|resync|check|reshape)\s*=\s*[0-9.]+%" "$MDSTAT" 2>/dev/null)
                        if [[ -n "$raid_rebuild" ]]; then
                            echo "$raid_rebuild" | while read -r rebuild_line; do
                                echo "RAID active rebuild: $rebuild_line" >> "$_sm_raw"
                            done
                        else
                            echo -e "RAID rebuild:\t\t\tnone in progress" >> "$_sm_raw"
                        fi

                        # 2. Volume layout from newest space_history_*.xml
                        sp_hist=$(ls -t "$debug_dsm/etc/space/space_history_"*.xml 2>/dev/null | head -1)
                        if [[ -n "$sp_hist" && -f "$sp_hist" ]]; then
                            echo "Volume layout:" >> "$_sm_raw"
                            awk '
                            /<space[[:space:]]/ { in_sp=1; vp=""; vt=""; vr=""; vs=""; venc="" }
                            in_sp && /<volume[[:space:]]+path=/ {
                                if (match($0, /path="[^"]+"/))  vp=substr($0,RSTART+6,RLENGTH-7)
                                if (match($0, /type="[^"]+"/))  vt=substr($0,RSTART+6,RLENGTH-7)
                            }
                            in_sp && /<raid[[:space:]]/ {
                                if (match($0, /level="[^"]+"/)) {
                                    lvl=substr($0,RSTART+7,RLENGTH-8)
                                    vr=(vr=="" ? lvl : vr "/" lvl)
                                }
                            }
                            in_sp && /total_size="/ {
                                if (match($0, /total_size="[0-9]+"/)) vs=substr($0,RSTART+12,RLENGTH-13)
                            }
                            in_sp && /enable_encryption="yes"/ { venc=" (encrypted)" }
                            /<\/space>/ {
                                if (vp != "") {
                                    gib = vs / 1024 / 1024 / 1024
                                    if (gib >= 1024) printf "  %s: %s / %s%s, %.2f TiB\n", vp, vr, vt, venc, gib/1024
                                    else printf "  %s: %s / %s%s, %.2f GiB\n", vp, vr, vt, venc, gib
                                }
                                in_sp=0
                            }' "$sp_hist" >> "$_sm_raw"
                        fi

                        # 3. HDD temperatures (warn >50, error >60)
                        for sf in "$debug_dsm/result/"{sd,nv,sas[0-9],smart}*; do
                            [[ -e "$sf" ]] || continue
                            tline=$(grep -m1 -iE "^\s*[0-9]+\s+(Temperature_Celsius|Airflow_Temperature_Cel)\b" "$sf" 2>/dev/null)
                            [[ -z "$tline" ]] && continue
                            temp=$(echo "$tline" | awk '{print $10}')
                            [[ ! "$temp" =~ ^[0-9]+$ ]] && continue
                            tag=""
                            if   [[ "$temp" -ge 60 ]]; then tag=" (ERROR: critical temp)"
                            elif [[ "$temp" -ge 50 ]]; then tag=" (warning: high temp)"
                            fi
                            echo "HDD temperature: $(basename -- "$sf"): ${temp}°C${tag}" >> "$_sm_raw"
                        done

                        # 4. HDD age warning from SMART files
                        for sf in "$debug_dsm/result/"{sd,nv,sas[0-9],smart}*; do
                            [[ -e "$sf" ]] || continue
                            pohline=$(grep -m1 -iE "Power[_-][Oo]n[_-](Hours|Hour_Count|Time)" "$sf" 2>/dev/null)
                            [[ -z "$pohline" ]] && continue
                            hours=$(echo "$pohline" | sed -e "s/ ([^()]*)//g" | awk '{print $NF}' | sed 's/h.*//')
                            [[ ! "$hours" =~ ^[0-9]+$ ]] && continue
                            years=$((hours / 8760))
                            if   [[ "$hours" -gt 70000 ]]; then
                                echo "HDD age ERROR: $(basename -- "$sf"): ${hours}h (~${years}y) — replace recommended" >> "$_sm_raw"
                            elif [[ "$hours" -gt 50000 ]]; then
                                echo "HDD age warning: $(basename -- "$sf"): ${hours}h (~${years}y)" >> "$_sm_raw"
                            fi
                        done

                        # 5. HDD vendor distribution
                        vendor_tmp=$(mktemp)
                        for sf in "$debug_dsm/result/"{sd,nv,sas[0-9],smart}*; do
                            [[ -e "$sf" ]] || continue
                            mf=$(grep -m1 -iE "Model Family|Device Model|^Vendor:" "$sf" 2>/dev/null | sed 's/.*:\s*//' | head -c 80)
                            [[ -z "$mf" ]] && mf="Unknown"
                            for vend in "Western Digital" "WD " "Seagate" "Toshiba" "HGST" "Samsung" "Hitachi" "Crucial" "Kingston" "Intel" "SanDisk" "Micron" "Synology"; do
                                if echo "$mf" | grep -qi "$vend"; then
                                    echo "${vend% }" >> "$vendor_tmp"
                                    continue 2
                                fi
                            done
                            echo "$mf" | awk '{print $1}' >> "$vendor_tmp"
                        done
                        if [[ -s "$vendor_tmp" ]]; then
                            summary=$(sort "$vendor_tmp" | uniq -c | sort -rn | awk '{printf "%dx %s, ", $1, $2}' | sed 's/, $//')
                            echo "HDD vendor distribution: $summary" >> "$_sm_raw"
                        fi
                        rm -f "$vendor_tmp"

                        # 6. BTRFS scrub status (real events only, not config syncs)
                        SCRUB_LOG="$debug_dsm/var/log/datascrubbing.log"
                        if [[ -f "$SCRUB_LOG" ]]; then
                            real_scrub_count=$(grep -cE "Start (btrfs|ext4)? data scrubbing on|data scrubbing done" "$SCRUB_LOG" 2>/dev/null)
                            if [[ "$real_scrub_count" -gt 0 ]]; then
                                # Last start per volume
                                awk '
                                /Start (btrfs|ext4)? data scrubbing on/ {
                                    if (match($0, /on [^ ]+/)) {
                                        v=substr($0,RSTART+3,RLENGTH-3); starts[v]=$1
                                    }
                                }
                                /Space .* data scrubbing done/ {
                                    if (match($0, /Space '\''[^'\'']+'\''/)) {
                                        v=substr($0,RSTART+7,RLENGTH-8); finishes[v]=$1
                                    }
                                }
                                END {
                                    for (v in starts) printf "BTRFS scrub (%s): last start=%s, last finish=%s\n", v, starts[v], (finishes[v] ? finishes[v] : "?")
                                    for (v in finishes) if (!(v in starts)) printf "BTRFS scrub (%s): last start=?, last finish=%s\n", v, finishes[v]
                                }' "$SCRUB_LOG" >> "$_sm_raw"
                            else
                                echo "BTRFS scrub: no scrub history found" >> "$_sm_raw"
                            fi
                        else
                            echo "BTRFS scrub: no scrub log present" >> "$_sm_raw"
                        fi

                        # 7. Disk Health Prediction (via jq)
                        HEALTH_JSON="$debug_dsm/var/log/disk_health_information.json"
                        if [[ -f "$HEALTH_JSON" ]] && command -v jq >/dev/null; then
                            jq -r 'to_entries[] |
                                .key as $sn |
                                .value as $v |
                                ($v.model // "?") as $model |
                                ($v | to_entries | map(select(.key | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}"))) | sort_by(.key) | last) as $latest |
                                ($latest.value.detail.overview_status // "?") as $st |
                                ($latest.value.cache.temperature // "") as $temp |
                                "Disk Health Prediction: \($sn) (\($model)): \($st)\(if $temp != "" then ", temp=\($temp)°C" else "" end)" +
                                (if $st == "warning" then " (WARNING)" elif $st != "normal" and $st != "?" then " (CRITICAL)" else "" end)
                            ' "$HEALTH_JSON" 2>/dev/null >> "$_sm_raw"
                        fi

                        # 8. Failed dpkg upgrades
                        DPKG_LOG="$debug_dsm/var/log/dpkg_upgrade.log"
                        if [[ -f "$DPKG_LOG" ]]; then
                            dpkg_fails=$(grep -iE "error|failed|not authenticated" "$DPKG_LOG" 2>/dev/null | grep -vi passed | tail -3)
                            if [[ -n "$dpkg_fails" ]]; then
                                fail_count=$(grep -ciE "error|failed|not authenticated" "$DPKG_LOG" 2>/dev/null)
                                echo "Failed dpkg upgrades: $fail_count entries (showing 3):" >> "$_sm_raw"
                                echo "$dpkg_fails" | sed 's/^/  /' >> "$_sm_raw"
                            else
                                echo -e "Failed dpkg upgrades:\tnone" >> "$_sm_raw"
                            fi
                        else
                            echo -e "Failed dpkg upgrades:\tnone" >> "$_sm_raw"
                        fi

                        # 9. Recent DSM update
                        SYNOUPDATE_LOG="$debug_dsm/var/log/synoupdate.log"
                        if [[ -f "$SYNOUPDATE_LOG" ]]; then
                            last_upd=$(tac "$SYNOUPDATE_LOG" | grep -m1 -E "^[0-9]{4}/[0-9]{2}/[0-9]{2}")
                            if [[ -n "$last_upd" ]]; then
                                ts=$(echo "$last_upd" | awk '{print $1, $2}')
                                last_upd_epoch=$(date -d "$(echo "$ts" | sed 's|/|-|g')" +%s 2>/dev/null || echo 0)
                                now_epoch=$(date +%s)
                                days_ago=$(( (now_epoch - last_upd_epoch) / 86400 ))
                                tag=""
                                if [[ "$days_ago" -ge 0 && "$days_ago" -lt 7 ]]; then tag=" (RECENT: < 7 days)"; fi
                                echo "Last DSM update activity: $ts (${days_ago} days ago)${tag}" >> "$_sm_raw"
                            fi
                        fi

                        # 10. Auth failures detail
                        if [[ "$auth_fail_ct" -gt 0 && -f "$AUTH_LOG" ]]; then
                            severity=""
                            [[ "$auth_fail_ct" -ge 10 ]] && severity=" (WARNING)"
                            echo "Auth failures: ${auth_fail_ct} total${severity}" >> "$_sm_raw"
                            top_user=$(grep -E "Failed password|authentication failure|Invalid user" "$AUTH_LOG" 2>/dev/null \
                                | grep -oE '(^|[[:space:]])user=[^ ]+' | sed 's/.*user=//' \
                                | sort | uniq -c | sort -rn | head -3 \
                                | awk '{printf "%s(%d), ", $2, $1}' | sed 's/, $//')
                            if [[ -z "$top_user" ]]; then
                                top_user=$(grep -oE "for invalid user \S+|for \S+ from" "$AUTH_LOG" 2>/dev/null \
                                    | awk '{print $(NF-1)}' | sort | uniq -c | sort -rn | head -3 \
                                    | awk '{printf "%s(%d), ", $2, $1}' | sed 's/, $//')
                            fi
                            top_host=$(grep -E "Failed password|authentication failure|Invalid user" "$AUTH_LOG" 2>/dev/null \
                                | grep -oE 'rhost=[^ ]+' | sed 's/rhost=//' \
                                | grep -v '^$' | sort | uniq -c | sort -rn | head -3 \
                                | awk '{printf "%s(%d), ", $2, $1}' | sed 's/, $//')
                            [[ -n "$top_user" ]] && echo "  Top targeted users: $top_user" >> "$_sm_raw"
                            [[ -n "$top_host" ]] && echo "  Top source hosts: $top_host" >> "$_sm_raw"
                        fi

                        # 11. UPS events from messages
                        ups_events=$(grep -iE "on battery|power failure|low battery|battery low|ups.*replace|apcupsd|upsmon" "$MESSAGES" 2>/dev/null | tail -3)
                        if [[ -n "$ups_events" ]]; then
                            echo "UPS events:" >> "$_sm_raw"
                            echo "$ups_events" | sed 's/^/  /' >> "$_sm_raw"
                        fi

                        # 12. HyperBackup task summary
                        BACKUP_LOG="$debug_dsm/var/log/synolog/synobackup.log"
                        if [[ -f "$BACKUP_LOG" ]]; then
                            # Last 5 backup tasks
                            backup_summary=$(tac "$BACKUP_LOG" 2>/dev/null \
                                | awk -F'\t' '
                                    /\[Local\]\[/ || /\] Backup/ {
                                        match($0, /\[[A-Za-z0-9_-]+\]/); name=substr($0,RSTART+1,RLENGTH-2);
                                        if (!(name in seen)) {
                                            seen[name]=1; print $0
                                            count++; if (count>=5) exit
                                        }
                                    }' | head -5)
                            if [[ -n "$backup_summary" ]]; then
                                echo "HyperBackup tasks:" >> "$_sm_raw"
                                echo "$backup_summary" | sed 's/^/  /' >> "$_sm_raw"
                            fi
                        fi

                        # 13. Bonding/LAG
                        BOND_DIR="$debug_dsm/proc/net/bonding"
                        if [[ -d "$BOND_DIR" ]]; then
                            echo "Network bonding:" >> "$_sm_raw"
                            for bf in "$BOND_DIR"/*; do
                                [[ -f "$bf" ]] || continue
                                mode=$(grep "Bonding Mode:" "$bf" | sed 's/.*: //')
                                slaves=$(grep "Slave Interface:" "$bf" | sed 's/.*: //' | tr '\n' ',' | sed 's/,$//')
                                states=$(grep "MII Status:" "$bf" | sed 's/.*: //' | tr '\n' ',' | sed 's/,$//')
                                echo "  $(basename -- "$bf"): mode=$mode, slaves=$slaves, states=$states" >> "$_sm_raw"
                            done
                        fi

                        # 14. Load average warning
                        if [[ -n "$UPTIME" ]]; then
                            la=$(echo "$UPTIME" | grep -oE "load average:\s*[0-9.]+" | awk '{print $NF}')
                            if [[ -n "$la" ]]; then
                                la_int=${la%.*}
                                if [[ "$la_int" -gt 10 ]] 2>/dev/null; then
                                    echo "High load average detected: $la (critical)" >> "$_sm_raw"
                                elif [[ "$la_int" -gt 5 ]] 2>/dev/null; then
                                    echo "Elevated load average: $la (warning)" >> "$_sm_raw"
                                fi
                            fi
                        fi

                        # 15. DSM region (timezone, language)
                        if [[ -f "$debug_dsm/etc/synoinfo.conf" ]]; then
                            tz=$(grep -oE 'timezone\s*=\s*"[^"]*"' "$debug_dsm/etc/synoinfo.conf" 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')
                            lang=$(grep -oE 'language\s*=\s*"[^"]*"' "$debug_dsm/etc/synoinfo.conf" 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')
                            if [[ -n "$tz" || -n "$lang" ]]; then
                                echo "DSM region: timezone=${tz:-?}, language=${lang:-?}" >> "$_sm_raw"
                            fi
                        fi

                        # 16. SMART self-test schedule
                        SMART_TEST_LOG="$debug_dsm/var/log/disk_smart_test_log.xml"
                        smart_sched=$(grep -oE "smart_test_period\s*=\s*\"[^\"]+\"|disk_smart_test_schedule\s*=\s*\"[^\"]+\"" "$debug_dsm/etc/synoinfo.conf" 2>/dev/null | sed 's/.*"\(.*\)"/\1/')
                        if [[ -n "$smart_sched" && "$smart_sched" != "none" && "$smart_sched" != "no" ]]; then
                            echo "SMART self-test schedule: $smart_sched" >> "$_sm_raw"
                        elif [[ -f "$SMART_TEST_LOG" && $(stat -c%s "$SMART_TEST_LOG" 2>/dev/null || echo 0) -gt 100 ]]; then
                            echo "SMART self-test schedule: history present (recent tests detected)" >> "$_sm_raw"
                        else
                            echo "SMART self-test schedule: not configured" >> "$_sm_raw"
                        fi

                        echo "" >> "$_sm_raw"
                        # ── End Extended Diagnostics ───────────────────────

                        echo -e "\n" >> "$_sm_raw"
                        echo -en "Third Party packages:" >> "$_sm_raw"
                        if [ -z "$third_packages" ]; then
                            echo -e "\tnone" >> "$_sm_raw"
                        else
                            echo -e "\n$third_packages\n" >> "$_sm_raw"
                        fi
                fi

                btrfserrkern=$(grep -ia "btrfs critical\|btrfs error\|btrfs warning\|btrfs.*failure\|btrfs.*failed\|BTRFS: superblock checksum mismatch" "$KERN")
                ext4errkern=$(grep -ia "ext-3\|ext-4" "$KERN" | grep -v "scripts/ext-3.4")
                btrfserrmsg=$(grep -ia "btrfs critical\|btrfs error\|btrfs warning\|btrfs.*failure\|btrfs.*failed\|BTRFS: superblock checksum mismatch" "$MESSAGES")
                ext4errmsg=$(grep -ia "ext-3\|ext-4" "$MESSAGES" | grep -v "scripts/ext-3.4" )
                if [[ -z "$btrfserrkern" ]] && [[ -z "$ext4errkern" ]] && [[ -z "$btrfserrmsg" ]] && [[ -z "$ext4errmsg" ]]; then
                    echo -e "Ext4-/Btrfs-Errs:\t\tnone" >> "$_sm_raw"
                else
                    # Combine, dedupe, sort by leading ISO timestamp, keep newest 20
                    all_fs=$(printf '%s\n%s\n%s\n%s\n' \
                        "$btrfserrkern" "$ext4errkern" "$btrfserrmsg" "$ext4errmsg" \
                        | grep -v '^$' | awk '!seen[$0]++' | sort)
                    total=$(echo "$all_fs" | wc -l)
                    shown=$(echo "$all_fs" | tail -n 20)
                    if [[ "$total" -gt 20 ]]; then
                        hidden=$((total - 20))
                        echo -e "\nExt4-/Btrfs-Errors: $total total — showing newest 20 ($hidden omitted)" >> "$_sm_raw"
                    else
                        echo -e "\nExt4-/Btrfs-Errors:" >> "$_sm_raw"
                    fi
                    echo "$shown" >> "$_sm_raw"
                fi

                    tac "$SYSDB" >> "$debug_dsm/var/log/synolog/synosystac.log"
                    SYSDBtac="$debug_dsm/var/log/synolog/synosystac.log"

                    impropershutdown=$(grep -ia "improper shutdown" "$SYSDB") #improper shutdowns
                    if [[ -z "$impropershutdown" ]]; then
                        echo -e "improper shutdowns:\t\tnone" >> "$_sm_raw"
                    else
                        echo -e "improper shutdowns:" >> "$_sm_raw"
                        echo "$impropershutdown" >> "$_sm_raw"
                        echo -e "\n" >> "$_sm_raw"
                    fi
                    volumecrash=$(grep -ia "was crashed" "$SYSDB") #volumecrash
                    if [[ -z "$volumecrash" ]]; then
                        echo -e "Volume crashes:\t\t\tnone" >> "$_sm_raw"
                    else
                        echo -e "Volume crashes:" >> "$_sm_raw"
                        echo "$volumecrash" >> "$_sm_raw"
                        echo -e "\n" >> "$_sm_raw"
                    fi

                    degradedvolume=$(grep -ia "degrade" "$SYSDB") #volumedegradation
                    if [[ -z "$degradedvolume" ]]; then
                        echo -e "degraded volumes:\t\tnone" >> "$_sm_raw"
                    else
                        echo -e "degraded volumes:" >> "$_sm_raw"
                        echo "$degradedvolume" >> "$_sm_raw"
                        echo -e "\n" >> "$_sm_raw"
                    fi

                    generrors=$(grep -ia "error" "$SYSDB" | uniq -u | wc -l) #generic errors
                    if [[ "$generrors" -eq 0 ]]; then
                        echo -e "generic errs:\t\t\tnone" >> "$_sm_raw"
                    else
                        echo -e "$(grep -ia "error" "$SYSDB" | grep -v "Failed to send email" | uniq -u | wc -l) generic errs:" >> "$_sm_raw"
                        echo "$(grep -ia "error" "$SYSDB" | grep -v "Failed to send email" | uniq -u)" >> "$_sm_raw"
                        echo -e "\n" >> "$_sm_raw"
                    fi

                if [[ "$TemporaryWorkaround" = 0 ]]; then
                    if [[ -f "$debug_dsm/var/log/messages.log" ]]; then
                        {
                            # Helper: print "<label>: N total — showing newest 20 (M omitted):" then last 20 lines (chronological)
                            emit_capped() {
                                local label="$1"; local pattern="$2"
                                local total
                                total=$(grep -iac "$pattern" "$MESSAGES")
                                if [[ "$total" -eq 0 ]]; then
                                    echo -e "${label}:\tnone"
                                    return
                                fi
                                local omitted=$(( total - 20 ))
                                if [[ "$omitted" -gt 0 ]]; then
                                    echo -e "${label}: ${total} total — showing newest 20 (${omitted} omitted):"
                                else
                                    echo -e "${label}: ${total} total — showing newest ${total}:"
                                fi
                                tac "$MESSAGES" | grep -ia -m20 "$pattern" | tac
                                echo -e "\n"
                            }

                            DRDYErr=$(grep -iac "DRDY" "$MESSAGES")
                            if [[ "$DRDYErr" -eq 0 ]]; then
                                echo -e "DRDY:\t\t\t\t\tnone"
                            else
                                emit_capped "DRDY" "DRDY"
                            fi
                            log "1646"
                            emit_capped "Database is malformed" "database disk image is malformed"
                            log "1655"
                            emit_capped "Out of Memory kills" "out_of_memory"
                            emit_capped "generic crashes" "crash"
                            log "1672"
                            CallTraces=$(grep -iac "Call Trace" "$MESSAGES")
                            if [[ "$CallTraces" -eq 0 ]]; then
                                echo -e "Call Traces:\t\t\tnone"
                            else
                                echo -e "$(grep -iac "Call Trace" "$MESSAGES") Call traces, showing last one:"
                                tac "$MESSAGES" | grep -ia -m1 "Call Trace" -B25 | tac
                            fi
                        } >>  "$_sm_raw"
                    fi
                fi

                # Render sectioned sm.log, then remove temp file
                render_sm_log
                rm -f "$_sm_raw" 2>/dev/null

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

                if [[ -f "$debug_dsm/etc/synoinfo.conf" ]]; then
                kernel_log_max=$(grep -c "kern_log_max=\"yes\"" "$DOWNLOAD_DIR"/debug_"$DATE"/"$DSM"/etc/synoinfo.conf)
                    if [ "$kernel_log_max" -gt 0 ]
                            then echo "Extended kernel logging on NAS is on." >> "$hb_debug"
                            else echo "Extended kernel logging on NAS is off." >> "$hb_debug"
                    fi
                else
                    log "synoinfo.conf not found."
                fi

                if [[ -f "$debug_dsm/etc/synoinfo.conf" ]]; then
                sys_stat_dump=$(grep "sys_stat_dump" "$debug_dsm/etc/synoinfo.conf" | cut -d "=" -f2)
                    if [ "$sys_stat_dump" == "yes" ]
                            then echo "Log system status periodically on NAS is on." >> "$hb_debug"
                    elif [ "$sys_stat_dump" == "no" ]
                            then echo "Log system status periodically on NAS is off." >> "$hb_debug"
                    else
                        echo "Log system status periodically: unknown" >> "$hb_debug"
                    fi
                else
                    log "synoinfo.conf not found."
                fi

                if [[ -f "$debug_dsm/etc/samba/smb.conf" ]]; then
                local_master=$(grep "local master" "$debug_dsm/etc/samba/smb.conf" | cut -d "=" -f2)
                    if [ "$local_master" == "yes" ]
                            then echo "Local Master Browser on NAS is on." >> "$hb_debug"
                    elif [ "$local_master" == "no" ]
                            then echo "Local Master Browser on NAS is off." >> "$hb_debug"
                    else
                        echo "Local Master Browser: unknown" >> "$hb_debug"
                    fi
                else
                    log "smb.conf not found."
                fi

                if [[ -f "$debug_dsm/etc/synoinfo.conf" ]]; then
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
                        log "enablercpower: unknown"
                    fi
                fi

                grep "^standbytimer" "$debug_dsm/etc/synoinfo.conf" >> "$hb_debug"

                echo -n "Packages interfering with Hibernation:" >> "$hb_debug"
                        hb_packages=$(grep "ActiveDirectoryServer\|AudioStation\|CloudStation\|MediaServer\|SynologyDrive\|CloudSync\|DownloadStation\|SurveillanceStation\|CMS\|Docker\|MailClient\|MailPlus\|MailPlus-Server\|PetaSpace\|Virtualization\|MailStation" "$PACK")
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

                if [[ -f "$debug_dsm/etc/power_sched.conf" ]]; then
                    echo -e "\n" >> "$hb_debug"
                    cat "$debug_dsm/etc/power_sched.conf" >> "$hb_debug"
                    while read -r sched_val; do
                        re='^[0-9]+$'
                        if [[ $sched_val =~ $re ]]; then
                            decode_power_sched "$sched_val" >> "$hb_debug"
                        fi
                    done < "$debug_dsm/etc/power_sched.conf"
                    else
                     echo "power_sched.conf not found." >> "$hb_debug"
                fi

                counter=0
                allpics=$(find "$DOWNLOAD_DIR/debug_${DATE}/" -maxdepth 1 -type f \( -name "*.jpg" -o -name "*.png" -o -name "*.PNG" -o -name "*.JPG" \) 2>/dev/null)
                declare -a PicArray
                for pic in "${allpics}"
                do  PicArray["${counter}"]="${pic}"
                    (( counter++ ))
                done

                #if file does not exist, set var to empty string (lazy fix for router debugs):
                if [ ! -f "$sm" ]; then
                    sm=""
                fi
                if [ ! -f "$hb_debug" ]; then
                    hb_debug=""
                fi
                if [ ! -d "$DOWNLOAD_DIR/debug_$DATE" ]; then
                    DEBUG_DIR=""
                fi


                sleep 0.1

            TIMEFORMAT=$'\nOpening Editor took: \t\t\t\t\t\t\t\t\e[36m%Rsec\e[39m'
            time(
                source "${Script_dir}/config.sh" #load OpenFiles[] Array from config.sh
                #log "Array before unsetting: ${OpenFiles[@]}"
                for i in "${!OpenFiles[@]}"; do #remove empty/missing entries from array [@]
                    _f="${OpenFiles[$i]}"
                    _base="${_f%%:*}"  # strip :100000 Sublime suffix before checking existence
                    if [[ -z "$_f" || ! -e "$_base" ]]; then
                        log "OpenFiles[$i] unset, because empty or not found: ${_f}"
                        unset "OpenFiles[$i]"
                    fi
                done
                if [[ "$os" == "win" ]]; then
                    # Convert all paths to Windows format and open in one Sublime call
                    declare -a _win_paths
                    for i in "${OpenFiles[@]}"; do
                        _win_paths+=("$(wslpath -w "$i")")
                    done
                    "${subl[@]}" "${_win_paths[@]}" 2>/dev/null
                    unset _win_paths
                else
                    for i in "${OpenFiles[@]}"; do # open single files
                        "${subl[@]}" "$i"
                        sleep 0.1
                    done
                fi

                echo -n "${subl[*]} "
                if [[ "$writeLastDebugToFile" = 1 ]]; then
                	echo -n "${subl[*]} " > "${LastDebugFile}"
            	fi
                for arg in "${OpenFiles[@]}"
                    do echo -n "\"$arg\" "
                    	if [[ "$writeLastDebugToFile" = 1 ]]; then
                        echo -n "\"$arg\" " >> "${LastDebugFile}"
                   		fi
                done
                )
                TIMEFORMAT=$'Executiontime: \t\t\t\t\t\t\t\t\t\e[36m%Rsec\e[39m'
                else
                    mkdir -p "${DOWNLOAD_DIR}/kapott"
                    mv "$file" "${DOWNLOAD_DIR}/kapott/debug_$DATE.dat"
                    echo "could not extract $file"
                    if [[ "$os" = "win" ]]; then
                        echo "" #maybe add things here
                    elif [[ "$os" = "other" ]]; then
                    	echo "" #maybe add things here
                fi
            fi
    DSM=dsm
    )
    echo
}

echo "Waiting for debug-files..."
log "Verbose logging enabled."

while true; do
    for file in "${DOWNLOAD_DIR}"/*.dat; do
        [[ -f "$file" ]] && process_dat_file "$file"
    done
    sleep "$sleep_scan_dir"
done