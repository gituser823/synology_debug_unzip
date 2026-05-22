# entpacker

Bash script that watches a directory for Synology debug `.dat` files, extracts and analyzes them automatically, and opens the results in a text editor.

## What it does

When a Synology debug file (`debug_*.dat`) is downloaded into the watched directory, the script:

1. Detects and extracts the gzip archive via `bsdtar`
2. Handles all known debug archive layouts (standard DSM, HighAvailability active/passive, UC3200, router USB share, old DSM versions)
3. Analyzes the extracted data and writes a summary to `sm.log`:
   - DSM version, hardware model, kernel
   - Mounted volumes and disk usage (warns at >90% full)
   - RAID status (mdstat), degraded arrays
   - SMART data per disk — health, temperature, reallocated/pending sectors
   - HDD compatibility against Synology's HCL
   - Installed packages vs. latest available versions
   - Improper shutdowns, volume crashes, kernel call traces
   - Network config (dropped packets, errors, IPv6)
   - NTP configuration
   - Btrfs/ext4 filesystem errors
   - Hibernation debug log
4. Opens the result files in a text editor

Compatibility and package version data is downloaded from Synology's servers and cached locally (refreshed every ~11 days).

## Requirements

```bash
sudo apt install libarchive-tools lftp jq sqlite3
```

`libarchive-tools` provides `bsdtar`. A text editor reachable via `xdg-open` or `subl` is used to display results.

## Usage

```bash
bash entpacker.sh -d "/path/to/download/directory"
```

The script then waits for `*.dat` files to appear in that directory. Download a debug file from your NAS via **DSM → Support Center → Debug** and save it to the watched folder.

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
bash entpacker.sh -d "$HOME/Downloads/synology"

# Force-update all cached data from Synology's servers
bash entpacker.sh -d "$HOME/Downloads/synology" -u
```

## Cached data (downloaded automatically)

| File | Source | Refresh interval |
|------|--------|-----------------|
| `tmp/genRSS.php` | DSM update feed | 10 hours |
| `comp/<Model>_hdds_compatible.json` | Synology HCL API | ~11 days |
| `comp/<Model>_hdds_incompatible.json` | Synology HCL API | ~11 days |
| `tmp/package_versions.txt` | archive.synology.com | ~11 days |

Run with `-u` to force an immediate refresh.

## Supported debug archive formats

- Standard DSM debug (current format)
- HighAvailability clusters (active + passive node)
- UC3200 unified controller
- Router debug via USB share
- Old DSM format (`volume1/@tmp/`)

## Notes

- The script requires an absolute path for `-d`. Relative paths are rejected.
- Firefox `.part` files are detected; the script waits for the download to complete before extracting.
- Multiple HCL download jobs run in parallel via `lftp` to speed up the initial data fetch.
- SRS (Synology Replacement Service) has been discontinued by Synology and is no longer checked.
