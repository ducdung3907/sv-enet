#!/usr/bin/env bash
# Run every testbench in tb/ and exit with an error if any of them fails.
# Used locally and by GitHub Actions. Same structure as ai-rtl's run_all.sh.
#
# Runs in parallel (JOBS=n to change, default = CPU cores).
# Usage (from the repository root):
#   ./sim/run_all.sh            # everything
#   ./sim/run_all.sh crc mac    # only runs whose name contains one of these words
#
# A run passes only if its log contains a line starting with "PASS" and no line
# starting with "FAIL". Logs go to sim/logs/ (ignored by git).
#
# A run is SKIPPED (not failed) when its testbench or any design file it needs
# does not exist yet, so CI stays green while modules are written one by one.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOGS="sim/logs"
mkdir -p "$LOGS"

# Every design file is compiled into every run; -s picks the testbench as the
# top, so unused modules are simply ignored.
DESIGN=$(ls rtl/*.sv board/*.sv 2>/dev/null)

# name | testbench file | top module | needs (design files, space separated) | -P overrides
RUNS=(
  "crc32            | tb/tb_enet_crc32.sv | tb_enet_crc32 | rtl/enet_crc32.sv | "
)

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

# Compile and run one entry. Writes its one-line verdict to $LOGS/<name>.result
run_one() {
    local entry="$1" name file top needs params
    IFS='|' read -r name file top needs params <<< "$entry"
    name=$(trim "$name"); file=$(trim "$file"); top=$(trim "$top")
    needs=$(trim "$needs"); params=$(trim "$params")
    local res="$LOGS/$name.result"

    if [ ! -f "$file" ]; then
        echo "SKIP skip (no $file)" > "$res"; return
    fi
    local n
    for n in $needs; do
        if [ ! -f "$n" ]; then
            echo "SKIP skip (no $n yet)" > "$res"; return
        fi
    done

    local pflags="" missing="" p pname
    for p in $params; do
        pname="${p%%=*}"
        if grep -qE "parameter[^;]*\b${pname}\b" "$file"; then pflags="$pflags -P${top}.${p}"
        else missing="$pname"; fi
    done
    if [ -n "$missing" ]; then
        echo "SKIP skip ($file has no $missing)" > "$res"; return
    fi

    local log="$LOGS/$name.log" vvp_file="$LOGS/$name.vvp"
    if ! iverilog -g2012 -s "$top" $pflags -o "$vvp_file" $DESIGN "$file" > "$log" 2>&1; then
        echo "FAIL FAIL (compile, see $log)" > "$res"; return
    fi
    timeout 900 vvp -n "$vvp_file" >> "$log" 2>&1
    if grep -q "^PASS" "$log" && ! grep -q "^FAIL" "$log"; then
        echo "PASS PASS  $(grep -m1 '^PASS' "$log" | cut -c1-60)" > "$res"
    else
        echo "FAIL FAIL (see $log)" > "$res"
    fi
}

selected=()
for entry in "${RUNS[@]}"; do
    IFS='|' read -r name _ <<< "$entry"; name=$(trim "$name")
    if [ $# -gt 0 ]; then
        keep=0; for w in "$@"; do [[ "$name" == *"$w"* ]] && keep=1; done
        [ $keep -eq 0 ] && continue
    fi
    rm -f "$LOGS/$name.result"
    selected+=("$name|$entry")
    run_one "$entry" &
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
done
wait

pass=0; fail=0; skip=0; failed=()
printf "%-18s %s\n" "run" "result"
printf "%-18s %s\n" "---" "------"
for item in "${selected[@]}"; do
    name="${item%%|*}"
    read -r kind text < "$LOGS/$name.result"
    printf "%-18s %s\n" "$name" "$text"
    case "$kind" in
        PASS) pass=$((pass+1)) ;;
        SKIP) skip=$((skip+1)) ;;
        *)    fail=$((fail+1)); failed+=("$name") ;;
    esac
done

echo
echo "passed: $pass   failed: $fail   skipped: $skip"
if [ $fail -gt 0 ]; then
    echo "failed runs: ${failed[*]}"
    exit 1
fi