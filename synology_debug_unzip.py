#!/usr/bin/env python3
"""
synology_debug_unzip.py - Synology debug file extractor and analyzer
Python port of synology_debug_unzip.sh by Thomas Feldmann
Runs on Windows, Linux, and macOS.

Requirements: pip install requests
"""

import argparse
import io
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
import traceback
import zipfile
from datetime import datetime
from pathlib import Path

try:
    import requests
except ImportError:
    print("Please install requests: pip install requests")
    sys.exit(1)

# Ensure UTF-8 output on Windows (avoids cp1252 UnicodeEncodeError)
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# On Windows, extracted Linux archives contain broken symlinks that raise
# PermissionError on stat(). Patch pathlib.Path so exists/is_dir/is_file
# return False instead of crashing — affects this process only.
import pathlib as _pathlib
for _method in ("exists", "is_dir", "is_file"):
    _orig = getattr(_pathlib.Path, _method)
    def _safe(self, _f=_orig):
        try:
            return _f(self)
        except (PermissionError, OSError):
            return False
    setattr(_pathlib.Path, _method, _safe)
del _pathlib, _method, _orig, _safe

SCRIPT_DIR = Path(__file__).parent.resolve()
CPU_FILE = SCRIPT_DIR / "tmp" / "CPU.txt"
POWER_SCHED_PY = SCRIPT_DIR / "files" / "power_shed.py"
RSS_FILE = SCRIPT_DIR / "tmp" / "genRSS.php"
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


def _is_wsl() -> bool:
    try:
        with open("/proc/version") as f:
            return bool(re.search(r"Microsoft|WSL", f.read()))
    except Exception:
        return False


def _find_win_subl() -> str:
    """Search for Sublime Text on the Windows side from WSL."""
    for cmd in ("sublime_text.exe", "subl.exe"):
        found = shutil.which(cmd)
        if found:
            return found
    try:
        win_user = subprocess.run(
            ["cmd.exe", "/c", "echo %USERNAME%"],
            capture_output=True, text=True, timeout=3,
        ).stdout.strip()
    except Exception:
        win_user = ""
    candidates = [
        "/mnt/c/Program Files/Sublime Text/sublime_text.exe",
        "/mnt/c/Program Files/Sublime Text 4/sublime_text.exe",
        "/mnt/c/Program Files/Sublime Text 3/sublime_text.exe",
        "/mnt/c/Program Files/Sublime Text/subl.exe",
        "/mnt/c/Program Files/Sublime Text 4/subl.exe",
        "/mnt/c/Program Files/Sublime Text 3/subl.exe",
    ]
    if win_user:
        candidates += [
            f"/mnt/c/Users/{win_user}/AppData/Local/Programs/Sublime Text/sublime_text.exe",
            f"/mnt/c/Users/{win_user}/AppData/Local/Programs/Sublime Text 3/sublime_text.exe",
            f"/mnt/c/Users/{win_user}/AppData/Local/Programs/Sublime Text 4/sublime_text.exe",
        ]
    for c in candidates:
        if Path(c).exists():
            return c
    return ""


def find_editor():
    system = platform.system()
    if system == "Windows":
        for c in [
            r"C:\Program Files\Sublime Text\sublime_text.exe",
            r"C:\Program Files\Sublime Text 4\sublime_text.exe",
            r"C:\Program Files\Sublime Text 3\sublime_text.exe",
            r"C:\Program Files\Sublime Text\subl.exe",
            r"C:\Program Files\Sublime Text 4\subl.exe",
            r"C:\Program Files\Sublime Text 3\subl.exe",
        ]:
            if Path(c).exists():
                return c
        found = shutil.which("sublime_text") or shutil.which("subl")
        if found:
            return found
        return "notepad.exe"
    if _is_wsl():
        found = _find_win_subl()
        return found if found else "explorer.exe"
    # Prefer Flatpak Sublime Text (carries user's Log Highlight settings)
    flatpak = shutil.which("flatpak")
    if flatpak:
        try:
            r = subprocess.run([flatpak, "info", "com.sublimehq.SublimeText"],
                               capture_output=True, text=True, timeout=5)
            if r.returncode == 0:
                return "flatpak:com.sublimehq.SublimeText"
        except Exception:
            pass
    for candidate in ["subl", "sublime_text", "code", "gedit", "kate", "mousepad", "xed", "pluma", "xdg-open"]:
        if shutil.which(candidate):
            return candidate
    return None


def read_file(path) -> str:
    try:
        return Path(path).read_text(errors="replace")
    except Exception:
        return ""


def safe_is_dir(path) -> bool:
    try:
        return Path(path).is_dir()
    except (PermissionError, OSError):
        return False


def safe_exists(path) -> bool:
    try:
        return Path(path).exists()
    except (PermissionError, OSError):
        return False


def safe_glob(path, pattern):
    try:
        return list(Path(path).glob(pattern))
    except (PermissionError, OSError):
        return []


def grep_lines(pattern, text, flags=re.IGNORECASE) -> list:
    pat = re.compile(pattern, flags)
    return [line for line in text.splitlines() if pat.search(line)]


def grep_count(pattern, text, flags=re.IGNORECASE) -> int:
    pat = re.compile(pattern, flags)
    return sum(1 for line in text.splitlines() if pat.search(line))


# ---------------------------------------------------------------------------
# Update functions
# ---------------------------------------------------------------------------

def update_cpu_list():
    print("Updating CPU list from Synology KB...", end="", flush=True)
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    try:
        r = requests.get(
            "https://kb.synology.com/de-de/DSM/tutorial/What_kind_of_CPU_does_my_NAS_have",
            timeout=(5, 30),
        )
        import json as _json
        pos = r.text.find('"content":')
        if pos < 0:
            print(" error: content field not found")
            return
        try:
            content, _ = _json.JSONDecoder().raw_decode(r.text[pos + len('"content":'):])
        except Exception as e:
            print(f" error: JSON decode failed: {e}")
            return
        rows = re.findall(r"<tr>(.*?)<\/tr>", content, re.S)
        lines = ["System Model\tCPU-Model\tCores\tThreads\tFPU\tArchitecture\tRAM"]
        for row in rows:
            cells = re.findall(r"<td>(.*?)<\/td>", row, re.S)
            cells = [re.sub(r"<[^>]+>", "", c).strip() for c in cells]
            if len(cells) >= 7:
                fpu = "Ja" if "&check;" in cells[4] or "✓" in cells[4] else "Nein"
                lines.append(f"{cells[0]}\t{cells[1]}\t{cells[2]}\t{cells[3]}\t{fpu}\t{cells[5]}\t{cells[6]}")
        CPU_FILE.write_text("\n".join(lines) + "\n")
        print(f" done ({len(lines) - 1} models)")
    except Exception as e:
        print(f" error: {e}")


def update_dsm_updates_list():
    print("Downloading latest genRSS.php...", end="", flush=True)
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    try:
        r = requests.get("https://update.synology.com/autoupdate/genRSS.php", timeout=(5, 15))
        RSS_FILE.write_bytes(r.content)
        print(f" done ({len(r.content)} bytes)")
    except Exception as e:
        print(f" error: {e}")


def update_package_versions_list():
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    try:
        r = requests.get("https://archive.synology.com/download/Package/", timeout=(5, 15))
        packages = re.findall(r'href="/download/Package/([A-Za-z][^/"]*)"', r.text)
        packages = [p for p in packages if not p.startswith(".")]
        AVAILABLE_PACKAGES.write_text("\n".join(packages) + "\n")
    except Exception as e:
        print(f"Package list error: {e}")
        return

    print(f"Updating latest package versions for {len(packages)} packages", end="", flush=True)

    def fetch_version(pkg):
        url = f"https://archive.synology.com/download/Package/{pkg.replace('+', '%2B')}/"
        try:
            resp = requests.get(url, timeout=(5, 15))
            versions = re.findall(r'href="/download/Package/[^/]+/([0-9][^/"]*)"', resp.text)
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
            if verbose:
                print(f"  {pkg} -> {ver if ver else '(not found)'}")
            elif i % 30 == 0:
                print(".", end="", flush=True)
    print(" done")

    lines = [f"{pkg} {ver}" for pkg, ver in sorted(results.items()) if ver]
    PACKAGE_VERSIONS.write_text("\n".join(lines) + "\n")


def update_compatibility_lists():
    COMP_DIR.mkdir(parents=True, exist_ok=True)
    print("Getting available Models...", end="", flush=True)
    try:
        r = requests.get(
            "https://www.synology.com/cgi/misc/?action=getProductList_withOEM", timeout=(5, 15)
        )
        m = re.search(r"\[([^\]]+)\]", r.text)
        if not m:
            print(" error parsing model list")
            return
        models = [x.strip().strip('"') for x in m.group(1).split(",")]
        skip_prefixes = ("PSU ", "ioSafe ", "Power Cord", "FAN ", "Disk Tray", "Drive Tray", "Adapter ", "CPU ", "Cable ")
        models = [m for m in models if not m.startswith(skip_prefixes)]
        PRODUCT_LIST.write_text(json.dumps(models, indent=2))
        print(f" {len(models)} models done")
    except Exception as e:
        print(f" error: {e}")
        return

    total = len(models)
    print(f"Downloading compatibility lists for {total} models...")

    def fetch_compat(model):
        enc = model.replace("+", "%2B")
        base = "https://www.synology.com/api/compatibility/findHclList"
        for suffix, recommend in [("compatible", "t"), ("incompatible", "f")]:
            out = COMP_DIR / f"{model}_hdds_{suffix}.json"
            try:
                resp = requests.get(
                    f"{base}?lang=en-global&tab=drives&model={enc}&category=hdds_no_ssd_trim&recommend={recommend}",
                    timeout=(5, 15),
                )
                out.write_text(resp.text.replace("\\/", "/"))
                log(f"  {model}_hdds_{suffix}.json ({len(resp.content)} bytes)")
            except Exception as e:
                log(f"  {model}_hdds_{suffix}.json ERROR: {e}")

    def _fmt_eta(seconds):
        seconds = int(seconds)
        if seconds < 60:
            return f"{seconds}s"
        return f"{seconds // 60}m {seconds % 60:02d}s"

    start = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=40) as exe:
        futures = {exe.submit(fetch_compat, m): m for m in models}
        for done, fut in enumerate(concurrent.futures.as_completed(futures), 1):
            fut.result()
            if not verbose:
                elapsed = time.time() - start
                rate = done / elapsed
                eta = _fmt_eta((total - done) / rate) if rate > 0 else "?"
                pct = done * 100 // total
                bar = "." * (done * 20 // total)
                print(f"\r  [{bar:<20}] {done}/{total} ({pct}%) ETA: {eta}   ", end="", flush=True)
    if not verbose:
        print(f"\r  [{'.' * 20}] {total}/{total} (100%) done.              ")
    else:
        print(f"  {total}/{total} done.")


def check_and_update():
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    COMP_DIR.mkdir(parents=True, exist_ok=True)
    now = time.time()

    rss_age = now - RSS_FILE.stat().st_mtime if RSS_FILE.exists() else float("inf")
    if rss_age > 600 * 60:
        RSS_FILE.touch()
        update_dsm_updates_list()

    cpu_age = now - CPU_FILE.stat().st_mtime if CPU_FILE.exists() else float("inf")
    if cpu_age > 24 * 60 * 60:
        CPU_FILE.touch()
        update_cpu_list()

    pv_age = now - PACKAGE_VERSIONS.stat().st_mtime if PACKAGE_VERSIONS.exists() else float("inf")
    if pv_age > 24 * 60 * 60:
        PACKAGE_VERSIONS.touch()
        update_compatibility_lists()
        update_package_versions_list()


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

_WIN_INVALID = re.compile(r'[<>:"|?*\x00-\x09\x0b-\x1f]')  # control chars except \n


def _sanitize_archive_name(name: str) -> str:
    """Make an archive entry name safe for Windows: replace \n with / and strip other invalid chars."""
    name = name.replace("\n", "/").replace("\r", "/")
    return _WIN_INVALID.sub("_", name)


def _tar_extractall_safe(tf: tarfile.TarFile, dest: Path):
    """Extract tar, skipping non-regular members and sanitizing names for Windows."""
    for member in tf.getmembers():
        if not (member.isfile() or member.isdir()):
            log(f"Skipping non-regular: {member.name}")
            continue
        member.name = _sanitize_archive_name(member.name)
        try:
            kw = {"filter": "fully_trusted"} if sys.version_info >= (3, 12) else {}
            tf.extract(member, dest, set_attrs=False, **kw)
        except Exception as e:
            log(f"Skipped {member.name}: {e}")


def _zip_extractall_safe(zf: zipfile.ZipFile, dest: Path):
    """Extract zip, sanitizing names for Windows (handles \n path separators from Linux)."""
    for info in zf.infolist():
        info.filename = _sanitize_archive_name(info.filename)
        try:
            zf.extract(info, dest)
        except Exception as e:
            log(f"Skipped {info.filename}: {e}")


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
            _tar_extractall_safe(tf, dest)
    elif magic[:4] == b"PK\x03\x04":
        with zipfile.ZipFile(filepath) as zf:
            _zip_extractall_safe(zf, dest)
    else:
        with tarfile.open(filepath, "r:*") as tf:
            _tar_extractall_safe(tf, dest)

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
        # SMART columns after attribute name: FLAG VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW_VALUE
        # Skip 7 (FLAG..WHEN_FAILED) with \s+\S+, then capture RAW_VALUE with \s+(\d+)
        m = re.search(
            rf"(?i)(?:{pattern})\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)", text
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
        r"Power[_-][Oo]n[_-](?:[Hh]ours?|[Tt]ime)[_-]?(?:[Cc]ount)?\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)",
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
# Extended diagnostics helpers
# ---------------------------------------------------------------------------

def parse_mdstat_rebuild(mdstat_text: str) -> list:
    """Return list of rebuild/resync/check progress lines from mdstat."""
    out = []
    if not mdstat_text:
        return out
    lines = mdstat_text.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^(md\d+)\s*:\s*active", line)
        if not m:
            continue
        array = m.group(1)
        for j in range(i + 1, min(i + 5, len(lines))):
            sub = lines[j]
            pm = re.search(
                r"(recovery|resync|check|reshape)\s*=\s*([\d.]+%)"
                r"(?:.*?\((\d+)/(\d+)\))?"
                r"(?:.*?finish\s*=\s*([\d.]+min))?"
                r"(?:.*?speed\s*=\s*(\S+))?",
                sub,
            )
            if pm:
                op, pct, cur, tot, eta, speed = pm.groups()
                parts = [f"{array} {op}: {pct}"]
                if cur and tot:
                    parts.append(f"{cur}/{tot}")
                if eta:
                    parts.append(f"ETA {eta}")
                if speed:
                    parts.append(speed)
                out.append(", ".join(parts))
                break
    return out


def parse_volume_layout(space_history_dir: Path) -> list:
    """Parse newest space_history_*.xml: return list of dicts per volume."""
    if not space_history_dir.is_dir():
        return []
    files = sorted(space_history_dir.glob("space_history_*.xml"))
    if not files:
        return []
    text = read_file(files[-1])
    out = []
    # Loop over <space> blocks
    for sp in re.finditer(r"<space\s+([^>]+)>(.*?)</space>", text, re.S):
        body = sp.group(2)
        vol_m = re.search(r'<volume\s+path="([^"]+)"\s+[^>]*?type="([^"]+)"', body)
        if not vol_m:
            continue
        vol_path = vol_m.group(1)
        fs_type = vol_m.group(2)
        raid_levels = re.findall(r'<raid\b[^>]*?level="([^"]+)"', body)
        size_m = re.search(r'total_size="(\d+)"', body)
        size = int(size_m.group(1)) if size_m else 0
        encrypted = "encrypted" in body.lower() or 'enable_encryption="yes"' in body.lower()
        disks = re.findall(r'<disk[^>]*?model="([^"]+)"', body)
        out.append({
            "path": vol_path,
            "fs": fs_type,
            "raid": "/".join(raid_levels) if raid_levels else "unknown",
            "size_bytes": size,
            "encrypted": encrypted,
            "disks": disks,
        })
    return out


def smart_temperature(smart_text: str) -> int:
    """Extract current temperature in °C from a SMART text dump.

    SMART attribute table columns are:
      [ID, NAME, FLAG, VALUE, WORST, THRESH, TYPE, UPDATED, WHEN_FAILED, RAW, ...]
    Raw value is at index 9 after split.
    """
    for name in ("Temperature_Celsius", "Airflow_Temperature_Cel",
                 "Drive_Temperature", "Composite_Temperature"):
        for line in smart_text.splitlines():
            if name not in line:
                continue
            if not re.match(rf"^\s*\d+\s+{re.escape(name)}\b", line):
                continue
            parts = line.split()
            if len(parts) >= 10 and parts[9].isdigit():
                return int(parts[9])
    # SAS/NVMe textual format
    m = re.search(r"(?:Current Drive Temperature|Temperature:)\s*(\d+)\s*C", smart_text, re.I)
    if m:
        return int(m.group(1))
    return 0


def parse_disk_health_json(path: Path) -> dict:
    """Parse Synology disk_health_information.json → {serial: status}."""
    if not path.exists():
        return {}
    try:
        import json
        data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return {}
    out = {}
    for serial, val in data.items():
        if not isinstance(val, dict):
            continue
        # Find newest date entry
        date_keys = [k for k in val.keys() if re.match(r"\d{4}-\d{2}-\d{2}", k)]
        if not date_keys:
            continue
        newest = max(date_keys)
        entry = val.get(newest, {})
        detail = entry.get("detail", {}) if isinstance(entry, dict) else {}
        status = detail.get("overview_status", "unknown")
        temp = ""
        cache = entry.get("cache", {}) if isinstance(entry, dict) else {}
        if cache.get("temperature"):
            temp = f", temp={cache['temperature']}°C"
        out[serial] = {
            "model": val.get("model", "?"),
            "status": status,
            "date": newest,
            "temp": temp,
        }
    return out


def count_auth_failures(auth_text: str) -> dict:
    """Count failed SSH/auth attempts and group by user."""
    if not auth_text:
        return {"total": 0, "ssh": 0, "by_user": {}, "by_host": {}}
    ssh_fail = 0
    by_user = {}
    by_host = {}
    for line in auth_text.splitlines():
        if not re.search(r"Failed password|authentication failure|Invalid user", line, re.I):
            continue
        ssh_fail += 1
        um = re.search(r"(?:^|\s)user=(\S+)", line) or \
             re.search(r"for(?:\s+invalid\s+user)?\s+(\S+)\s+from", line, re.I)
        if um:
            u = um.group(1).rstrip(";,")
            if u and u not in (";", ","):
                by_user[u] = by_user.get(u, 0) + 1
        hm = re.search(r"rhost=(\S+)", line) or re.search(r"from\s+(\d+\.\d+\.\d+\.\d+)", line)
        if hm and hm.group(1):
            h = hm.group(1)
            by_host[h] = by_host.get(h, 0) + 1
    return {"total": ssh_fail, "ssh": ssh_fail, "by_user": by_user, "by_host": by_host}


def parse_ups_events(messages_text: str) -> list:
    """Find UPS state changes (on-battery, low-battery, restored)."""
    if not messages_text:
        return []
    out = []
    patterns = [
        (r"on\s+battery|UPS.*on\s+battery|power\s+failure", "On battery"),
        (r"on\s+line.*power|line\s+power\s+restored|UPS.*restored", "On line power"),
        (r"low\s+battery|battery\s+low", "Low battery"),
        (r"ups.*replace|battery.*replace", "Battery needs replacement"),
        (r"apcupsd|upsmon|upsd\b|\bnut\b", "UPS monitor active"),
    ]
    for pat, label in patterns:
        ms = re.findall(rf"^.*(?:{pat}).*$", messages_text, re.M | re.I)
        if ms:
            out.append(f"{label}: {len(ms)} event(s); last: {ms[-1].strip()[:200]}")
    return out


def parse_synobackup(text: str) -> list:
    """Parse synobackup.log, return per-task summary."""
    if not text:
        return []
    tasks = {}
    for line in text.splitlines():
        m = re.match(r"^(\w+)\s+(\S+\s+\S+)\s+(\S+?):\s+(.+)$", line)
        if not m:
            continue
        level, dt, _user, msg = m.groups()
        tm = re.match(r"\[Local\]\[(\w+)\]\s+(.+)", msg) or re.match(r"\[(\w+)\]\s+(.+)", msg)
        if not tm:
            continue
        name = tm.group(1)
        action = tm.group(2)
        if name not in tasks or dt > tasks[name]["date"]:
            tasks[name] = {"date": dt, "level": level, "action": action.strip()}
    return [{"name": k, **v} for k, v in tasks.items()]


def parse_synoupdate(text: str) -> dict:
    """Parse synoupdate.log for last upgrade event."""
    if not text:
        return {}
    # Look for major patterns
    last_line = ""
    for line in text.splitlines():
        if re.search(r"start|finish|upgrade|update", line, re.I):
            last_line = line
    if not last_line:
        return {}
    dm = re.match(r"^(\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2})", last_line)
    if not dm:
        return {"last_line": last_line.strip()[:200]}
    from datetime import datetime
    try:
        dt = datetime.strptime(dm.group(1), "%Y/%m/%d %H:%M:%S")
        days_ago = (datetime.now() - dt).days
    except Exception:
        days_ago = -1
    return {"date": dm.group(1), "days_ago": days_ago, "last_line": last_line.strip()[:200]}


def parse_dpkg_failures(text: str) -> list:
    """Find failed dpkg upgrades."""
    if not text:
        return []
    out = []
    for line in text.splitlines():
        if re.search(r"(?i)error|failed|not authenticated", line) and "passed" not in line.lower():
            out.append(line.strip()[:200])
    return out[-10:]


def parse_bonding(bonding_dir: Path) -> list:
    """Parse /proc/net/bonding/* files."""
    if not bonding_dir.is_dir():
        return []
    out = []
    for bf in sorted(bonding_dir.iterdir()):
        text = read_file(bf)
        mode = re.search(r"Bonding Mode:\s*(.+)", text)
        slaves = re.findall(r"Slave Interface:\s*(\S+)", text)
        states = re.findall(r"MII Status:\s*(\S+)", text)
        out.append(
            f"{bf.name}: {mode.group(1).strip() if mode else 'unknown'} "
            f"({len(slaves)} slaves: {', '.join(slaves)}) "
            f"states: {', '.join(states)}"
        )
    return out


def hdd_vendor_summary(smart_files: list) -> str:
    """Build 'Nx WD Red, Mx Seagate' summary from SMART files."""
    counter = {}
    for sf in smart_files:
        s = parse_smart(sf)
        mf = s["model_family"] or s["model"] or "Unknown"
        # Collapse to top-level vendor/family
        for k in ("Western Digital", "WD", "Seagate", "Toshiba", "HGST",
                  "Samsung", "Hitachi", "Crucial", "Kingston", "Intel",
                  "SanDisk", "Micron", "Synology"):
            if k.lower() in mf.lower():
                counter[k] = counter.get(k, 0) + 1
                break
        else:
            counter[mf.split()[0]] = counter.get(mf.split()[0], 0) + 1
    if not counter:
        return ""
    return ", ".join(f"{v}x {k}" for k, v in sorted(counter.items(), key=lambda x: -x[1]))


def count_users_groups(etc_dir: Path) -> dict:
    """Count human users (uid >= 1000) and groups."""
    users = []
    groups = []
    pwd = etc_dir / "passwd"
    grp = etc_dir / "group"
    if pwd.exists():
        for line in read_file(pwd).splitlines():
            parts = line.split(":")
            if len(parts) >= 4:
                try:
                    if int(parts[2]) >= 1000 and parts[0] not in ("nobody",):
                        users.append(parts[0])
                except ValueError:
                    pass
    if grp.exists():
        for line in read_file(grp).splitlines():
            parts = line.split(":")
            if len(parts) >= 3:
                try:
                    if int(parts[2]) >= 100 and parts[0] not in ("nobody",):
                        groups.append(parts[0])
                except ValueError:
                    pass
    return {"users": users, "groups": groups}


def synoinfo_region(synoinfo_text: str) -> dict:
    """Extract timezone and language."""
    out = {}
    for key in ("timezone", "language", "country_code", "ntp_server"):
        m = re.search(rf'^{key}\s*=\s*"([^"]*)"', synoinfo_text, re.M)
        if m:
            out[key] = m.group(1)
    return out


def count_encrypted_shares(synoshare_dir: Path) -> int:
    """Count encrypted share configs."""
    if not synoshare_dir.is_dir():
        return -1
    count = 0
    for sf in synoshare_dir.iterdir():
        if sf.is_file():
            t = read_file(sf)
            if re.search(r'encryption\s*=\s*"?(yes|true|1)"?', t, re.I) or \
               "enc_key" in t or "EncryptedShare" in t:
                count += 1
    return count


def smart_test_schedule(synoinfo_text: str, smart_test_log: Path) -> str:
    """Determine if automatic SMART tests are scheduled."""
    sched_m = re.search(
        r'(?:disk_smart_test_schedule|smart_test_period)\s*=\s*"?(\w+)"?',
        synoinfo_text, re.I,
    )
    if sched_m and sched_m.group(1).lower() not in ("none", "no", "0", ""):
        return f"SMART self-test schedule: {sched_m.group(1)}"
    if smart_test_log.exists() and smart_test_log.stat().st_size > 100:
        return "SMART self-test schedule: history present (recent tests detected)"
    return "SMART self-test schedule: not configured"


def parse_btrfs_scrub(text: str) -> dict:
    """Parse datascrubbing.log for real scrub events (not config syncs)."""
    if not text:
        return {}
    by_vol = {}
    for line in text.splitlines():
        ts_m = re.match(r"^(\S+)\s", line)
        if not ts_m:
            continue
        ts = ts_m.group(1)

        # Start of an actual scrub: "Start btrfs data scrubbing on /volumeN"
        sm = re.search(r"Start (?:btrfs|ext4)? data scrubbing on (\S+)", line)
        if sm:
            vol = sm.group(1)
            by_vol.setdefault(vol, {})["last_start"] = ts
            continue

        # Schedule round start (no specific volume)
        if re.search(r"Start next data scrubbing round", line):
            by_vol.setdefault("(scheduled round)", {})["last_round"] = ts
            continue

        # Done: "Space '/dev/...' data scrubbing done"
        dm = re.search(r"Space '(\S+?)' data scrubbing done", line)
        if dm:
            vol = dm.group(1)
            by_vol.setdefault(vol, {})["last_finish"] = ts
            continue

        # Real errors: scrub-related uncorrectable / corruption
        if re.search(r"scrub.*(uncorrectable|corrupt|csum)", line, re.I):
            vm = re.search(r"(/volume\d+|/dev/\S+|md\d+)", line)
            vol = vm.group(1) if vm else "?"
            by_vol.setdefault(vol, {}).setdefault("errors", []).append(line.strip()[:200])
    return by_vol


def parse_qgroup_warnings(messages_text: str, kern_text: str) -> int:
    """Count qgroup over-quota events."""
    combined = messages_text + "\n" + kern_text
    return grep_count(r"qgroup.*(over|exceed|limit reach)", combined)


def docker_container_count(result_dir: Path) -> int:
    """Approximate number of running Docker containers from ethtool.docker* files."""
    if not result_dir.is_dir():
        return 0
    return len(list(result_dir.glob("ethtool.docker[a-f0-9]*.result")))


def check_smart_test_age(smart_test_log: Path) -> dict:
    """Get last test date and count tests from disk_smart_test_log.xml."""
    if not smart_test_log.exists():
        return {}
    text = read_file(smart_test_log)
    dates = re.findall(r'\b(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})', text)
    if not dates:
        return {}
    return {"count": len(dates), "newest": max(dates), "oldest": min(dates)}


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
        swap_m = re.search(r"^Swap:\s+(\d+)\s+(\d+)", free_text, re.M)
        if swap_m:
            swap_total_kb = int(swap_m.group(1))
            swap_used_kb = int(swap_m.group(2))

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
    if safe_is_dir(scsi_base):
        for pm in safe_glob(scsi_base, "host*/syno_pm_info"):
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

    # packages_onoff.list - seed with packages_ver.list, then grep syno_service.result
    if installed_pkgs:
        onoff_lines = list(installed_pkgs)
        syno_service_path = dsm_dir / "result" / "syno_service.result"
        syno_service_text = read_file(syno_service_path) if syno_service_path.exists() else ""
        if syno_service_text:
            for pkg in installed_pkgs:
                for line in syno_service_text.splitlines():
                    if pkg.lower() in line.lower():
                        onoff_lines.append(line)
        (dsm_dir / "packages_onoff.list").write_text("\n".join(onoff_lines) + "\n")

    # SMART files
    result_dir = dsm_dir / "result"
    smart_txz_dir = dsm_dir / "var" / "log" / "smart_result"
    if smart_txz_dir.is_dir():
        txz_files = sorted(smart_txz_dir.glob("*.txz"))
        if txz_files:
            try:
                with tarfile.open(txz_files[-1], "r:xz") as tf:
                    _tar_extractall_safe(tf, result_dir)
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
    btrfs_kern = [line for line in kern_text.splitlines() if re.search(btrfs_pat, line, re.I)]
    ext4_kern = [line for line in kern_text.splitlines() if re.search(ext4_pat, line, re.I) and "scripts/ext-3.4" not in line]
    btrfs_msg = [line for line in messages_text.splitlines() if re.search(btrfs_pat, line, re.I)]
    ext4_msg = [line for line in messages_text.splitlines() if re.search(ext4_pat, line, re.I) and "scripts/ext-3.4" not in line]
    fs_error_ct = len(btrfs_kern) + len(ext4_kern) + len(btrfs_msg) + len(ext4_msg)

    # SYSDB events
    def sdb_lines(pattern):
        return [line for line in sysdb_text.splitlines() if re.search(pattern, line, re.I)]

    improper_shutdowns = sdb_lines("improper shutdown")
    volume_crashes = sdb_lines("was crashed")
    degraded_volumes = sdb_lines("degrade")
    gen_errors_all = [line for line in sysdb_text.splitlines()
                      if re.search("error", line, re.I) and "Failed to send email" not in line]
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
        r"MailStation|phpMyAdmin|synocli-disk|synocli-file|synocli-monitor|synocli-net|"
        r"SynologyPhotos|SynoOnlinePack_v2|QuickConnect|total \d"
    )
    third_pkgs = [
        line for line in pack_text.splitlines()
        if line.strip() and not re.search(first_party, line) and "enabled" not in line.lower()
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
    fan_debug_on = bool(fan_debug_m and int(fan_debug_m.group(1) or "0", 0) > 0)
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
    hb_packages = [line for line in pack_text.splitlines() if re.search(hb_pkg_pat, line)]

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
            "\nPossible Known Issue: BIOS:",
            "Bugged Versions are less than M.616",
            f"This Machines BIOS-Version: {bios_ver}",
        ]

    if upnp_model == "DS718+":
        scemd = read_file(dsm_dir / "var" / "log" / "scemd.log")
        if grep_count("<cpu_temperature> is over", scemd) > 0:
            known_issues.append("\nCPU is overheating, RMA unit:")
            known_issues += grep_lines("<cpu_temperature> is over", scemd)

    if grep_count(r"core_clear_root_int_from_queue Error Interrupt|Issued IDENTIFY to non-existent device", messages_text) > 0:
        known_issues.append("\nKnown Issue: random HDD drops of WD or HGST HDDs, update HDD Firmware:")

    bios_checks = {
        "DS918+": "M.024",
        "DS718+": "M.220",
        "DS218+": "M.124",
        "DS418play": "M.310",
    }
    if upnp_model in bios_checks and bios_ver:
        min_v = bios_checks[upnp_model]
        if version_compare_gt(min_v, bios_ver):
            known_issues += [
                f"\nKnown Issue: BIOS outdated (minimum: {min_v})",
                "Update to DSM 6.1.3-15152 Update 7 to update the BIOS.",
                f"This Machines BIOS-Version: {upnp_model} {bios_ver}",
            ]

    if re.search(r"tn40xx", kern_text, re.I) and re.search(r"memory", kern_text):
        known_issues += [
            "\nKnown Issue: with 10GbE E10G15-F1 Card detected.",
            "See Issue B",
        ]

    marvell_models = ["DS218j", "RS217", "RS816", "DS416j", "DS416slim", "DS216", "DS216j", "DS116"]
    if upnp_model in marvell_models:
        if grep_count(r"Can't refill, try to allocate again in cleanup timer", messages_text) > 0:
            known_issues += [
                "\nKnown Issue:",
                "[Cause] The marvell model may suffer from memory allocating issue.",
                "[Workaround]Add the following command to a bootup task:",
                "/sbin/sysctl -w vm.min_free_kbytes=16384",
            ]

    if grep_count("btrfs_wait_pending_ordered", messages_text) > 0:
        known_issues += [
            "\nPossible Known Issue:",
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
            "See",
        ]
        lns = grep_lines('"faulty_communication":true', ha_log)
        if lns:
            known_issues.append(lns[-1])

    # ============================================================
    # Extended diagnostics (collect)
    # ============================================================
    raid_rebuild = parse_mdstat_rebuild(mdstat_text)
    volume_layout = parse_volume_layout(dsm_dir / "etc" / "space")

    # Per-HDD temperature
    hdd_temps = []
    for sf in smart_files:
        t_text = read_file(sf)
        t = smart_temperature(t_text)
        if t > 0:
            hdd_temps.append({"disk": sf.name, "temp": t})

    disk_health = parse_disk_health_json(dsm_dir / "var" / "log" / "disk_health_information.json")
    auth_text = read_file(dsm_dir / "var" / "log" / "auth.log")
    auth_failures = count_auth_failures(auth_text)
    ups_events = parse_ups_events(messages_text)

    synobackup_text = read_file(dsm_dir / "var" / "log" / "synolog" / "synobackup.log")
    backup_tasks = parse_synobackup(synobackup_text)

    synoupdate_text = read_file(dsm_dir / "var" / "log" / "synoupdate.log")
    upgrade_info = parse_synoupdate(synoupdate_text)

    dpkg_text = read_file(dsm_dir / "var" / "log" / "dpkg_upgrade.log")
    dpkg_fails = parse_dpkg_failures(dpkg_text)

    bonds = parse_bonding(dsm_dir / "proc" / "net" / "bonding")
    qgroup_warnings = parse_qgroup_warnings(messages_text, kern_text)
    docker_count = docker_container_count(result_dir)
    user_grp = count_users_groups(dsm_dir / "etc")
    region = synoinfo_region(synoinfo_etc)
    enc_share_count = count_encrypted_shares(dsm_dir / "etc" / "synoshare")
    smart_sched = smart_test_schedule(synoinfo_etc,
                                      dsm_dir / "var" / "log" / "disk_smart_test_log.xml")
    smart_test_history = check_smart_test_age(dsm_dir / "var" / "log" / "disk_smart_test_log.xml")
    btrfs_scrub = parse_btrfs_scrub(read_file(dsm_dir / "var" / "log" / "datascrubbing.log"))
    vendor_summary = hdd_vendor_summary(smart_files)

    # Load average parsing from uptime
    load_avg_warning = ""
    lm = re.search(r"load average:\s*([\d.]+),\s*([\d.]+),\s*([\d.]+)", uptime_text)
    if lm:
        try:
            la_1 = float(lm.group(1))
            if la_1 > 10.0:
                load_avg_warning = f"High load average detected: {la_1} (critical)"
            elif la_1 > 5.0:
                load_avg_warning = f"Elevated load average: {la_1} (warning)"
        except ValueError:
            pass

    # ============================================================
    # Write sm.log — section buffers
    # ============================================================
    _sections = {
        "updates": [],
        "storage": [],
        "smart": [],
        "net": [],
        "pkgs": [],
        "overview": [],
        "docker": [],
        "extended": [],
        "issues": [],
    }
    _current_section = "storage"

    def w(s="", section=None):
        _sections[section or _current_section].append(str(s))

    def set_section(name):
        nonlocal _current_section
        _current_section = name

    # ─── STORAGE ────────────────────────────────────────────────
    set_section("storage")
    for issue in vol_16tb:
        w(issue)

    # mdstat - md0 with errors + non-md0/md1 arrays
    if mdstat_text:
        lines = mdstat_text.splitlines()
        i = 0
        while i < len(lines):
            if re.match(r"^md0\b", lines[i]):
                ctx = lines[i: i + 3]
                if any("E" in line for line in ctx[1:]):
                    w("RAID:")
                    for line in ctx:
                        w(f"  {line}")
            elif re.match(r"^md[^01]\b", lines[i]):
                w("RAID:")
                for line in lines[i: i + 3]:
                    w(f"  {line}")
            i += 1

    w("ExtensionUnits:")
    if ext_units:
        for u in ext_units:
            w(f"  {u}")
    else:
        w("  none")

    if upnp_etc and upnp_etc != upnp_model:
        w(f"DSM was migrated from {upnp_etc} to {upnp_model}")

    # Mountpoints
    w("Volumes:")
    vol_mounts = [line.split(",")[0] for line in mounts_text.splitlines() if re.search("volume", line, re.I)]
    if vol_mounts:
        for line in vol_mounts:
            w(f"  {line}")
    else:
        w("  No Volumes mounted.")

    # df > 90%
    if df_text:
        over90 = []
        for line in df_text.splitlines():
            parts = line.split()
            if len(parts) >= 5:
                pct = re.sub(r"%", "", parts[4])
                try:
                    if int(pct) >= 90:
                        over90.append(line)
                except Exception:
                    pass
        if over90:
            w(f"Disk usage (>90% full): ({len(over90)})")
            for line in over90:
                w(f"  {line}")

    # ─── SMART ──────────────────────────────────────────────────
    set_section("smart")
    cpu_header = next((line for line in cpu_file_text.splitlines() if "CPU-Model" in line), "")
    ds_cpu_txt = next((line for line in cpu_file_text.splitlines()
                       if re.match(rf"^{re.escape(upnp_model)}\s", line)), "")
    if cpu_header or ds_cpu_txt:
        w("CPUinfo from txt:")
        if cpu_header:
            w(f"  {cpu_header}")
        if ds_cpu_txt:
            w(f"  {ds_cpu_txt}")
        w("")

    w(f"Reallocated_Sector_Ct:    {bad_sum if bad_sum else 0}" +
      (f" on {' '.join(bad_hdds)}" if bad_hdds else ""))
    w(f"Current_Pending_Sector:   {pend_sum if pend_sum else 0}" +
      (f" on {' '.join(pend_hdds)}" if pend_hdds else ""))
    w(f"Offline_Uncorrectable:    {unc_sum if unc_sum else 0}" +
      (f" on {' '.join(unc_hdds)}" if unc_hdds else ""))
    w("")

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

        w(f"{sf.name}: {mf}  {hdd_comp}  PowerOnHours: {poh}")
        w(f"  {', '.join(parts)}")

    # Memory tests → overview section
    if passed_memtest > 0 or failed_memtest > 0:
        set_section("overview")
        if passed_memtest > 0:
            w(f"Memory tests:               {passed_memtest} passed")
        if failed_memtest > 0:
            w(f"Memory tests:               {failed_memtest} FAILED")
    # if both 0, the overview "Memory tests: keine" line is rendered later

    # ─── UPDATES ────────────────────────────────────────────────
    set_section("updates")
    if latest_build_num and dsm_build_num and latest_build_num > dsm_build_num:
        w("Neuere Version verfügbar:")
        for line in grep_lines(re.escape(ds_upnp_plus), rss_text):
            w(f"  {re.sub(r'<[^>]+>', '', line)}")
        w(f"  (current: {dsm_version} {dsm_build} {dsm_smallfix})")
    else:
        w("DSM Version is latest.")
    w(f"installed VERSION: {dsm_version}, {dsm_build}, {dsm_smallfix}")

    # RAM comparison goes to extended
    if ds_mem3_calc_byte and ds_mem_txt_byte:
        if ds_mem3_calc_byte > ds_mem_txt_byte:
            w(f"More RAM installed! {ds_mem3_calc} vs {ds_mem_txt} preinstalled",
              section="extended")
        elif free_mem_kb * 1024 > ds_mem_txt_byte:
            w(f"More RAM installed! {bytes_to_human(free_mem_kb * 1024)} vs {ds_mem_txt} preinstalled",
              section="extended")
        elif ds_mem3_calc_byte == ds_mem_txt_byte:
            w("same RAM installed as preinstalled!", section="extended")

    # ─── NETWORK ────────────────────────────────────────────────
    set_section("net")
    w(f"IPv6:    {'enabled' if ipv6_count > 0 else 'disabled'}")
    w(f"Dropped: {dropped_sum}  ·  Errors: {error_sum}")
    for eth in ethtool_lines:
        w(f"  {eth}")

    dns_servers = re.findall(r"^nameserver .+", resolv_text, re.M)
    w(f"DNS:     {', '.join(dns_servers) if dns_servers else '(nicht gefunden)'}")

    # NTP
    ntp_text_local = read_file(dsm_dir / "etc" / "ntp.conf")
    ntp_server_line = ""
    if "time.google.com" in ntp_text_local:
        ntp_server_line = "time.google.com"
    elif "pool.ntp.org" in ntp_text_local:
        ntp_server_line = "pool.ntp.org"
    else:
        ntp_m = re.search(r"^server (.+)", ntp_text_local, re.M)
        ntp_server_line = ntp_m.group(1) if ntp_m else "manual / off"
    w(f"NTP:     {ntp_server_line}")
    w(f"DDNS:    {'on' if ddns_on else 'off'}")
    if quickconnect_echo:
        w(f"  {quickconnect_echo}")
    if ddns_on:
        ddns_host_m = re.search(r"hostname.+", ddns_text)
        if ddns_host_m:
            w(f"  DDNS {ddns_host_m.group(0)}")

    # Samba/NFS/AFP
    def _state(s):
        return s.split(" is ")[-1] if " is " in s else "unknown"
    w(f"Samba:   {_state(samba_st)}  ·  NFS: {_state(nfs_st)}  ·  AFP: {_state(afp_st)}")

    if bonds:
        w("Bonding:")
        for b in bonds:
            w(f"  {b}")

    # ─── PACKAGES ───────────────────────────────────────────────
    set_section("pkgs")
    pkg_updates = []
    if installed_pkgs:
        for pkg in installed_pkgs:
            avail = re.sub(r"-", ".", pkg_versions.get(pkg, ""))
            inst = ""
            if synopkg_text:
                ms = re.findall(rf"{re.escape(pkg)} (\S+)", synopkg_text)
                if ms:
                    inst = re.sub(r"-", ".", ms[-1])
            if avail and inst and version_compare_gt(avail, inst):
                pkg_updates.append(f"Update for {pkg} from {inst} to {avail}")

    if pkg_updates:
        for u in pkg_updates:
            w(u)
    else:
        w("Alle Pakete aktuell.")

    if third_pkgs:
        w(f"Drittanbieter: {len(third_pkgs)}")
        for p in third_pkgs:
            w(f"  {p}")
    else:
        w("Drittanbieter: keine")

    # Samba shares
    if smb_conf.exists():
        if smb_paths:
            w("Samba-shares:")
            for p in smb_paths:
                w(f"  {p}")
        else:
            w("No Samba Shares found.")

    # iSCSI
    if iscsi_lun_path.exists():
        if not iscsi_lun_text or iscsi_lun_path.stat().st_size < 1:
            w("LUN-Config-file is empty.")
        else:
            w("Found LUNs:")
            for line in iscsi_lun_text.splitlines():
                w(f"  {line}")
            w(f"Combined LUN Size: {bytes_to_human(iscsi_lun_bytes)}")

    for conf_name, label in [("iscsi_mapping.conf", "iSCSI Mapping:"),
                              ("iscsi_target.conf", "iSCSI Targets:")]:
        cp = dsm_dir / "usr" / "syno" / "etc" / conf_name
        if cp.exists():
            w(label)
            for line in read_file(cp).splitlines():
                w(f"  {line}")

    # ─── OVERVIEW ───────────────────────────────────────────────
    set_section("overview")
    if old_dsm_warning:
        w("(Data may be unreliable, because of old DSM Version)")

    def _val(n):
        return n if n else 0

    w(f"Improper shutdowns          {_val(len(improper_shutdowns))}")
    w(f"Volume crashes              {_val(len(volume_crashes))}")
    w(f"Degraded volumes            {_val(len(degraded_volumes))}")
    w(f"Ext4/Btrfs errors           {fs_error_ct}")
    w(f"Generic errors (SYSDB)      {_val(len(gen_errors))}")
    w(f"DRDY errors                 {_val(len(drdy_lines))}")
    w(f"Database malformed          {db_malformed}")
    w(f"Out of Memory kills         {oom_kills}")
    w(f"Kernel crashes              {crashes_ct}")
    w(f"Call Traces                 {call_traces}")
    w(f"Auth failures               {auth_failures['total']}")
    w(f"BTRFS qgroup warnings       {qgroup_warnings}")
    if passed_memtest == 0 and failed_memtest == 0:
        w("Memory tests                keine")
    if user_grp["users"]:
        w(f"Non-system users            {len(user_grp['users'])}")
    if enc_share_count >= 0:
        w(f"Encrypted shares            {enc_share_count}")

    # ─── DOCKER ─────────────────────────────────────────────────
    set_section("docker")
    if docker_count > 0:
        w(f"Container gesehen:  {docker_count}")
    else:
        w("Container gesehen:  keine")

    # ─── EXTENDED DIAGNOSTICS ───────────────────────────────────
    set_section("extended")
    if raid_rebuild:
        for line in raid_rebuild:
            w(f"RAID rebuild:    {line}")
    else:
        w("RAID rebuild:    keiner aktiv")

    if volume_layout:
        w("Volume layout:")
        for v in volume_layout:
            enc = " (encrypted)" if v["encrypted"] else ""
            disks = ", ".join(v["disks"][:4]) if v["disks"] else "?"
            w(f"  {v['path']}: {v['raid']} / {v['fs']}{enc}, "
              f"{bytes_to_human(v['size_bytes'])}, disks: {disks}")

    if hdd_temps:
        parts = []
        for ht in hdd_temps:
            t = ht["temp"]
            tag = ""
            if t >= 60:
                tag = " (CRIT)"
            elif t >= 50:
                tag = " (warn)"
            parts.append(f"{ht['disk']}: {t}°C{tag}")
        w(f"HDD-Temperaturen: {'  ·  '.join(parts)}")

    for sf in smart_files:
        s = parse_smart(sf)
        if s["poh"] and s["poh"].isdigit():
            hours = int(s["poh"])
            if hours > 70000:
                w(f"HDD age ERROR: {sf.name}: {hours}h (~{hours//8760}y) — replace recommended")
            elif hours > 50000:
                w(f"HDD age warning: {sf.name}: {hours}h (~{hours//8760}y)")

    if vendor_summary:
        w(f"Hersteller: {vendor_summary}")

    real_scrubs = {k: v for k, v in btrfs_scrub.items()
                   if k != "(scheduled round)" and (v.get("last_start") or v.get("last_finish") or v.get("errors"))}
    if real_scrubs:
        for vol, st in real_scrubs.items():
            start = st.get("last_start", "?")
            finish = st.get("last_finish", "?")
            errs = st.get("errors", [])
            w(f"BTRFS scrub ({vol}): last start={start}, last finish={finish}"
              f"{', ERRORS: ' + str(len(errs)) if errs else ''}")
    else:
        w("BTRFS scrub:     kein Verlauf")

    if disk_health:
        for serial, info in disk_health.items():
            state = info["status"]
            tag = ""
            if state not in ("normal", "unknown"):
                tag = " (WARNING)" if state == "warning" else " (CRITICAL)"
            w(f"Disk Health: {serial} ({info['model']}): {state}{info['temp']}{tag}")

    if dpkg_fails:
        w(f"dpkg-Upgrades:   {len(dpkg_fails)} fehlgeschlagen (showing 3):")
        for f in dpkg_fails[:3]:
            w(f"  {f}")
    else:
        w("dpkg-Upgrades:   keine fehlgeschlagen")

    if upgrade_info:
        d = upgrade_info.get("days_ago", -1)
        tag = " (RECENT: < 7 days)" if 0 <= d < 7 else ""
        w(f"Last DSM update activity: {upgrade_info.get('date', '?')} ({d} days ago){tag}")

    if auth_failures["total"] > 0:
        top_user = sorted(auth_failures["by_user"].items(), key=lambda x: -x[1])[:3]
        top_host = sorted(auth_failures["by_host"].items(), key=lambda x: -x[1])[:3]
        severity = " (WARNING)" if auth_failures["total"] >= 10 else ""
        w(f"Auth failures: {auth_failures['total']} total{severity}")
        if top_user:
            w("  Top targeted users: " +
              ", ".join(f"{u}({c})" for u, c in top_user))
        if top_host:
            w("  Top source hosts: " +
              ", ".join(f"{h}({c})" for h, c in top_host))

    if ups_events:
        w("UPS events:")
        for e in ups_events:
            w(f"  {e}")

    if backup_tasks:
        w("HyperBackup tasks:")
        for t in backup_tasks[:8]:
            tag = " (ERROR)" if t["level"] == "err" else \
                  " (warning)" if t["level"] == "warning" else ""
            w(f"  {t['name']}: {t['date']} - {t['action'][:120]}{tag}")

    if load_avg_warning:
        w(load_avg_warning)

    if region:
        w(f"DSM region: timezone={region.get('timezone', '?')}, "
          f"language={region.get('language', '?')}")

    sched_str = smart_sched.replace("SMART self-test schedule: ", "")
    w(f"SMART-Schedule:  {sched_str}")
    if smart_test_history:
        w(f"SMART tests in history: {smart_test_history['count']} "
          f"(newest: {smart_test_history['newest']})")

    # ─── ISSUES ─────────────────────────────────────────────────
    set_section("issues")
    for ki in known_issues:
        if ki.strip():
            w(ki)

    # FS errors detail — newest 20 only
    all_fs = btrfs_kern + ext4_kern + btrfs_msg + ext4_msg
    if all_fs:
        all_fs_uniq = list(dict.fromkeys(all_fs))
        ts_re = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})")
        all_fs_uniq.sort(key=lambda line: (ts_re.match(line).group(1) if ts_re.match(line) else ""))
        shown = all_fs_uniq[-20:]
        hidden = len(all_fs_uniq) - len(shown)
        if hidden > 0:
            w(f"Ext4-/Btrfs-Errors: {len(all_fs_uniq)} total — showing newest 20 ({hidden} omitted)")
        else:
            w("Ext4-/Btrfs-Errors:")
        for line in shown:
            w(f"  {line}")

    # SYSDB details (only non-empty)
    if improper_shutdowns:
        w("improper shutdowns:")
        for line in improper_shutdowns:
            w(f"  {line}")

    if volume_crashes:
        w("Volume crashes:")
        for line in volume_crashes:
            w(f"  {line}")

    if degraded_volumes:
        w("degraded volumes:")
        for line in degraded_volumes:
            w(f"  {line}")

    if gen_errors:
        w(f"{len(gen_errors)} generic errs:")
        for line in gen_errors:
            w(f"  {line}")

    # Messages detail — each section capped at newest 20
    def _emit_capped(label, lines):
        shown = lines[-20:]
        omitted = len(lines) - len(shown)
        hdr = f"{label}: {len(lines)} total — showing newest 20"
        if omitted > 0:
            hdr += f" ({omitted} omitted)"
        w(hdr + ":")
        for line in shown:
            w(f"  {line}")

    if messages_text:
        if drdy_lines:
            _emit_capped("DRDY", drdy_lines)
        if db_malformed > 0:
            _emit_capped("Database is malformed",
                         grep_lines("database disk image is malformed", messages_text))
        if oom_kills > 0:
            _emit_capped("Out of Memory kills",
                         grep_lines("out_of_memory", messages_text))
        if crashes_ct > 0:
            _emit_capped("generic crashes",
                         grep_lines("crash", messages_text))
        if call_traces > 0:
            w(f"{call_traces} Call traces, showing last one:")
            all_lines = messages_text.splitlines()
            last_ct_idx = None
            for i, line in enumerate(all_lines):
                if re.search("Call Trace", line, re.I):
                    last_ct_idx = i
            if last_ct_idx is not None:
                for line in all_lines[last_ct_idx: last_ct_idx + 26]:
                    w(f"  {line}")

    # ─── Render to sm.log ───────────────────────────────────────
    sm.parent.mkdir(parents=True, exist_ok=True)

    border = "═" * 80

    def _section_header(title):
        return f"\n── {title} " + "─" * max(2, 79 - len(title) - 3)

    def _indent(line, prefix="  "):
        if line == "" or line.startswith("  "):
            return line
        return prefix + line

    # Parse productversion value
    def _ver_val(s):
        m = re.search(r'"([^"]+)"', s)
        return m.group(1) if m else s

    dsm_version_clean = _ver_val(dsm_version)
    dsm_build_clean = _ver_val(dsm_build)
    dsm_smallfix_clean = _ver_val(dsm_smallfix)
    dsm_full = dsm_version_clean
    if dsm_build_clean:
        dsm_full += f"-{dsm_build_clean}"
    if dsm_smallfix_clean and dsm_smallfix_clean != "0":
        dsm_full += f" Update {dsm_smallfix_clean}"

    cpu_clean = re.sub(r".*:\s*", "", ds_cpu).strip() if ds_cpu else "(unknown)"

    # Uptime parse
    up_m = re.search(r"up\s+(.+?),\s*load average:\s*([\d., ]+)", uptime_text)
    if up_m:
        up_str = up_m.group(1).strip()
        load_str = up_m.group(2).strip()
    else:
        up_str = uptime_text.strip() or "(unknown)"
        load_str = ""

    ram_str = bytes_to_human(free_mem_kb * 1024) if free_mem_kb else "(unknown)"
    if swap_total_kb > 0:
        swap_pct = swap_used_kb / swap_total_kb * 100
        ram_str += f"  ·  Swap: {swap_pct:.2f}% ({bytes_to_human(swap_used_kb * 1024)} / {bytes_to_human(swap_total_kb * 1024)})"

    try:
        os.chmod(sm, 0o644)
    except (PermissionError, OSError):
        pass
    with open(sm, "w", encoding="utf-8") as _sm_fh:
        def write_sm(s=""):
            _sm_fh.write(str(s) + "\n")

        if sm_prefix:
            write_sm(sm_prefix)
            write_sm()

        # ─── HEADER ─────────────────────────────────────────────
        write_sm(border)
        title_bits = [b for b in [upnp_model, hostname, f"S/N: {ds_sn}" if ds_sn else ""] if b]
        write_sm(f"  {'  |  '.join(title_bits)}")
        write_sm(border)
        write_sm(f"  DSM:    {dsm_full}")
        write_sm(f"  Kernel: {kernel_version}")
        cpu_line = f"  CPU:    {cpu_clean}"
        if processor_count or ds_cores:
            cpu_line += f"  ·  {processor_count} Threads / {ds_cores} Cores"
        write_sm(cpu_line)
        write_sm(f"  RAM:    {ram_str}")
        up_line = f"  Uptime: {up_str}"
        if load_str:
            up_line += f"  ·  Load: {load_str}"
        write_sm(up_line)
        if bios_ver:
            write_sm(f"  BIOS:   {bios_ver}")
        if ds_hwmodel or ds_model:
            write_sm(f"  HW:     {ds_hwmodel}  ·  Model: {ds_model}")
        if ds_mem3:
            write_sm(f"  RAM-modules:")
            for line in ds_mem3.splitlines():
                write_sm(f"    {line}")
            if ds_mem3_calc:
                write_sm(f"  RAM, calced: {ds_mem3_calc}")
        write_sm(border)

        # ─── SECTIONS ───────────────────────────────────────────
        section_order = [
            ("updates", "DSM UPDATES"),
            ("storage", "STORAGE"),
            ("smart", "SMART"),
            ("net", "NETZWERK"),
            ("pkgs", "PAKETE"),
            ("overview", "OVERVIEW"),
            ("docker", "DOCKER"),
            ("extended", "EXTENDED DIAGNOSTICS"),
            ("issues", "PROBLEME & BEKANNTE FEHLER"),
        ]
        for key, title in section_order:
            write_sm(_section_header(title))
            lines = _sections[key]
            if not lines:
                continue
            for line in lines:
                if line == "":
                    write_sm("")
                elif line.startswith("  "):
                    write_sm(line)
                else:
                    write_sm(f"  {line}")
        write_sm(border)

    # ============================================================
    # Write smartgrep
    # ============================================================
    sg.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(sg, 0o644)
    except (PermissionError, OSError):
        pass
    with open(sg, "w", encoding="utf-8") as fsg:
        def write_sg(s=""):
            fsg.write(str(s) + "\n")

        if df_text:
            over90 = []
            for line in df_text.splitlines():
                parts = line.split()
                if len(parts) >= 5:
                    try:
                        if int(re.sub(r"%", "", parts[4])) >= 90:
                            over90.append(line)
                    except Exception:
                        pass
            if over90:
                write_sg(f"Mountpoints more than 90% full: ({len(over90)})")
                for line in over90:
                    write_sg(line)
            else:
                write_sg("Mountpoints more than 90% full: (0)")
                write_sg("No full Mountpoints found.")
            write_sg("\n")

        write_sg(mdstat_text)
        write_sg("\nMountpoints:")
        write_sg(mounts_text)
        write_sg(" \n")

        for sf in smart_files:
            if sf.is_file():
                t = read_file(sf)
                for line in t.splitlines():
                    if re.search(r"Model Family|Device Model|User Capacity", line, re.I):
                        write_sg(line)

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
            write_sg(f"\n\n{sf}")
            if is_sas:
                for line in t.splitlines():
                    if re.search(
                        r"Vendor|Product|Revision|Compliance|User Capacity|block size|"
                        r"Rotation|Form Factor|Serial Number|SMART support is|Temperature Warning",
                        line, re.I,
                    ):
                        write_sg(line)
            else:
                for line in t.splitlines():
                    if re.search(smart_grep_attrs, line, re.I):
                        write_sg(line)
                write_sg()
                in_err = False
                for line in t.splitlines():
                    if re.match(r"SMART Error Log Version: 1", line):
                        in_err = True
                        continue
                    if in_err:
                        if "Selective self-test flags" in line:
                            break
                        write_sg(line)
            write_sg(" \n \n")

    # ============================================================
    # Write hibernation_debug.log
    # ============================================================
    hb.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(hb, 0o644)
    except (PermissionError, OSError):
        pass
    with open(hb, "w", encoding="utf-8") as fhb:
        def write_hb(s=""):
            fhb.write(str(s) + "\n")

        if ntp_text:
            if "time.google.com" in ntp_text:
                write_hb("NTP-Client on NAS is on. Server is time.google.com")
            elif "pool.ntp.org" in ntp_text:
                write_hb("NTP-Client on NAS is on. Server is pool.ntp.org")
            else:
                ntp_m = re.search(r"^server (.+)", ntp_text, re.M)
                if ntp_m:
                    write_hb(f"NTP-Client on NAS is on. Server is {ntp_m.group(1)}")
                else:
                    write_hb("Time set to manual, NTP-Client on NAS is off.")

        write_hb(ntp_server_st)
        write_hb("QuickConnect on NAS is " + ("on." if quickconnect_echo and "No QuickConnect" not in quickconnect_echo else "off."))
        write_hb("DDNS on NAS is " + ("on." if ddns_on else "off."))
        write_hb("IPv6 on NAS is " + ("on." if ipv6_count > 0 else "off."))
        write_hb(f"\nHibernation on NAS is {'on.' if sata_deep else 'off.'}")
        write_hb("Fan debug mode on NAS is " + ("on." if fan_debug_on else "off."))
        write_hb("Extended kernel logging on NAS is " + ("on." if kernel_log_max else "off."))
        write_hb(f"Log system status periodically on NAS is {sys_stat}.")
        write_hb(f"Local Master Browser on NAS is {local_master}.")

        if supportrcpower_m:
            val = supportrcpower_m.group(1)
            write_hb(f"supportrcpower on NAS is {'on.' if val == 'yes' else 'off.'}")
        if enablercpower_m:
            val = enablercpower_m.group(1)
            write_hb(f"enablercpower on NAS is {'on.' if val == 'yes' else 'off.'}")

        if standbytimer:
            write_hb(standbytimer)

        write_hb("Packages interfering with Hibernation:")
        if not hb_packages:
            write_hb("\t\tnone.")
        else:
            write_hb("\n" + "\n".join(hb_packages))

        if power_sched_text:
            write_hb("\n")
            write_hb(power_sched_text)
            if POWER_SCHED_PY.exists():
                for line in power_sched_text.splitlines():
                    if line.strip().isdigit():
                        try:
                            r = subprocess.run(
                                [sys.executable, str(POWER_SCHED_PY), line.strip()],
                                capture_output=True, text=True, timeout=5,
                            )
                            write_hb(r.stdout.strip())
                        except Exception:
                            pass
        else:
            write_hb("power_sched.conf not found.")

        write_hb(samba_st)

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

    print(f"Opening editor: {editor}")
    try:
        if _is_wsl():
            # Convert Linux paths to Windows paths and open all at once
            win_paths = []
            for f in existing:
                try:
                    r = subprocess.run(["wslpath", "-w", f], capture_output=True, text=True)
                    win_paths.append(r.stdout.strip())
                except Exception:
                    win_paths.append(f)
            subprocess.Popen([editor] + win_paths)
        elif platform.system() == "Windows":
            # subl.exe opens all files as tabs in one window.
            # Exclude directories — passing a folder creates a separate project window.
            subl = str(Path(editor).parent / "subl.exe")
            if not Path(subl).exists():
                subl = editor
            files_only = [f for f in existing if not Path(f).is_dir()]
            subprocess.Popen([subl] + files_only)
        elif editor.startswith("flatpak:"):
            app_id = editor.split(":", 1)[1]
            subprocess.Popen(["flatpak", "run", "--filesystem=host", app_id] + existing)
        else:
            subprocess.Popen([editor] + existing)
    except Exception as e:
        print(f"Editor launch failed: {e}")
        print("Result files:")
        for f in existing:
            print(f"  {f}")


# ---------------------------------------------------------------------------
# Sublime Text: Package Control + Log Highlight
# ---------------------------------------------------------------------------

def install_sublime_packages():
    """Install Package Control and queue Log Highlight for Sublime Text."""
    import urllib.request, json as _json

    system = platform.system()
    if system == "Windows":
        return  # Skip on Windows/WSL

    try:
        with open("/proc/version") as _f:
            if re.search(r"Microsoft|WSL", _f.read()):
                return
    except Exception:
        pass

    flatpak = shutil.which("flatpak")
    is_flatpak = False
    if flatpak:
        try:
            r = subprocess.run([flatpak, "info", "com.sublimehq.SublimeText"],
                               capture_output=True, timeout=5)
            is_flatpak = r.returncode == 0
        except Exception:
            pass

    if is_flatpak:
        base = Path.home() / ".var/app/com.sublimehq.SublimeText/config/sublime-text"
    elif shutil.which("subl") or shutil.which("sublime_text"):
        base = Path.home() / ".config/sublime-text"
    else:
        return  # Sublime Text not installed

    pkg_ctrl_dir = base / "Installed Packages"
    pkg_ctrl_file = pkg_ctrl_dir / "Package Control.sublime-package"
    settings_dir = base / "Packages/User"
    settings_file = settings_dir / "Package Control.sublime-settings"

    pkg_ctrl_dir.mkdir(parents=True, exist_ok=True)
    settings_dir.mkdir(parents=True, exist_ok=True)

    if not pkg_ctrl_file.exists():
        url = "https://packagecontrol.io/Package%20Control.sublime-package"
        try:
            print("Installing Sublime Package Control...")
            urllib.request.urlretrieve(url, str(pkg_ctrl_file))
        except Exception as e:
            print(f"Package Control download failed: {e}")

    # Merge Log Highlight into existing settings
    try:
        existing = _json.loads(settings_file.read_text()) if settings_file.exists() else {}
    except Exception:
        existing = {}
    pkgs = existing.get("installed_packages", [])
    if "Log Highlight" not in pkgs:
        pkgs.append("Log Highlight")
        existing["installed_packages"] = pkgs
        settings_file.write_text(_json.dumps(existing, indent=4) + "\n")
        print("Sublime: Log Highlight added to Package Control queue.")


# ---------------------------------------------------------------------------
# Process one .dat file
# ---------------------------------------------------------------------------

def process_file(filepath: Path, download_dir: Path):
    while filepath.with_suffix(filepath.suffix + ".part").exists():
        time.sleep(SLEEP_EXTRACT_ZIP)

    # On Windows, the file may still be locked briefly after the .part check
    for _ in range(10):
        try:
            filepath.open("rb").close()
            break
        except PermissionError:
            time.sleep(SLEEP_EXTRACT_ZIP)
    else:
        return  # still locked after retries — skip this scan cycle

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

    try:
        shutil.move(str(filepath), str(debug_dir / filepath.name))
    except (PermissionError, shutil.Error):
        pass  # Windows may still hold a lock; file stays in place, no retry needed
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

    editor = find_editor()
    is_sublime = editor and ("subl" in editor or "sublime" in editor.lower() or editor.startswith("flatpak:") or editor == "code")

    def ep_sublime(relpath):
        p = dsm_dir / relpath
        return f"{p}:100000" if p.exists() else None

    if _is_wsl():
        file_list = [str(debug_dir)]
    else:
        file_list = []

    if is_sublime:
        file_list += [
            str(sg),
            ep("packages_onoff.list"),
            ep("var/log/bash_history.log"),
            str(hb),
            ep("var/log/hibernation.log"),
            ep("result/df.result"),
            ep_sublime("space.xml"),
            disk_log,
            ep_sublime("var/log/kern.log"),
            ep_sublime("var/log/synolog/synosystac.log"),
            ep_sublime("var/log/messages.log"),
            str(sm),
        ]
    else:
        file_list += [
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
        ]

    open_in_editor(file_list + [str(p) for p in pics])

    print(f"Total time: {time.time() - t0:.2f}s")


# ---------------------------------------------------------------------------
# Watch loop + main
# ---------------------------------------------------------------------------

def watch(download_dir: Path):
    print("Waiting for debug-files...")
    while True:
        for dat in sorted(download_dir.glob("*.dat")):
            if dat.is_file():
                try:
                    process_file(dat, download_dir)
                except Exception as e:
                    print(f"Error processing {dat.name}: {e}")
                    traceback.print_exc()
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
        print("\t-u : Update DSM-Updates, HDD-(in-)compatibility-lists, package updates")
        print("\t-v : Be Verbose")
        print("\t-d : Set Download directory to scan (use absolute path) [required]")
        print('\t     example: synology_debug_unzip.py -d "/home/thomas/Downloads/neu"')
        print()
        sys.exit(0)

    if args.v:
        verbose = True

    if args.u:
        print("updating files:")
        update_cpu_list()
        update_dsm_updates_list()
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

    install_sublime_packages()
    check_and_update()
    watch(download_dir)


if __name__ == "__main__":
    main()
