#!/usr/bin/env python3
"""
entpacker.py - Synology debug file extractor and analyzer
Python port of entpacker.sh by Thomas Feldmann
Runs on Windows, Linux, and macOS.

Requirements: pip install requests
"""

import argparse
import concurrent.futures
import json
import lzma
import os
import platform
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import time
import zipfile
from datetime import datetime
from pathlib import Path

try:
    import requests
except ImportError:
    print("Please install requests: pip install requests")
    sys.exit(1)

SCRIPT_DIR = Path(__file__).parent.resolve()
CPU_FILE = SCRIPT_DIR / "files" / "CPU.txt"
POWER_SCHED_PY = SCRIPT_DIR / "files" / "power_shed.py"
RSS_FILE = SCRIPT_DIR / "tmp" / "genRSS.php"
SRS_FILE = SCRIPT_DIR / "tmp" / "SRS.php"
SRS_DE_FILE = SCRIPT_DIR / "tmp" / "SRS-de.php"
AVAILABLE_PACKAGES = SCRIPT_DIR / "tmp" / "available_packages.txt"
PACKAGE_VERSIONS = SCRIPT_DIR / "tmp" / "package_versions.txt"
PRODUCT_LIST = SCRIPT_DIR / "tmp" / "ProductList.json"
COMP_DIR = SCRIPT_DIR / "comp"
TMP_DIR = SCRIPT_DIR / "tmp"

SLEEP_SCAN_DIR = 6
SLEEP_EXTRACT_ZIP = 0.5

verbose = False


def log(msg):
    if verbose:
        print(f"[verbose] {msg}")


def bytes_to_human(b):
    b = int(b) if b else 0
    suffixes = ["Bytes", "KiB", "MiB", "GiB", "TiB", "PiB"]
    s = 0
    d = ""
    while b > 1024 and s < len(suffixes) - 1:
        rem = b % 1024
        d = f".{rem * 100 // 1024:02d}"
        b //= 1024
        s += 1
    return f"{b}{d} {suffixes[s]}"


def version_key(ver):
    if not ver:
        return (0,)
    parts = re.split(r"[.\-]", str(ver))
    result = []
    for p in parts:
        try:
            result.append(int(p))
        except ValueError:
            result.append(0)
    return tuple(result)


def version_compare_gt(a, b):
    return version_key(a) > version_key(b)


def find_editor():
    system = platform.system()
    if system == "Windows":
        for c in [
            r"C:\Program Files\Sublime Text\subl.exe",
            r"C:\Program Files\Sublime Text 4\subl.exe",
            r"C:\Program Files\Sublime Text 3\subl.exe",
        ]:
            if Path(c).exists():
                return c
        return "notepad.exe"
    try:
        with open("/proc/version") as f:
            if re.search(r"Microsoft|WSL", f.read()):
                return r"/mnt/c/Program Files/Sublime Text 3/subl.exe"
    except Exception:
        pass
    for candidate in ["subl", "sublime_text", "gedit", "xdg-open"]:
        if shutil.which(candidate):
            return candidate
    return None


def read_file(path) -> str:
    try:
        return Path(path).read_text(errors="replace")
    except Exception:
        return ""


def grep_lines(pattern, text, flags=re.IGNORECASE) -> list:
    return [m.group(0) for m in re.finditer(f".*{pattern}.*", text, flags | re.MULTILINE)]


def grep_count(pattern, text, flags=re.IGNORECASE) -> int:
    return len(re.findall(pattern, text, flags))


# ---------------------------------------------------------------------------
# Update functions
# ---------------------------------------------------------------------------

def update_dsm_updates_list():
    print("Downloading latest genRSS.php...", end="", flush=True)
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    try:
        r = requests.get("https://update.synology.com/autoupdate/genRSS.php", timeout=30)
        RSS_FILE.write_bytes(r.content)
        print(f" done ({len(r.content)} bytes)")
    except Exception as e:
        print(f" error: {e}")


def update_srs_list():
    print("SRS-Liste entfällt (Synology hat SRS eingestellt).")
    SRS_FILE.touch()
    SRS_DE_FILE.touch()


def update_package_versions_list():
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    try:
        r = requests.get("https://archive.synology.com/download/Package/", timeout=30)
        packages = re.findall(r'href="([A-Za-z][^/"]+)/"', r.text)
        packages = [p for p in packages if not p.startswith(".")]
        AVAILABLE_PACKAGES.write_text("\n".join(packages) + "\n")
    except Exception as e:
        print(f"Package list error: {e}")
        return

    print(f"Updating latest package versions for {len(packages)} packages", end="", flush=True)

    def fetch_version(pkg):
        url = f"https://archive.synology.com/download/Package/{pkg.replace('+', '%2B')}/"
        try:
            resp = requests.get(url, timeout=20)
            versions = re.findall(r'href="([0-9][^/"]*)"', resp.text)
            versions = [v for v in versions if re.match(r"^[0-9]", v)]
            if versions:
                versions.sort(key=version_key, reverse=True)
                return pkg, versions[0]
        except Exception:
            pass
        return pkg, ""

    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as exe:
        futures = {exe.submit(fetch_version, p): p for p in packages}
        for i, fut in enumerate(concurrent.futures.as_completed(futures)):
            pkg, ver = fut.result()
            results[pkg] = ver
            if i % 30 == 0:
                print(".", end="", flush=True)
    print(" done")

    lines = [f"{pkg} {ver}" for pkg, ver in sorted(results.items()) if ver]
    PACKAGE_VERSIONS.write_text("\n".join(lines) + "\n")


def update_compatibility_lists():
    COMP_DIR.mkdir(parents=True, exist_ok=True)
    print("Getting available Models...", end="", flush=True)
    try:
        r = requests.get(
            "https://www.synology.com/cgi/misc/?action=getProductList_withOEM", timeout=30
        )
        m = re.search(r"\[([^\]]+)\]", r.text)
        if not m:
            print(" error parsing model list")
            return
        models = [x.strip().strip('"') for x in m.group(1).split(",")]
        PRODUCT_LIST.write_text(json.dumps(models, indent=2))
        print(f" {len(models)} models done")
    except Exception as e:
        print(f" error: {e}")
        return

    print(f"Downloading compatibility lists for {len(models)} models...")

    def fetch_compat(model):
        enc = model.replace("+", "%2B")
        base = "https://www.synology.com/api/compatibility/findHclList"
        for suffix, recommend in [("compatible", "t"), ("incompatible", "f")]:
            out = COMP_DIR / f"{model}_hdds_{suffix}.json"
            try:
                resp = requests.get(
                    f"{base}?lang=en-global&tab=drives&model={enc}&category=hdds_no_ssd_trim&recommend={recommend}",
                    timeout=30,
                )
                out.write_text(resp.text.replace("\\/", "/"))
            except Exception:
                pass

    with concurrent.futures.ThreadPoolExecutor(max_workers=40) as exe:
        list(exe.map(fetch_compat, models))
    print("Compatibility lists downloaded.")


def check_and_update():
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    COMP_DIR.mkdir(parents=True, exist_ok=True)
    now = time.time()

    rss_age = now - RSS_FILE.stat().st_mtime if RSS_FILE.exists() else float("inf")
    if rss_age > 600 * 60:
        RSS_FILE.touch()
        update_dsm_updates_list()

    srs_age = now - SRS_FILE.stat().st_mtime if SRS_FILE.exists() else float("inf")
    if srs_age > 600 * 60:
        SRS_FILE.touch()
        update_srs_list()

    pv_age = now - PACKAGE_VERSIONS.stat().st_mtime if PACKAGE_VERSIONS.exists() else float("inf")
    if pv_age > 16040 * 60:
        PACKAGE_VERSIONS.touch()
        update_compatibility_lists()
        update_package_versions_list()


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

def extract_dat(filepath: Path, download_dir: Path):
    ts = datetime.now()
    ts_aligned = ts.replace(second=(ts.second // 10) * 10, microsecond=0)
    date_str = ts_aligned.strftime("%H%M%S")
    dest = download_dir / f"debug_{date_str}"
    dest.mkdir(parents=True, exist_ok=True)

    with open(filepath, "rb") as f:
        magic = f.read(4)

    if magic[:2] == b"\x1f\x8b":
        with tarfile.open(filepath, "r:gz") as tf:
            tf.extractall(dest)
    elif magic[:4] == b"PK\x03\x04":
        with zipfile.ZipFile(filepath) as zf:
            zf.extractall(dest)
    else:
        with tarfile.open(filepath, "r:*") as tf:
            tf.extractall(dest)

    return dest, date_str


def decompress_xz_logs(dsm_dir: Path):
    for glob_pat, main_name in [
        ("var/log/messages*.xz", "var/log/messages"),
        ("var/log/kern*.xz", "var/log/kern.log"),
        ("var/log/dmesg*.xz", "var/log/dmesg"),
    ]:
        xz_files = sorted(dsm_dir.glob(glob_pat))
        if not xz_files:
            continue
        main_path = dsm_dir / main_name
        parts = []
        for xf in xz_files:
            try:
                with lzma.open(xf) as f:
                    parts.append(f.read())
                xf.unlink()
            except Exception:
                pass
        if parts:
            existing = main_path.read_bytes() if main_path.exists() else b""
            main_path.write_bytes(b"".join(parts) + existing)


# ---------------------------------------------------------------------------
# HDD compatibility
# ---------------------------------------------------------------------------

_comp_cache: dict = {}


def check_hdd_compat(model_name: str, upnp_model: str) -> str:
    if not model_name:
        return ""
    ck = f"{upnp_model}_comp"
    ik = f"{upnp_model}_incomp"
    if ck not in _comp_cache:
        _comp_cache[ck] = read_file(COMP_DIR / f"{upnp_model}_hdds_compatible.json")
        _comp_cache[ik] = read_file(COMP_DIR / f"{upnp_model}_hdds_incompatible.json")

    variants = [model_name, model_name.replace("-", " - "), model_name.rsplit("-", 1)[0]]
    for v in variants:
        if v and v in _comp_cache[ik]:
            return "(incompatible)"
    for v in variants:
        if v and v in _comp_cache[ck]:
            return "(compatible)"
    return "(not listed)"


# ---------------------------------------------------------------------------
# SMART parsing
# ---------------------------------------------------------------------------

def parse_smart(path: Path) -> dict:
    text = read_file(path)

    def attr_raw(pattern):
        m = re.search(
            rf"(?i){pattern}\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)", text
        )
        return int(m.group(1)) if m else 0

    reallocated = attr_raw(r"Reallocated_Sector_C[t]|Reallocated_Sector_Count")
    pending = attr_raw(r"Current_Pending_Sector")
    offline_unc = attr_raw(r"Offline_Uncorrectable|Uncorrectable_Error_Count|Off-Line_Scan_Uncorrectable_Sector_Count")

    # Model name - mirrors bash: cut -d " " -f8 style parsing
    model = ""
    model_family = ""
    for line in text.splitlines():
        if re.match(r"Model Family", line, re.I) and not model_family:
            model_family = re.sub(r".*:\s*", "", line).strip()
        if re.match(r"Device Model", line, re.I) and not model:
            parts = line.split()
            if len(parts) >= 3:
                raw = " ".join(parts[2:]).replace('"', "Inch")
                if raw == "SSD" and len(parts) >= 4:
                    model = " ".join(parts[3:5]).replace('"', "Inch")
                else:
                    model = parts[2].replace('"', "Inch") if len(parts) >= 3 else raw

    if not model:
        m = re.search(r"^Product\s*:\s*(.+)", text, re.I | re.M)
        if m:
            model = m.group(1).strip()

    capacity = ""
    m = re.search(r"User Capacity.*?\[([^\]]+)\]", text, re.I)
    if m:
        capacity = m.group(1).strip()

    sector_size = ""
    m = re.search(r"(?:Sector Size|Logical block size)\s*[:\s]+(\d+)", text, re.I)
    if m:
        sector_size = m.group(1)

    poh = ""
    m = re.search(
        r"Power[_-][Oo]n[_-](?:[Hh]ours?|[Tt]ime)[_-]?(?:[Cc]ount)?\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)",
        text, re.I,
    )
    if m:
        poh = m.group(1)

    last_test = ""
    last_result = ""
    m = re.search(r"Extended [Oo]ffline\s+(.+)", text)
    if m:
        parts = m.group(1).split()
        for p in parts:
            if p.isdigit():
                last_test = p
                break
        last_result = " ".join(parts[:4]) if len(parts) >= 4 else m.group(1)

    if not last_result:
        m = re.search(r"Background long\s{3,}(.+)", text)
        if m:
            last_result = " ".join(m.group(1).split()[:4])
            last_test = "sas-drive"

    return dict(
        reallocated=reallocated, pending=pending, offline_unc=offline_unc,
        model=model, model_family=model_family, capacity=capacity,
        sector_size=sector_size, poh=poh, last_test=last_test, last_result=last_result,
    )


# ---------------------------------------------------------------------------
# Service enabled check
# ---------------------------------------------------------------------------

def service_enabled(name, config_file, synoservice_dir: Path) -> str:
    path = synoservice_dir / config_file
    if not path.exists():
        return f"{name} status unknown"
    m = re.search(r'auto_start["\s:]+([^",:]+)', read_file(path))
    if m:
        s = m.group(1).strip()
        return f"{name} is {'on' if s == 'yes' else 'off'}"
    return f"{name} status unknown"


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

def analyze(debug_dir: Path, download_dir: Path, sm_prefix: str = ""):
    # Locate dsm subdirectory
    dsm_dir = debug_dir / "dsm"
    if not dsm_dir.is_dir():
        dsm_dir = debug_dir

    old_dsm_warning = False

    # Old DSM layout: volume1/@tmp/.../dsm/
    v1tmp = debug_dir / "volume1" / "@tmp"
    if v1tmp.is_dir():
        for sfvar in v1tmp.iterdir():
            dsm_src = sfvar / "dsm"
            if dsm_src.is_dir():
                for f in list(dsm_src.iterdir()):
                    shutil.move(str(f), str(debug_dir))
        old_dsm_warning = True

    # packages.list at root = old flat layout
    if (debug_dir / "packages.list").exists():
        dsm_dir = debug_dir

    sm = dsm_dir / "sm.log"
    sg = dsm_dir / "smartgrep"
    hb = dsm_dir / "hibernation_debug.log"

    # Decompress xz logs
    decompress_xz_logs(dsm_dir)

    # Rename messages → messages.log
    msg_raw = dsm_dir / "var" / "log" / "messages"
    msg_path = dsm_dir / "var" / "log" / "messages.log"
    if msg_raw.exists() and not msg_path.exists():
        msg_raw.rename(msg_path)

    # Core text files
    synoinfo = read_file(dsm_dir / "etc.defaults" / "synoinfo.conf") or \
               read_file(dsm_dir / "etc" / "synoinfo.conf")
    synoinfo_etc = read_file(dsm_dir / "etc" / "synoinfo.conf")
    kern_text = read_file(dsm_dir / "var" / "log" / "kern.log")
    messages_text = read_file(msg_path)
    dmidecode_text = read_file(dsm_dir / "result" / "dmidecode.result")
    free_text = read_file(dsm_dir / "result" / "free.result")
    df_text = read_file(dsm_dir / "result" / "df.result")
    mdstat_text = read_file(dsm_dir / "proc" / "mdstat")
    mounts_text = read_file(dsm_dir / "proc" / "mounts")
    ifconfig_text = read_file(dsm_dir / "result" / "ifconfig.result")
    ntp_text = read_file(dsm_dir / "etc" / "ntp.conf")
    ddns_text = read_file(dsm_dir / "etc" / "ddns.conf")
    resolv_text = read_file(dsm_dir / "etc" / "resolv.conf")
    rss_text = read_file(RSS_FILE)
    cpu_file_text = read_file(CPU_FILE)
    srs_de_text = read_file(SRS_DE_FILE)
    pack_text = read_file(dsm_dir / "packages.list")
    version_text = read_file(dsm_dir / "etc.defaults" / "VERSION")
    disk_xml = read_file(dsm_dir / "var" / "log" / "disk_overview.xml")

    # Parse core values
    upnp_m = re.search(r'upnpmodelname="([^"]+)"', synoinfo, re.I)
    upnp_model = upnp_m.group(1) if upnp_m else ""

    upnp_etc_m = re.search(r'upnpmodelname="([^"]+)"', synoinfo_etc, re.I)
    upnp_etc = upnp_etc_m.group(1) if upnp_etc_m else ""

    hw_m = re.search(r"syno_hw_version=(\S+)", kern_text, re.I)
    ds_hwmodel = re.sub(r"p\b", "+", hw_m.group(1).split("v")[0]) if hw_m else ""

    ds_model_m = re.search(r"] Model:\s*(.+)", kern_text, re.I)
    ds_model = re.sub(r"-", "", ds_model_m.group(1).strip()) if ds_model_m else ""

    cpu_m = re.search(r"(?:model name|Hardware)\s*:\s*(.+)", read_file(dsm_dir / "proc" / "cpuinfo"), re.I)
    ds_cpu = cpu_m.group(0).strip() if cpu_m else ""
    processor_count = grep_count(r"^processor", read_file(dsm_dir / "proc" / "cpuinfo"), re.M)
    ds_cores = read_file(dsm_dir / "proc" / "sys" / "kernel" / "syno_CPU_info_core").strip()
    ds_sn = read_file(dsm_dir / "proc" / "sys" / "kernel" / "syno_serial").strip()

    kernel_m = re.search(r"Linux version (\S+.*)", kern_text)
    kernel_version = kernel_m.group(1)[:100] if kernel_m else ""

    bios_ver = ""
    if dmidecode_text:
        bm = re.search(r"BIOS Information.*?Version:\s*([^\n]+)", dmidecode_text, re.I | re.DOTALL)
        if bm:
            bios_ver = bm.group(1).split("\n")[0].strip()

    # RAM calculation from dmidecode
    ds_mem3_lines = []
    ds_mem3_calc_byte = 0
    if dmidecode_text:
        in_dev = False
        for line in dmidecode_text.splitlines():
            if line.strip() == "Memory Device":
                in_dev = True
            elif line.strip() == "" and in_dev:
                in_dev = False
            elif in_dev and re.match(r"\s*Size:", line):
                size_str = re.sub(r"\s*Size:\s*", "", line).strip()
                if "No Module" not in size_str:
                    ds_mem3_lines.append(line.strip())
                    sm2 = re.match(r"(\d+)\s*([KMGT]?)B?", size_str.replace(" ", ""))
                    if sm2:
                        mult = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}
                        ds_mem3_calc_byte += int(sm2.group(1)) * mult.get(sm2.group(2).upper(), 1)
    ds_mem3 = "\n".join(ds_mem3_lines)
    ds_mem3_calc = bytes_to_human(ds_mem3_calc_byte) if ds_mem3_calc_byte else ""

    # free.result
    free_mem_kb = 0
    swap_total_kb = 0
    swap_used_kb = 0
    if free_text:
        mm = re.search(r"^Mem:\s+(\d+)", free_text, re.M)
        if mm:
            free_mem_kb = int(mm.group(1))
        sm2 = re.search(r"^Swap:\s+(\d+)\s+(\d+)", free_text, re.M)
        if sm2:
            swap_total_kb = int(sm2.group(1))
            swap_used_kb = int(sm2.group(2))

    # CPU.txt memory spec
    ds_mem_txt = ""
    ds_mem_txt_byte = 0
    for line in cpu_file_text.splitlines():
        if re.match(rf"^{re.escape(upnp_model)}\s", line):
            parts = line.split()
            if len(parts) >= 2:
                ds_mem_txt = " ".join(parts[-2:])
                tmm = re.match(r"(\d+)\s*([KMGT]?)B?", ds_mem_txt.replace(" ", ""))
                if tmm:
                    mult = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}
                    ds_mem_txt_byte = int(tmm.group(1)) * mult.get(tmm.group(2).upper(), 1)
            break

    # DSM version
    dsm_version = dsm_build = dsm_smallfix = ""
    dsm_build_num = 0
    for line in version_text.splitlines():
        if "productversion" in line:
            dsm_version = line.strip()
        elif "buildnumber" in line:
            dsm_build = line.strip()
            bm = re.search(r'"(\d+)"', line)
            if bm:
                dsm_build_num = int(bm.group(1))
        elif "smallfixnumber" in line:
            dsm_smallfix = line.strip()

    # Latest DSM build from RSS
    ds_upnp_plus = upnp_model.replace("+", "%2B") + "_"
    latest_build_num = 0
    lm = re.search(rf"{re.escape(ds_upnp_plus)}.*?_(\d+)\.pat", rss_text, re.I)
    if lm:
        latest_build_num = int(lm.group(1))

    # Misc
    hostname = read_file(dsm_dir / "etc" / "hostname").strip()

    quickconnect_echo = ""
    qc_conf = dsm_dir / "usr" / "syno" / "etc" / "synorelayd" / "synorelayd.conf"
    if qc_conf.exists():
        am = re.search(r'"alias"\s*:\s*"([^"]+)"', read_file(qc_conf))
        quickconnect_echo = (
            f"QuickConnect Hostname: {am.group(1)}.quickconnect.to"
            if am
            else "No QuickConnect alias is set"
        )

    ddns_on = "service=true" in ddns_text
    ipv6_count = grep_count(r"inet6 addr", ifconfig_text)
    dropped_sum = sum(int(v) for v in re.findall(r"dropped:(\d+)", ifconfig_text))
    error_sum = sum(int(v) for v in re.findall(r"errors:(\d+)", ifconfig_text))

    # Extension units
    ext_units = []
    ext_plain_lines = []
    scsi_base = dsm_dir / "sys" / "class" / "scsi_host"
    if scsi_base.is_dir():
        for pm in scsi_base.glob("host*/syno_pm_info"):
            pm_text = read_file(pm)
            dm = re.search(r'syno_device_list[^"]*"([^"]+)"', pm_text)
            hdds = re.sub(r"/dev/", "", dm.group(1)) if dm else ""
            um = re.search(r'Unique[^"]*"([^"]+)"', pm_text)
            unit = um.group(1) if um else ""
            if unit:
                ext_units.append(f"{unit} with {hdds}")
                ext_plain_lines.append(f"{unit}:{hdds}")
    ext_plain_path = dsm_dir / "Ext_plain"
    if ext_plain_lines:
        ext_plain_path.write_text("\n".join(ext_plain_lines) + "\n")

    uptime_text = read_file(dsm_dir / "result" / "uptime.result").strip()

    # SYSDB
    sysdb_text = ""
    sysdb_path = dsm_dir / "var" / "log" / "synolog" / "synosys.log"
    synosysdb_path = dsm_dir / "var" / "log" / "synolog" / ".SYNOSYSDB"
    if sysdb_path.exists():
        sysdb_text = read_file(sysdb_path)
    elif synosysdb_path.exists():
        try:
            conn = sqlite3.connect(str(synosysdb_path))
            rows = conn.execute(
                "select id, datetime(time,'unixepoch','localtime'), username, msg from logs;"
            ).fetchall()
            conn.close()
            sysdb_text = "\n".join(f"{r[0]} {r[1]} {r[2]} {r[3]}" for r in rows)
            sysdb_path = dsm_dir / "SYSDB.log"
            sysdb_path.write_text(sysdb_text)
        except Exception as e:
            log(f"sqlite3 error: {e}")

    sysdb_tac_path = dsm_dir / "var" / "log" / "synolog" / "synosystac.log"
    if sysdb_text:
        sysdb_tac_path.parent.mkdir(parents=True, exist_ok=True)
        sysdb_tac_path.write_text("\n".join(reversed(sysdb_text.splitlines())) + "\n")

    # Package versions
    pkg_versions = {}
    if PACKAGE_VERSIONS.exists():
        for line in PACKAGE_VERSIONS.read_text().splitlines():
            p = line.split(" ", 1)
            if len(p) == 2 and p[1].strip():
                pkg_versions[p[0]] = p[1].strip()

    # Installed packages
    installed_pkgs = []
    if pack_text:
        for line in pack_text.splitlines()[1:]:
            parts = line.split()
            if parts:
                rev = list(reversed(parts[1:])) + [parts[0]]
                if rev:
                    installed_pkgs.append(rev[0])
        installed_pkgs = [p for p in installed_pkgs if p]
        (dsm_dir / "packages_ver.list").write_text("\n".join(installed_pkgs) + "\n")

    synopkg_path = dsm_dir / "var" / "log" / "synopkg.log"
    synopkg_text = ""
    if synopkg_path.exists():
        if synopkg_path.stat().st_size == 0:
            xz1 = synopkg_path.parent / "synopkg.log.1.xz"
            if xz1.exists():
                try:
                    with lzma.open(xz1) as lf:
                        synopkg_text = lf.read().decode(errors="replace")
                except Exception:
                    pass
        else:
            synopkg_text = read_file(synopkg_path)

    # SMART files
    result_dir = dsm_dir / "result"
    smart_txz_dir = dsm_dir / "var" / "log" / "smart_result"
    if smart_txz_dir.is_dir():
        txz_files = sorted(smart_txz_dir.glob("*.txz"))
        if txz_files:
            try:
                with tarfile.open(txz_files[-1], "r:xz") as tf:
                    tf.extractall(result_dir)
                extracted_dir = result_dir / "var" / "log" / "smart_result"
                if extracted_dir.is_dir():
                    for sub in extracted_dir.iterdir():
                        if sub.is_dir():
                            for sf in sub.iterdir():
                                (result_dir / f"sd_{sf.name}.result").write_bytes(sf.read_bytes())
            except Exception as e:
                log(f"smart txz extraction error: {e}")

    smart_files = []
    if result_dir.is_dir():
        for pat in ["sd*", "nv*", "smart*", "sas[0-9]*"]:
            smart_files.extend(f for f in result_dir.glob(pat) if f.is_file())
    smart_files = sorted(set(smart_files))

    # Aggregate SMART
    bad_sum = pend_sum = unc_sum = 0
    bad_hdds = pend_hdds = unc_hdds = []
    bad_hdds, pend_hdds, unc_hdds = [], [], []

    for sf in smart_files:
        s = parse_smart(sf)
        if s["reallocated"] > 0:
            bad_sum += s["reallocated"]
            bad_hdds.append(sf.name)
        if s["pending"] > 0:
            pend_sum += s["pending"]
            pend_hdds.append(sf.name)
        if s["offline_unc"] > 0:
            unc_sum += s["offline_unc"]
            unc_hdds.append(sf.name)

    # FS errors
    btrfs_pat = r"btrfs (?:critical|error|warning)|btrfs.*(?:failure|failed)|BTRFS: superblock checksum mismatch"
    ext4_pat = r"ext-[34]"
    btrfs_kern = [l for l in kern_text.splitlines() if re.search(btrfs_pat, l, re.I)]
    ext4_kern = [l for l in kern_text.splitlines() if re.search(ext4_pat, l, re.I) and "scripts/ext-3.4" not in l]
    btrfs_msg = [l for l in messages_text.splitlines() if re.search(btrfs_pat, l, re.I)]
    ext4_msg = [l for l in messages_text.splitlines() if re.search(ext4_pat, l, re.I) and "scripts/ext-3.4" not in l]
    fs_error_ct = len(btrfs_kern) + len(ext4_kern) + len(btrfs_msg) + len(ext4_msg)

    # SYSDB events
    def sdb_lines(pattern):
        return [l for l in sysdb_text.splitlines() if re.search(pattern, l, re.I)]

    improper_shutdowns = sdb_lines("improper shutdown")
    volume_crashes = sdb_lines("was crashed")
    degraded_volumes = sdb_lines("degrade")
    gen_errors_all = [l for l in sysdb_text.splitlines()
                      if re.search("error", l, re.I) and "Failed to send email" not in l]
    gen_errors = list(dict.fromkeys(gen_errors_all))

    drdy_lines = list(dict.fromkeys(grep_lines("DRDY", messages_text)))
    db_malformed = grep_count("database disk image is malformed", messages_text)
    oom_kills = grep_count("out_of_memory", messages_text)
    crashes_ct = grep_count("crash", messages_text)
    call_traces = grep_count("Call Trace", messages_text)

    # Memory tests
    passed_memtest = grep_count("Memtest passed", messages_text)
    failed_memtest = grep_count("Memtest failed", messages_text)

    # Third-party packages
    first_party = (
        r"AntiVirus|AudioStation|Calendar|CloudStation|FileStation|HyperBackup|LogCenter|"
        r"MediaServer|NoteStation|PHP[0-9]\.[0-9]|PhotoStation|ProxyServer|StorageAnalyzer|"
        r"SynoFinder|SynologyApplicationService|SynologyDrive|TextEditor|USBCopy|VideoStation|"
        r"WebDAVServer|CloudSync|DownloadStation|SurveillanceStation|WebStation|VPNCenter|"
        r"MariaDB|Chat|Git|Node\.js_4|Perl|ActiveBackup|ActiveBackup-Office365|"
        r"ActiveDirectoryServer|Apache[0-9]\.[0-9]|CMS|CardDAVServer|DNSServer|DiagnosisTool|"
        r"Docker|MailClient|MailPlus-Server|OAuthService|PetaSpace|PrestoServer|PythonModule|"
        r"SSOServer|SnapshotReplication|Spreadsheet|SynologyMoments|Virtualization|iTunesServer|"
        r"TimeBackup|Java7|Java8|exFAT|PDFViewer|DocumentViewer|HighAvailability|MailServer|"
        r"MailStation|phpMyAdmin|total \d"
    )
    third_pkgs = [
        l for l in pack_text.splitlines()
        if l.strip() and not re.search(first_party, l) and "enabled" not in l.lower()
    ]

    # Samba shares
    smb_conf = dsm_dir / "etc" / "samba" / "smb.share.conf"
    smb_paths = re.findall(r"path=.+", read_file(smb_conf)) if smb_conf.exists() else []

    # iSCSI
    iscsi_lun_path = dsm_dir / "usr" / "syno" / "etc" / "iscsi_lun.conf"
    iscsi_lun_text = read_file(iscsi_lun_path) if iscsi_lun_path.exists() else ""
    iscsi_lun_bytes = sum(int(v) for v in re.findall(r"bytes=(\d+)", iscsi_lun_text))

    # Ethtool speeds
    ethtool_lines = []
    if result_dir.is_dir():
        for ef in sorted(list(result_dir.glob("ethtool.eth*.result")) +
                         list(result_dir.glob("ethtool.bond*.result"))):
            m = re.search(r"Speed.+", read_file(ef))
            if m:
                ethtool_lines.append(f"{ef.name}: {m.group(0)}")

    # Services
    synoservice_dir = dsm_dir / "usr" / "syno" / "etc" / "synoservice.override"
    samba_st = service_enabled("Samba", "samba.cfg", synoservice_dir)
    nfs_st = service_enabled("NFS", "nfsd.cfg", synoservice_dir)
    afp_st = service_enabled("AFP", "atalk.cfg", synoservice_dir)
    ntp_server_st = service_enabled("NTPServer", "ntpd-server.cfg", synoservice_dir)

    # Hibernation settings
    sata_deep = "satadeepsleeptimer=\"1\"" in synoinfo_etc
    kernel_log_max = 'kern_log_max="yes"' in synoinfo_etc
    fan_debug_m = re.search(r'enable_fan_debug="([^"]+)"', synoinfo_etc)
    fan_debug_on = bool(fan_debug_m and int(fan_debug_m.group(1) or 0) > 0)
    sys_stat_m = re.search(r'sys_stat_dump="?([^"\s]+)"?', synoinfo_etc)
    sys_stat = sys_stat_m.group(1) if sys_stat_m else "unknown"
    standbytimer = re.search(r"^standbytimer.+", synoinfo_etc, re.M)
    standbytimer = standbytimer.group(0) if standbytimer else ""
    local_master_m = re.search(r"local master\s*=\s*(\S+)", read_file(dsm_dir / "etc" / "samba" / "smb.conf"))
    local_master = local_master_m.group(1).strip() if local_master_m else "unknown"
    supportrcpower_m = re.search(r'supportrcpower="([^"]+)"', synoinfo, re.I)
    enablercpower_m = re.search(r'enableRCPower="([^"]+)"', synoinfo, re.I)

    # Power schedule
    power_sched_path = dsm_dir / "etc" / "power_sched.conf"
    power_sched_text = read_file(power_sched_path) if power_sched_path.exists() else ""

    hb_pkg_pat = (
        r"ActiveDirectoryServer|AudioStation|CloudStation|MediaServer|SynologyDrive|"
        r"CloudSync|DownloadStation|SurveillanceStation|CMS|Docker|MailClient|"
        r"MailPlus|MailPlus-Server|PetaSpace|Virtualization|MailStation"
    )
    hb_packages = [l for l in pack_text.splitlines() if re.search(hb_pkg_pat, l)]

    # 16TB volume limitation
    vol_16tb = []
    tune2fs_dir = dsm_dir / "var" / "log" / "tune2fs"
    if tune2fs_dir.is_dir():
        for vf in tune2fs_dir.glob("dev.vg*.result"):
            vt = read_file(vf)
            if "Filesystem features" in vt and "64bit" not in vt:
                label = vf.stem.split(".")[1] if "." in vf.stem else vf.stem
                vol_16tb.append(f"{label} has 16 Terabyte Volume Limitation.")

    # Known issues list
    known_issues = []

    if upnp_model == "DS216+":
        known_issues += [
            "\nPossible Known Issue: BIOS: https://cssnew.synology.com/issue/4334",
            "Bugged Versions are less than M.616",
            f"This Machines BIOS-Version: {bios_ver}",
        ]

    if upnp_model == "DS718+":
        scemd = read_file(dsm_dir / "var" / "log" / "scemd.log")
        if grep_count("<cpu_temperature> is over", scemd) > 0:
            known_issues.append("\nCPU is overheating, RMA unit: https://cssnew.synology.com/issue/11124")
            known_issues += grep_lines("<cpu_temperature> is over", scemd)

    if grep_count(r"core_clear_root_int_from_queue Error Interrupt|Issued IDENTIFY to non-existent device", messages_text) > 0:
        known_issues.append("\nKnown Issue: random HDD drops of WD or HGST HDDs, update HDD Firmware: https://cssnew.synology.com/issue/9198")

    bios_checks = {
        "DS918+": ("M.024", "https://cssnew.synology.com/issue/12026"),
        "DS718+": ("M.220", "https://cssnew.synology.com/issue/12026"),
        "DS218+": ("M.124", "https://cssnew.synology.com/issue/12026"),
        "DS418play": ("M.310", "https://cssnew.synology.com/issue/12026"),
    }
    if upnp_model in bios_checks and bios_ver:
        min_v, url = bios_checks[upnp_model]
        if version_compare_gt(min_v, bios_ver):
            known_issues += [
                f"\nKnown Issue: BIOS: {url}",
                "Update to DSM 6.1.3-15152 Update 7 to update the BIOS.",
                f"This Machines BIOS-Version: {upnp_model} {bios_ver}",
            ]

    if re.search(r"tn40xx", kern_text, re.I) and re.search(r"memory", kern_text):
        known_issues += [
            "\nKnown Issue: with 10GbE E10G15-F1 Card detected.",
            "See https://cssnew.synology.com/issue/5206 Issue B",
        ]

    marvell_models = ["DS218j", "RS217", "RS816", "DS416j", "DS416slim", "DS216", "DS216j", "DS116"]
    if upnp_model in marvell_models:
        if grep_count(r"Can't refill, try to allocate again in cleanup timer", messages_text) > 0:
            known_issues += [
                "\nKnown Issue: https://cssnew.synology.com/issue/13942",
                "[Cause] The marvell model may suffer from memory allocating issue.",
                "[Workaround]Add the following command to a bootup task:",
                "/sbin/sysctl -w vm.min_free_kbytes=16384",
            ]

    if grep_count("btrfs_wait_pending_ordered", messages_text) > 0:
        known_issues += [
            "\nPossible Known Issue: https://cssnew.synology.com/issue/25294",
            "After updating to DSM6.2.2, the volume might get stuck.",
        ]

    scemd_path = dsm_dir / "var" / "log" / "scemd.log"
    if scemd_path.exists():
        scemd_t = read_file(scemd_path)
        if grep_count("temperature> is over", scemd_t) > 0:
            known_issues.append("\nCPU or Disk is overheating:")
            known_issues += grep_lines("temperature> is over", scemd_t)

    ha_log = read_file(dsm_dir / "var" / "log" / "ha.log")
    if grep_count('"faulty_communication":true', ha_log) > 0:
        ct = grep_count('"faulty_communication":true', ha_log)
        known_issues += [
            "\nKnown Issue: Lots of error messages 'High system usage detected' show up under HA Manager.",
            f"Showing only latest of {ct} occurences.",
            "See https://cssnew.synology.com/issue/25154",
        ]
        lns = grep_lines('"faulty_communication":true', ha_log)
        if lns:
            known_issues.append(lns[-1])

    # ============================================================
    # Write sm.log
    # ============================================================
    sm.parent.mkdir(parents=True, exist_ok=True)

    def w(s="", end="\n"):
        with open(sm, "a", encoding="utf-8") as fh:
            fh.write(str(s) + end)

    if sm_prefix:
        w(sm_prefix)
        w()

    for issue in vol_16tb:
        w(issue)

    # mdstat - md0 with errors + non-md0/md1 arrays
    if mdstat_text:
        lines = mdstat_text.splitlines()
        i = 0
        while i < len(lines):
            if re.match(r"^md0\b", lines[i]):
                ctx = lines[i: i + 3]
                if any("E" in l for l in ctx[1:]):
                    for l in ctx:
                        w(l)
            elif re.match(r"^md[^01]\b", lines[i]):
                for l in lines[i: i + 3]:
                    w(l)
            i += 1

    w("ExtensionUnits:")
    if ext_units:
        for u in ext_units:
            w(u)
    else:
        w("none")

    if upnp_etc and upnp_etc != upnp_model:
        w(f"DSM was migrated from {upnp_etc} to {upnp_model}")

    cpu_header = next((l for l in cpu_file_text.splitlines() if "CPU-Model" in l), "")
    ds_cpu_txt = next((l for l in cpu_file_text.splitlines()
                       if re.match(rf"^{re.escape(upnp_model)}\s", l)), "")
    w("\nCPUinfo from txt:")
    w(cpu_header)
    w(ds_cpu_txt + "\n")

    w(f"Reallocated_Sector_Ct: {bad_sum if bad_sum else 0}" +
      (f" on {' '.join(bad_hdds)}" if bad_hdds else ""))
    w(f"Current_Pending_Sector: {pend_sum if pend_sum else 0}" +
      (f" on {' '.join(pend_hdds)}" if pend_hdds else ""))
    w(f"Offline_Uncorrectable: {unc_sum if unc_sum else 0}" +
      (f" on {' '.join(unc_hdds)}" if unc_hdds else ""))

    # Per-HDD SMART summary
    ext_plain_text = read_file(ext_plain_path) if ext_plain_path.exists() else ""
    for sf in smart_files:
        s = parse_smart(sf)
        model = s["model"]
        mf = s["model_family"] or model or "(unknown)"

        if not model and disk_xml:
            base = sf.stem.rsplit("_", 1)[-1]
            dm = re.search(rf'{re.escape(base)}[^"]*"([^"]+)"', disk_xml, re.I)
            if dm:
                model = dm.group(1).strip()
                mf = model

        disk_upnp = upnp_model.replace("rp", "RP")
        if ext_plain_text:
            prefix = "_".join(sf.name.split("_")[:-1]) if "_" in sf.name else sf.stem
            for pl in ext_plain_text.splitlines():
                if prefix in pl:
                    disk_upnp = pl.split(":")[0].replace("rp", "RP")
                    break

        hdd_comp = check_hdd_compat(model, disk_upnp)
        poh = s["poh"]

        if not s["last_test"]:
            test_str = "never"
        elif s["last_test"] == "sas-drive":
            test_str = "unknown when run"
        elif s["last_test"].isdigit() and poh.isdigit():
            test_str = f"{int(poh) - int(s['last_test'])} hours ago"
        else:
            test_str = "unknown when run"

        parts = [f"Last Extended SMART-Test: {test_str}"]
        if s["last_result"]:
            parts.append(s["last_result"])
        if s["sector_size"]:
            parts.append(f"Sectors: {s['sector_size']}")
        parts.append(f"Size: {s['capacity']}")

        w(f"{sf.name}: {mf}\t{hdd_comp}: PowerOnHours: {poh}")
        w(", ".join(parts))

    # Memory tests
    w(f"\nMemory Tests: ", end="")
    if passed_memtest > 0:
        w(f"{passed_memtest} Memory tests have passed.")
        for l in grep_lines("Memtest passed", messages_text):
            w(l)
    if failed_memtest > 0:
        w(f"Found {failed_memtest} failed Memtests:")
        for l in grep_lines("Memtest failed", messages_text):
            w(l)
    if passed_memtest == 0 and failed_memtest == 0:
        w("No Memory tests have been run.")

    # Mountpoints
    w("Mountpoints:")
    vol_mounts = [l.split(",")[0] for l in mounts_text.splitlines() if re.search("volume", l, re.I)]
    if vol_mounts:
        for l in vol_mounts:
            w(l)
    else:
        w("No Volumes mounted.")

    # df > 90%
    if df_text:
        over90 = []
        for l in df_text.splitlines():
            parts = l.split()
            if len(parts) >= 5:
                pct = re.sub(r"%", "", parts[4])
                try:
                    if int(pct) >= 90:
                        over90.append(l)
                except Exception:
                    pass
        if over90:
            w(f"Mountpoints more than 90% full: ({len(over90)})")
            for l in over90:
                w(l)
            w()

    # DSM update
    if latest_build_num and dsm_build_num and latest_build_num > dsm_build_num:
        w("More recent DSM Version available.")
        w("available major updates:")
        for l in grep_lines(re.escape(ds_upnp_plus), rss_text):
            w(re.sub(r"<[^>]+>", "", l))
        w()
    else:
        w("DSM Version is latest!")

    w(f"installed VERSION: {dsm_version}, {dsm_build}, {dsm_smallfix}")

    # RAM comparison
    if ds_mem3_calc_byte and ds_mem_txt_byte:
        if ds_mem3_calc_byte > ds_mem_txt_byte:
            w(f"More RAM installed! {ds_mem3_calc} vs {ds_mem_txt} preinstalled")
        elif free_mem_kb * 1024 > ds_mem_txt_byte:
            w(f"More RAM installed! {bytes_to_human(free_mem_kb * 1024)} vs {ds_mem_txt} preinstalled")
        elif ds_mem3_calc_byte == ds_mem_txt_byte:
            w("same RAM installed as preinstalled!")

    w(f"Uptime:  {uptime_text}")
    w(f"Hostname:  {hostname}")
    if quickconnect_echo:
        w(quickconnect_echo)

    if ddns_on:
        ddns_host_m = re.search(r"hostname.+", ddns_text)
        w("DDNS " + (ddns_host_m.group(0) if ddns_host_m else ""))

    w(f"BIOS: {bios_ver}")
    w(f"Hardware Version: {ds_hwmodel} and Diskstationmodel: {ds_model}")
    w(f"UPNP Model: {upnp_model}")
    w(f"Kernel: {kernel_version}")
    w(f"CPU from logs: {ds_cpu}; Threads: {processor_count} , Cores: {ds_cores}")
    w(f"Serialnumber: {ds_sn}")
    ticket_url = (
        "https://cssnew.synology.com/ticket?list_type=agent_all&sort_by=update_time"
        "&sort_direction=desc&filter=%7B%22search_column%22%3A%5B%22ticket_id%22%2C"
        f"%22content%22%5D%2C%22sn%22%3A%22{ds_sn}%22%7D"
    )
    w(f"Associated Tickets: \t{ticket_url}")

    if swap_total_kb > 0:
        pct = f"{swap_used_kb / swap_total_kb * 100:.2f}"
        w(f"\nSwap: ({pct}%) used {bytes_to_human(swap_used_kb * 1024)} of {bytes_to_human(swap_total_kb * 1024)}")

    if ds_mem3:
        w(f"\nInstalled RAM-modules:\n{ds_mem3}")
    if ds_mem3_calc:
        w(f"RAM, calced: {ds_mem3_calc}")
    w(f"RAM free.result: {bytes_to_human(free_mem_kb * 1024)}")
    w()

    # Samba
    if smb_conf.exists():
        if smb_paths:
            w(f"Found Samba-shares:\n{chr(9).join(smb_paths)}\n")
        else:
            w("No Samba Shares found.\n")

    # iSCSI
    if iscsi_lun_path.exists():
        if not iscsi_lun_text or iscsi_lun_path.stat().st_size < 1:
            w("\nLUN-Config-file is empty.")
        else:
            w("\nFound LUNs:")
            w(iscsi_lun_text)
            w(f"Combined LUN Size: {bytes_to_human(iscsi_lun_bytes)}\n")

    for conf_name, label in [("iscsi_mapping.conf", "iSCSI Mapping:"),
                              ("iscsi_target.conf", "iSCSI Targets:")]:
        cp = dsm_dir / "usr" / "syno" / "etc" / conf_name
        if cp.exists():
            w(label)
            w(read_file(cp))

    # Package update checks
    if installed_pkgs:
        for pkg in installed_pkgs:
            avail = re.sub(r"-", ".", pkg_versions.get(pkg, ""))
            inst = ""
            if synopkg_text:
                ms = re.findall(rf"{re.escape(pkg)} (\S+)", synopkg_text)
                if ms:
                    inst = re.sub(r"-", ".", ms[-1])
            if avail and inst and version_compare_gt(avail, inst):
                w(f"Update for {pkg} from {inst} to {avail} available!")

        w("\n")
        w("Overview:")
        if old_dsm_warning:
            w("(Data may be unreliable, because of old DSM Version)")

        w(f"Third Party packages:\t{'none' if not third_pkgs else len(third_pkgs)}")
        w(f"Ext4-/Btrfs-Errs:\t\t{'none' if fs_error_ct == 0 else fs_error_ct}")
        w(f"improper shutdowns:\t\t{'none' if not improper_shutdowns else len(improper_shutdowns)}")
        w(f"Volume crashes:\t\t\t{'none' if not volume_crashes else len(volume_crashes)}")
        w(f"degraded volumes:\t\t{'none' if not degraded_volumes else len(degraded_volumes)}")
        w(f"generic errs:\t\t\t{'none' if not gen_errors else len(gen_errors)}")
        w(f"DRDY:\t\t\t\t\t{'none' if not drdy_lines else len(drdy_lines)}")
        w(f"Database is malformed:\t{'none' if db_malformed == 0 else db_malformed}")
        w(f"Out of Memory kills:\t{'none' if oom_kills == 0 else oom_kills}")
        w(f"generic crashes:\t\t{'none' if crashes_ct == 0 else crashes_ct}")
        w(f"Call Traces:\t\t\t{'none' if call_traces == 0 else call_traces}")
        w()
        w("Third Party packages:", end="")
        if not third_pkgs:
            w("\tnone")
        else:
            w("\n" + "\n".join(third_pkgs) + "\n")

    # FS errors detail
    all_fs = btrfs_kern + ext4_kern + btrfs_msg + ext4_msg
    if not all_fs:
        w("Ext4-/Btrfs-Errs:\t\tnone")
    else:
        w("\nExt4-/Btrfs-Errors:")
        for l in all_fs:
            w(l)

    # SRS
    if upnp_model and upnp_model in srs_de_text:
        w("\nNAS can be SRSed in DE! ( enabled )")
    else:
        w("\nno DE-SRS possible. ( disabled )")

    w("IPv6 enabled" if ipv6_count > 0 else "IPv6 disabled")
    w(f"found {dropped_sum} dropped Packages in ifconfig.result.")
    w(f"found {error_sum} bugged Packages in ifconfig.result.")
    for eth in ethtool_lines:
        w(eth)

    w("DNS Servers:")
    dns_servers = re.findall(r"^nameserver .+", resolv_text, re.M)
    w(", ".join(dns_servers) if dns_servers else "/etc/resolv.conf not found.")

    w(samba_st)
    w(nfs_st)
    w(afp_st)

    for ki in known_issues:
        w(ki)

    # SYSDB details
    if not improper_shutdowns:
        w("improper shutdowns:\t\tnone")
    else:
        w("improper shutdowns:")
        w("\n".join(improper_shutdowns))
        w()

    if not volume_crashes:
        w("Volume crashes:\t\t\tnone")
    else:
        w("Volume crashes:")
        w("\n".join(volume_crashes))
        w()

    if not degraded_volumes:
        w("degraded volumes:\t\tnone")
    else:
        w("degraded volumes:")
        w("\n".join(degraded_volumes))
        w()

    if not gen_errors:
        w("generic errs:\t\t\tnone")
    else:
        w(f"{len(gen_errors)} generic errs:")
        w("\n".join(gen_errors))
        w()

    # Messages detail
    if messages_text:
        if not drdy_lines:
            w("DRDY:\t\t\t\t\tnone")
        else:
            w(f"{len(drdy_lines)} times DRDY, showing 20 max:")
            all_lines = messages_text.splitlines()
            shown = set()
            count = 0
            for i, line in enumerate(all_lines):
                if re.search("DRDY", line, re.I) and count < 20:
                    for j in range(max(0, i - 5), min(len(all_lines), i + 11)):
                        if j not in shown:
                            w(all_lines[j])
                            shown.add(j)
                    count += 1
            w()

        if db_malformed == 0:
            w("Database is malformed:\tnone")
        else:
            w(f"{db_malformed} times malformed database, showing 20 max:")
            for l in grep_lines("database disk image is malformed", messages_text)[-20:]:
                w(l)
            w()

        if oom_kills == 0:
            w("Out of Memory kills:\tnone")
        else:
            w(f"{oom_kills} times Out of Memory kills, showing 20 max:")
            for l in grep_lines("out_of_memory", messages_text)[-20:]:
                w(l)
            w()

        if crashes_ct == 0:
            w("generic crashes:\t\tnone")
        else:
            w(f"{crashes_ct} times generic crashes, showing 100 max:")
            for l in grep_lines("crash", messages_text)[:100]:
                w(l)
            w()

        if call_traces == 0:
            w("Call Traces:\t\t\tnone")
        else:
            w(f"{call_traces} Call traces, showing 20 most recent + next 25 lines:")
            all_lines = messages_text.splitlines()
            ct_count = 0
            for i, line in enumerate(all_lines):
                if re.search("Call Trace", line, re.I) and ct_count < 20:
                    for l in all_lines[i: i + 26]:
                        w(l)
                    w()
                    ct_count += 1

    # ============================================================
    # Write smartgrep
    # ============================================================
    sg.parent.mkdir(parents=True, exist_ok=True)
    with open(sg, "w", encoding="utf-8") as fsg:
        def ws(s=""):
            fsg.write(str(s) + "\n")

        if df_text:
            over90 = []
            for l in df_text.splitlines():
                parts = l.split()
                if len(parts) >= 5:
                    try:
                        if int(re.sub(r"%", "", parts[4])) >= 90:
                            over90.append(l)
                    except Exception:
                        pass
            if over90:
                ws(f"Mountpoints more than 90% full: ({len(over90)})")
                for l in over90:
                    ws(l)
            else:
                ws("Mountpoints more than 90% full: (0)")
                ws("No full Mountpoints found.")
            ws("\n")

        ws(mdstat_text)
        ws("\nMountpoints:")
        ws(mounts_text)
        ws(" \n")

        for sf in smart_files:
            if sf.is_file():
                t = read_file(sf)
                for l in t.splitlines():
                    if re.search(r"Model Family|Device Model|User Capacity", l, re.I):
                        ws(l)

        smart_grep_attrs = (
            r"overall-health self-assessment|Model Family|Device Model|Serial Number|"
            r"Firmware Version|User Capacity|Sector Sizes|Rotation Rate|ID#|"
            r"Raw_Read_Error_Rate|Reallocated_Sector_Ct|Seek_Error_Rate|Spin_Retry_Count|"
            r"Calibration_Retry_Count|Reallocated_Event_Count|Current_Pending_Sector|"
            r"Offline_Uncorrectable|UDMA_CRC_Error_Count|Multi_Zone_Error_Rate|"
            r"Power_On_Hours|Reallocated_Sector_Count|Power-on_Hours|"
            r"Program_Fail_Count_\(total\)|Erase_Fail_Count_\(total\)|Runtime_Bad_Count_\(total\)|"
            r"Uncorrectable_Error_Count|Uncorrectable_Error_Cnt|Off-Line_Scan_Uncorrectable_Sector_Count|"
            r"Airflow_Temperature_Cel|ECC_Error_Rate|CRC_Error_Count|POR_Recovery_Count|Percent_Lifetime_Remain"
        )
        for sf in smart_files:
            if not sf.is_file():
                continue
            name = sf.name
            is_sas = name.startswith("smart_sas") or bool(re.match(r"sas\d", name))
            t = read_file(sf)
            ws(f"\n\n{sf}")
            if is_sas:
                for l in t.splitlines():
                    if re.search(
                        r"Vendor|Product|Revision|Compliance|User Capacity|block size|"
                        r"Rotation|Form Factor|Serial Number|SMART support is|Temperature Warning",
                        l, re.I,
                    ):
                        ws(l)
            else:
                for l in t.splitlines():
                    if re.search(smart_grep_attrs, l, re.I):
                        ws(l)
                ws()
                in_err = False
                for l in t.splitlines():
                    if re.match(r"SMART Error Log Version: 1", l):
                        in_err = True
                        continue
                    if in_err:
                        if "Selective self-test flags" in l:
                            break
                        ws(l)
            ws(" \n \n")

    # ============================================================
    # Write hibernation_debug.log
    # ============================================================
    hb.parent.mkdir(parents=True, exist_ok=True)
    with open(hb, "w", encoding="utf-8") as fhb:
        def wh(s=""):
            fhb.write(str(s) + "\n")

        if ntp_text:
            if "time.google.com" in ntp_text:
                wh("NTP-Client on NAS is on. Server is time.google.com")
            elif "pool.ntp.org" in ntp_text:
                wh("NTP-Client on NAS is on. Server is pool.ntp.org")
            else:
                sm2 = re.search(r"^server (.+)", ntp_text, re.M)
                if sm2:
                    wh(f"NTP-Client on NAS is on. Server is {sm2.group(1)}")
                else:
                    wh("Time set to manual, NTP-Client on NAS is off.")

        wh(ntp_server_st)
        wh("QuickConnect on NAS is " + ("on." if quickconnect_echo and "No QuickConnect" not in quickconnect_echo else "off."))
        wh("DDNS on NAS is " + ("on." if ddns_on else "off."))
        wh("IPv6 on NAS is " + ("on." if ipv6_count > 0 else "off."))
        wh(f"\nHibernation on NAS is {'on.' if sata_deep else 'off.'}")
        wh("Fan debug mode on NAS is " + ("on." if fan_debug_on else "off."))
        wh("Extended kernel logging on NAS is " + ("on." if kernel_log_max else "off."))
        wh(f"Log system status periodically on NAS is {sys_stat}.")
        wh(f"Local Master Browser on NAS is {local_master}.")

        if supportrcpower_m:
            val = supportrcpower_m.group(1)
            wh(f"supportrcpower on NAS is {'on.' if val == 'yes' else 'off.'}")
        if enablercpower_m:
            val = enablercpower_m.group(1)
            wh(f"enablercpower on NAS is {'on.' if val == 'yes' else 'off.'}")

        if standbytimer:
            wh(standbytimer)

        wh("Packages interfering with Hibernation:", end="")
        if not hb_packages:
            wh("\t\tnone.")
        else:
            wh("\n" + "\n".join(hb_packages))

        if power_sched_text:
            wh("\n")
            wh(power_sched_text)
            if POWER_SCHED_PY.exists():
                for line in power_sched_text.splitlines():
                    if line.strip().isdigit():
                        try:
                            r = subprocess.run(
                                [sys.executable, str(POWER_SCHED_PY), line.strip()],
                                capture_output=True, text=True, timeout=5,
                            )
                            wh(r.stdout.strip())
                        except Exception:
                            pass
        else:
            wh("power_sched.conf not found.")

        wh(samba_st)

    print(f"{datetime.now():%d. %B %H:%M:%S}: analysis complete → {sm}")
    return sm, sg, hb, dsm_dir


# ---------------------------------------------------------------------------
# Open in editor
# ---------------------------------------------------------------------------

def open_in_editor(files: list):
    editor = find_editor()
    existing = [str(f) for f in files if f and Path(str(f)).exists()]
    if not existing:
        return
    if not editor:
        print("No editor found. Result files:")
        for f in existing:
            print(f"  {f}")
        return

    if platform.system() == "Windows":
        for f in existing:
            os.startfile(f)
    else:
        for f in existing:
            subprocess.Popen([editor, f])
            time.sleep(0.1)


# ---------------------------------------------------------------------------
# Process one .dat file
# ---------------------------------------------------------------------------

def process_file(filepath: Path, download_dir: Path):
    while filepath.with_suffix(filepath.suffix + ".part").exists():
        time.sleep(SLEEP_EXTRACT_ZIP)

    print(f"{datetime.now():%d. %B %H:%M:%S}: found .dat-file! Extracting...")
    t0 = time.time()

    try:
        debug_dir, date_str = extract_dat(filepath, download_dir)
    except Exception as e:
        print(f"Extraction failed: {e}")
        kapott = download_dir / "kapott"
        kapott.mkdir(exist_ok=True)
        ts = datetime.now().strftime("%H%M%S")
        shutil.move(str(filepath), str(kapott / f"debug_{ts}.dat"))
        return

    shutil.move(str(filepath), str(debug_dir))
    print(f"{datetime.now():%d. %B %H:%M:%S}: extracted to {debug_dir}")

    sm_prefix = ""
    if filepath.name == "passive_debugfile.dat":
        sm_prefix = "Synology HA: Detected, this is the PASSIVE Server-log"
    elif filepath.name == "passive_UC.dat":
        sm_prefix = "Synology UC: Detected, this is the PASSIVE Server-log"

    ha_passive = debug_dir / "HighAvailability" / "passive_debug.dat"
    if ha_passive.exists():
        shutil.move(str(ha_passive), str(download_dir / "passive_debugfile.dat"))
        sm_prefix = "Synology HA: Detected, this is the ACTIVE Server-log"

    uc_remote = debug_dir / "remote.debug.dat"
    if uc_remote.exists():
        shutil.move(str(uc_remote), str(download_dir / "passive_UC.dat"))
        sm_prefix = "Synology UC: Detected, this is the ACTIVE Server-log"

    # Router USB share
    vol_usb = debug_dir / "volumeUSB1"
    if vol_usb.is_dir():
        for sub in vol_usb.iterdir():
            tmp_p = sub / "@tmp"
            if tmp_p.is_dir():
                for sf in tmp_p.iterdir():
                    if "SupportFormAttach" in sf.name:
                        for item in list(sf.iterdir()):
                            shutil.move(str(item), str(debug_dir))
                        break
        shutil.rmtree(str(vol_usb), ignore_errors=True)

    sm, sg, hb, dsm_dir = analyze(debug_dir, download_dir, sm_prefix)

    # Build file list for editor
    def ep(relpath):
        p = dsm_dir / relpath
        return str(p) if p.exists() else None

    disk_log = ep("var/log/disk_log.xml") or ep("var/log/disk.log")
    pics = (list(debug_dir.glob("*.jpg")) + list(debug_dir.glob("*.JPG")) +
            list(debug_dir.glob("*.png")) + list(debug_dir.glob("*.PNG")))

    open_in_editor([
        str(debug_dir),
        str(sg),
        ep("packages_onoff.list"),
        ep("var/log/bash_history.log"),
        str(hb),
        ep("var/log/hibernation.log"),
        ep("result/df.result"),
        ep("space.xml"),
        disk_log,
        ep("var/log/kern.log"),
        ep("var/log/synolog/synosystac.log"),
        ep("var/log/messages.log"),
        str(sm),
    ] + [str(p) for p in pics])

    print(f"Total time: {time.time() - t0:.2f}s")


# ---------------------------------------------------------------------------
# Watch loop + main
# ---------------------------------------------------------------------------

def watch(download_dir: Path):
    print("Waiting for debug-files...")
    while True:
        for dat in sorted(download_dir.glob("*.dat")):
            if dat.is_file():
                process_file(dat, download_dir)
        time.sleep(SLEEP_SCAN_DIR)


def main():
    global verbose

    parser = argparse.ArgumentParser(
        description="Synology debug file extractor and analyzer", add_help=False
    )
    parser.add_argument("-d", metavar="PATH", help="Download directory to watch (absolute path)")
    parser.add_argument("-u", action="store_true", help="Update cached data and exit")
    parser.add_argument("-v", action="store_true", help="Verbose output")
    parser.add_argument("-h", action="store_true", help="Show help")
    args = parser.parse_args()

    if args.h:
        print("\navailable commandline-arguments are:\n")
        print("\t-h : Show this help")
        print("\t-u : Update SRS-List, DSM-Updates, HDD-(in-)compatibility-lists, package updates")
        print("\t-v : Be Verbose")
        print("\t-d : Set Download directory to scan (use absolute path) [required]")
        print('\t     example: entpacker.py -d "/home/thomas/Downloads/neu"')
        print()
        sys.exit(0)

    if args.v:
        verbose = True

    if args.u:
        if not args.d:
            print("Error: -d required with -u")
            sys.exit(1)
        print("updating files:")
        update_dsm_updates_list()
        update_srs_list()
        update_compatibility_lists()
        update_package_versions_list()
        sys.exit(0)

    if not args.d:
        print(f"Usage: {Path(sys.argv[0]).name} -d \"/absolute/path\" [-h show help]")
        sys.exit(1)

    download_dir = Path(args.d)
    if not download_dir.is_absolute():
        print(f"Error: path must be absolute.")
        sys.exit(1)
    if not download_dir.is_dir():
        print(f"Error: {args.d} is not a valid directory")
        sys.exit(1)

    print(f"download directory set to {download_dir}")

    TMP_DIR.mkdir(parents=True, exist_ok=True)
    COMP_DIR.mkdir(parents=True, exist_ok=True)

    check_and_update()
    watch(download_dir)


if __name__ == "__main__":
    main()
