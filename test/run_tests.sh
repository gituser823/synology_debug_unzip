#!/bin/bash
# Automated test runner for synology_debug_unzip.sh and synology_debug_unzip.py
# Creates a synthetic Synology debug archive and validates the sm.log output.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

ok() {
    echo "  [PASS] $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  [FAIL] $1"
    FAIL=$((FAIL + 1))
    if [[ -n "${2:-}" ]]; then
        echo "         --- sm.log head ---"
        head -60 "$2" 2>/dev/null | sed 's/^/         /'
        echo "         -------------------"
    fi
}

check() {
    local label="$1" file="$2" pattern="$3"
    if grep -qi "$pattern" "$file" 2>/dev/null; then
        ok "$label"
    else
        fail "$label (pattern '${pattern}' not in $(basename "$file"))" "$file"
    fi
}

# ---------------------------------------------------------------------------
# Build test archive
# ---------------------------------------------------------------------------
DAT="$WORK_DIR/debug_test.dat"
python3 "$TEST_DIR/make_test_dat.py" "$DAT"

# ---------------------------------------------------------------------------
# Fake editor: sits first in PATH so both scripts find it instead of flatpak
# ---------------------------------------------------------------------------
FAKE_BIN="$WORK_DIR/bin"
mkdir -p "$FAKE_BIN"
for name in subl sublime_text gedit; do
    cat > "$FAKE_BIN/$name" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$FAKE_BIN/$name"
done
# Mask flatpak so editor detection falls through to our fake subl
cat > "$FAKE_BIN/flatpak" <<'EOF'
#!/bin/bash
# Return non-zero for "info" so Sublime Text Flatpak is not detected
[[ "$1" == "info" ]] && exit 1
exec /usr/bin/flatpak "$@"
EOF
chmod +x "$FAKE_BIN/flatpak"
export PATH="$FAKE_BIN:$PATH"

# ---------------------------------------------------------------------------
# Helper: run a script in background, drop the .dat, wait for sm.log
# ---------------------------------------------------------------------------
run_and_wait() {
    local label="$1"
    shift
    local watch_dir="$WORK_DIR/${label}_watch"
    mkdir -p "$watch_dir"

    "$@" -d "$watch_dir" >"$WORK_DIR/${label}.stdout" 2>&1 &
    local pid=$!

    # Give the watch loop a moment to start
    sleep 2

    cp "$DAT" "$watch_dir/debug_test.dat"

    # Wait up to 60s for sm.log
    local sm_log="" deadline
    deadline=$(( $(date +%s) + 60 ))
    while [[ $(date +%s) -lt $deadline ]]; do
        sm_log=$(find "$watch_dir" -name "sm.log" 2>/dev/null | head -1)
        if [[ -n "$sm_log" ]]; then
            break
        fi
        sleep 1
    done

    # Let it finish writing
    sleep 2
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true

    echo "$sm_log"
}

# ---------------------------------------------------------------------------
# Test synology_debug_unzip.sh
# ---------------------------------------------------------------------------
echo ""
echo "=== Testing synology_debug_unzip.sh ==="
SM_SH=$(run_and_wait "bash" bash "$SCRIPT_DIR/synology_debug_unzip.sh")

if [[ -z "$SM_SH" ]]; then
    fail "sm.log was not created by synology_debug_unzip.sh"
    echo "  --- synology_debug_unzip.sh stdout ---"
    head -40 "$WORK_DIR/bash.stdout" | sed 's/^/  /'
else
    ok "sm.log created"
    check "model DS920+"            "$SM_SH" "DS920\+"
    check "serial number"           "$SM_SH" "2330ABC123"
    check "DSM version"             "$SM_SH" "7\.2\.2"
    check "SMART Reallocated=0"     "$SM_SH" "Reallocated_Sector_Ct.*0"
    check "SMART Pending=0"         "$SM_SH" "Current_Pending_Sector.*0"
    check "SMART Uncorrectable=0"   "$SM_SH" "Offline_Uncorrectable.*0"
    check "RAID (volume array)"      "$SM_SH" "md2"
    check "volumes mounted"         "$SM_SH" "volume"
    check "ExtensionUnits"          "$SM_SH" "ExtensionUnits"
    check "packages present"        "$SM_SH" "packages\|Docker\|HyperBackup"
    echo "  sm.log: $SM_SH ($(wc -l < "$SM_SH") lines)"
fi

# ---------------------------------------------------------------------------
# Test synology_debug_unzip.py
# ---------------------------------------------------------------------------
echo ""
echo "=== Testing synology_debug_unzip.py ==="
SM_PY=$(run_and_wait "py" python3 "$SCRIPT_DIR/synology_debug_unzip.py")

if [[ -z "$SM_PY" ]]; then
    fail "sm.log was not created by synology_debug_unzip.py"
    echo "  --- synology_debug_unzip.py stdout ---"
    head -40 "$WORK_DIR/py.stdout" | sed 's/^/  /'
else
    ok "sm.log created"
    check "model DS920+"            "$SM_PY" "DS920\+"
    check "serial number"           "$SM_PY" "2330ABC123"
    check "DSM version"             "$SM_PY" "7\.2\.2"
    check "SMART Reallocated=0"     "$SM_PY" "Reallocated_Sector_Ct.*0"
    check "SMART Pending=0"         "$SM_PY" "Current_Pending_Sector.*0"
    check "SMART Uncorrectable=0"   "$SM_PY" "Offline_Uncorrectable.*0"
    check "RAID (volume array)"      "$SM_PY" "md2"
    check "volumes mounted"         "$SM_PY" "volume"
    check "packages present"        "$SM_PY" "packages\|Docker\|HyperBackup"
    echo "  sm.log: $SM_PY ($(wc -l < "$SM_PY") lines)"
fi

# ---------------------------------------------------------------------------
# Cross-check: key fields present in both
# ---------------------------------------------------------------------------
if [[ -f "$SM_SH" && -f "$SM_PY" ]]; then
    echo ""
    echo "=== Cross-check (sh vs py) ==="
    for pattern in "DS920" "2330ABC123" "Reallocated_Sector_Ct" "volume"; do
        sh_hit=$(grep -qi "$pattern" "$SM_SH" && echo yes || echo no)
        py_hit=$(grep -qi "$pattern" "$SM_PY" && echo yes || echo no)
        if [[ "$sh_hit" == "$py_hit" ]]; then
            ok "  $pattern: both=$sh_hit"
        else
            fail "  $pattern: sh=$sh_hit py=$py_hit"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================="
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "=============================="
[[ $FAIL -eq 0 ]]
