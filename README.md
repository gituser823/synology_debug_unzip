# synology_debug_unzip

Bash script and Python port that watch a directory for Synology debug `.dat` files, extract and analyze them automatically, and open the results in a text editor.

## What it does

When a Synology debug file (`debug_*.dat`) is downloaded into the watched directory, the script:

1. Detects and extracts the archive (gzip, zip, or raw tar) via `bsdtar` / Python's `tarfile`/`zipfile`
2. Handles all known debug archive layouts (standard DSM, HighAvailability active/passive, UC3200, router USB share, old DSM versions)
3. Analyzes the extracted data and writes a summary to `sm.log`:
   - DSM version, hardware model, serial number, kernel
   - Mounted volumes and disk usage (warns at >90% full)
   - RAID status (mdstat), degraded arrays, active rebuilds
   - SMART data per disk — health, temperature, reallocated/pending/uncorrectable sectors, power-on hours
   - HDD compatibility against Synology's HCL
   - Installed packages vs. latest available versions
   - Improper shutdowns, volume crashes, kernel call traces
   - Network config (dropped packets, errors, IPv6, bonding, ethtool speeds)
   - NTP, DDNS, QuickConnect configuration
   - Btrfs/ext4 filesystem errors, Btrfs scrub history
   - Hibernation and power schedule debug log
   - Extended diagnostics: UPS events, auth failures, HyperBackup tasks, disk health prediction, volume layout
4. Opens the result files in a text editor

Compatibility and package version data is downloaded from Synology's servers and cached locally (refreshed every 24 hours).

## Versions

| File | Language | Requires |
|------|----------|----------|
| `synology_debug_unzip.sh` | Bash | `bsdtar`, `lftp`, `jq`, `sqlite3`, `unzip` |
| `synology_debug_unzip.py` | Python 3 | `pip install requests` |

Both versions are feature-equivalent. The Python version runs on Windows natively in addition to Linux and WSL.

## Requirements

### Bash version

```bash
sudo apt install libarchive-tools lftp jq sqlite3 unzip
```

`libarchive-tools` provides `bsdtar`.

### Python version

```bash
pip install requests
```

## Editor support

The script auto-detects an available editor in this priority order:

| Platform | Detection order |
|----------|----------------|
| **Linux** | Flatpak Sublime Text → `subl` → `sublime_text` → `gedit` → `kate` → `mousepad` → `xed` → `pluma` → `xdg-open` |
| **Windows** | `C:\Program Files\Sublime Text\` → `Sublime Text 4\` → `Sublime Text 3\` → `notepad.exe` |
| **WSL** | Auto-searches Windows-side Sublime Text across common install paths and Windows PATH interop → `explorer.exe` fallback |

On WSL, file paths are automatically converted to Windows format (`wslpath -w`) and all result files are opened in a single editor call.

## Usage

### Bash

```bash
bash synology_debug_unzip.sh -d "/path/to/download/directory"
```

### Python

```bash
python3 synology_debug_unzip.py -d "/path/to/download/directory"
```

The script waits for `*.dat` files to appear in that directory. Download a debug file from your NAS via **DSM → Support Center → Debug** and save it to the watched folder.

### Options

| Flag | Description |
|------|-------------|
| `-d "/path"` | Set download directory to watch (required) |
| `-u` | Update HDD compatibility lists, package versions and DSM update list, then exit |
| `-v` | Verbose output |
| `-h` | Show help |

### Example

```bash
# Start watching
bash synology_debug_unzip.sh -d "$HOME/Downloads/synology"

# Force-update all cached data from Synology's servers
bash synology_debug_unzip.sh -d "$HOME/Downloads/synology" -u
```

## Cached data (downloaded automatically)

| File | Source | Refresh interval |
|------|--------|-----------------|
| `tmp/genRSS.php` | DSM update feed | 10 hours |
| `comp/<Model>_hdds_compatible.json` | Synology HCL API | 24 hours |
| `comp/<Model>_hdds_incompatible.json` | Synology HCL API | 24 hours |
| `tmp/package_versions.txt` | archive.synology.com | 24 hours |

Run with `-u` to force an immediate refresh.

## Supported debug archive formats

- Standard DSM debug (current format)
- HighAvailability clusters (active + passive node)
- UC3200 unified controller
- Router debug via USB share
- Old DSM format (`volume1/@tmp/`)

## Notes

- An absolute path is required for `-d`. Relative paths are rejected.
- Firefox `.part` files are detected; the script waits for the download to complete before extracting.
- Multiple HCL download jobs run in parallel to speed up the initial data fetch.
- SRS (Synology Replacement Service) has been discontinued by Synology and is not checked.
