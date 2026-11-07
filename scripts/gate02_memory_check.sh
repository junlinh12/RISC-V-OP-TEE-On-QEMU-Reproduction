#!/usr/bin/env bash
# =============================================================================
#  Gate 02 (pre-build) : memory usage diagnosis
#  Project : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  READ-ONLY. Kills nothing, needs no sudo, changes no setting, drops no cache.
#  Shows where host memory goes before the Buildroot build:
#    - breakdown of /proc/meminfo (applications / shared memory / kernel / cache)
#    - top processes by resident memory and by swap, grouped by program name
#    - memory charged to cgroups (your session, other users, system services)
#    - tmpfs usage (shared memory that page reclaim cannot simply drop)
#  Process owners are shown only as me / root / system / other-user, so no
#  other user's name is written to the log. Command lines are never printed
#  (only program names), because they may contain paths or tokens.
#  Logging: [rc=N] per command, pipefail, sanitized log in logs/gate02/,
#  raw log + sha256 manifest in logs/gate02/raw/ (local only).
#
#  Usage : bash scripts/gate02_memory_check.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "${SCRIPT_DIR}")" != "scripts" ]; then
  echo "ERROR: place this script in <project-root>/scripts/ and run it from there." >&2
  exit 1
fi
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
LOG_DIR="${PROJECT_ROOT}/logs/gate02"
RAW_DIR="${LOG_DIR}/raw"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/gate02_memory_check_${TS}.log"
RAW_FILE="${RAW_DIR}/gate02_memory_check_${TS}.raw.log"
MANIFEST="${RAW_DIR}/gate02_memory_check_${TS}.sha256"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
mkdir -p "${LOG_DIR}" "${RAW_DIR}"

MY_UID="$(id -u)"

# ---- sanitizer (same rules as the other gate scripts) ------------------------
U_NAME="$(id -un)"
H_SHORT="$(hostname -s 2>/dev/null || true)"
H_FQDN="$(hostname -f 2>/dev/null || true)"
esc() { printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|#]/\\&/g'; }
SED_ARGS=(-E -e "s#$(esc "${HOME}")#<HOME>#g")
[ -n "${H_FQDN}" ]  && SED_ARGS+=(-e "s#\\b$(esc "${H_FQDN}")\\b#<HOST>#g")
[ -n "${H_SHORT}" ] && SED_ARGS+=(-e "s#\\b$(esc "${H_SHORT}")\\b#<HOST>#g")
[ -n "${U_NAME}" ]  && SED_ARGS+=(-e "s#\\b$(esc "${U_NAME}")\\b#<USER>#g")
SED_ARGS+=(
  -e 's#127\.0\.0\.1#__LOOPBACK__#g'
  -e 's#([0-9]{1,3}\.){3}[0-9]{1,3}#<IPv4>#g'
  -e 's#__LOOPBACK__#127.0.0.1#g'
  -e 's#([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}#<MAC>#g'
  -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}#<EMAIL>#g'
)
sanitize() { sed "${SED_ARGS[@]}"; }

# ---- helpers ----------------------------------------------------------------
section() { printf '\n===== %s =====\n' "$1"; }
FAILS=0
fail() { FAILS=$((FAILS + 1)); }
run() {
  local rc
  printf '$ %s\n' "$1"
  bash -c "$1" 2>&1; rc=$?
  printf '[rc=%d]\n' "${rc}"
  [ "${rc}" -ne 0 ] && fail
  return "${rc}"
}
# owner class from a numeric uid (no names are printed)
OWNER_AWK='function owner(u) { if (u == myuid) return "me"; if (u == 0) return "root"; if (u < 1000) return "system"; return "other-user" }'
gib() { awk -v b="$1" 'BEGIN { printf "%6.2f GiB", b / 1073741824 }'; }

{
  section "0. Meta"
  echo "Gate      : 02 pre-build memory diagnosis (read-only)"
  echo "Timestamp : ${TS}"
  echo "Script    : scripts/$(basename "${SCRIPT_PATH}")  sha256=$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"
  run "uptime -p"
  run "free -h"
  echo "Note: in recent procps versions 'used' = total - available."

  section "1. Breakdown of /proc/meminfo"
  awk '
    { v[$1] = $2 }
    END {
      g = 1048576
      printf "MemTotal                      : %6.2f GiB\n", v["MemTotal:"]/g
      printf "MemAvailable                  : %6.2f GiB\n", v["MemAvailable:"]/g
      printf "MemFree                       : %6.2f GiB\n", v["MemFree:"]/g
      print  "-- what occupies memory --"
      printf "Applications (AnonPages)      : %6.2f GiB\n", v["AnonPages:"]/g
      printf "Shared memory / tmpfs (Shmem) : %6.2f GiB\n", v["Shmem:"]/g
      printf "Page cache (Cached-Shmem)     : %6.2f GiB  (mostly reclaimable)\n", (v["Cached:"]-v["Shmem:"])/g
      printf "Buffers                       : %6.2f GiB\n", v["Buffers:"]/g
      printf "Kernel slab, reclaimable      : %6.2f GiB\n", v["SReclaimable:"]/g
      printf "Kernel slab, unreclaimable    : %6.2f GiB\n", v["SUnreclaim:"]/g
      printf "Page tables + kernel stacks   : %6.2f GiB\n", (v["PageTables:"]+v["KernelStack:"])/g
      printf "Huge pages reserved (Hugetlb) : %6.2f GiB\n", v["Hugetlb:"]/g
      print  "-- swap --"
      printf "SwapTotal                     : %6.2f GiB\n", v["SwapTotal:"]/g
      printf "Swap used                     : %6.2f GiB\n", (v["SwapTotal:"]-v["SwapFree:"])/g
      printf "SwapCached                    : %6.2f GiB\n", v["SwapCached:"]/g
      printf "Committed_AS                  : %6.2f GiB\n", v["Committed_AS:"]/g
    }' /proc/meminfo
  run "swapon --show"

  section "2. Top 15 processes by resident memory (RSS)"
  echo "owner        pid      RSS        running   program"
  ps -eo uid=,pid=,rss=,etimes=,comm= --sort=-rss | head -n 15 | awk -v myuid="${MY_UID}" "${OWNER_AWK}"'
    { uid=$1; pid=$2; rss=$3; et=$4; line=$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", line)
      printf "%-11s %7s %7.2f GiB %6.1f h   %s\n", owner(uid), pid, rss/1048576, et/3600, line }'

  section "3. RSS grouped by program and owner (top 15; shared pages are counted per process)"
  echo "owner        procs   RSS sum     program"
  ps -eo uid=,rss=,comm= | awk -v myuid="${MY_UID}" "${OWNER_AWK}"'
    { uid=$1; rss=$2; line=$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", line)
      k = owner(uid) "\t" line; s[k] += rss; n[k]++ }
    END { for (k in s) { split(k, a, "\t"); printf "%-11s %5d %8.2f GiB   %s\n", a[1], n[k], s[k]/1048576, a[2] } }' \
    | sort -k3,3 -rn | head -n 15

  section "4. RSS total per owner class"
  ps -eo uid=,rss= | awk -v myuid="${MY_UID}" "${OWNER_AWK}"'
    { s[owner($1)] += $2; n[owner($1)]++ }
    END { for (o in s) printf "%-11s %5d procs %8.2f GiB\n", o, n[o], s[o]/1048576 }' | sort -k4,4 -rn
  echo "logged-in users (distinct): $(who | awk '{print $1}' | sort -u | wc -l)   your sessions: $(who | awk -v me="${U_NAME}" '$1 == me' | wc -l)"

  section "5. Swap used per program (top 10)"
  awk -F'\t' -v myuid="${MY_UID}" "${OWNER_AWK}"'
    FNR == 1 { name = ""; uid = "" }
    /^Name:/ { name = $2 }
    /^Uid:/  { uid = $2 }
    /^VmSwap:/ { kb = $2; gsub(/[^0-9]/, "", kb); if (kb > 0) { k = owner(uid) "\t" name; s[k] += kb } }
    END { for (k in s) { split(k, a, "\t"); printf "%-11s %8.2f GiB   %s\n", a[1], s[k]/1048576, a[2] } }' \
    /proc/[0-9]*/status 2>/dev/null | sort -k2,2 -rn | head -n 10

  section "6. Memory charged to cgroups (includes page cache)"
  if [ -r /sys/fs/cgroup/user.slice/memory.current ]; then
    echo "-- user sessions --"
    for f in /sys/fs/cgroup/user.slice/user-*.slice/memory.current; do
      [ -r "${f}" ] || continue
      uid="${f#*/user-}"; uid="${uid%%.slice*}"
      cls="$(awk -v u="${uid}" -v myuid="${MY_UID}" "${OWNER_AWK}"' BEGIN { print owner(u) }')"
      printf '%-11s %s\n' "${cls}" "$(gib "$(cat "${f}")")"
    done
    echo "-- system services (top 10) --"
    for f in /sys/fs/cgroup/system.slice/*/memory.current; do
      [ -r "${f}" ] && printf '%s %s\n' "$(cat "${f}")" "$(basename "$(dirname "${f}")")"
    done | sort -rn | head -n 10 | while read -r b n; do printf '%s  %s\n' "$(gib "${b}")" "${n}"; done
    MYSLICE="/sys/fs/cgroup/user.slice/user-${MY_UID}.slice"
    if [ -d "${MYSLICE}" ]; then
      echo "-- inside your session (top 10 apps / scopes) --"
      find "${MYSLICE}" -mindepth 2 -maxdepth 4 -name memory.current 2>/dev/null | while read -r f; do
        printf '%s %s\n' "$(cat "${f}" 2>/dev/null || echo 0)" "$(basename "$(dirname "${f}")")"
      done | sort -rn | head -n 10 | while read -r b n; do printf '%s  %s\n' "$(gib "${b}")" "${n}"; done
    fi
  else
    echo "(cgroup v2 memory files not readable)"
  fi

  section "7. tmpfs usage (counted as Shmem)"
  run "df -h -t tmpfs"

  section "9. Summary"
  echo "Failed commands : ${FAILS}"
  echo "This script changed nothing. Decide on any action after reviewing the log."
  echo "Next            : upload logs/gate02/$(basename "${LOG_FILE}") (the sanitized log) to the chat"
  [ "${FAILS}" -eq 0 ]
} 2>&1 | tee "${RAW_FILE}" | sanitize | tee "${LOG_FILE}"
STATUS=$?

( cd "${PROJECT_ROOT}" && sha256sum "${RAW_FILE#"${PROJECT_ROOT}"/}" "${LOG_FILE#"${PROJECT_ROOT}"/}" \
    "${SCRIPT_PATH#"${PROJECT_ROOT}"/}" > "${MANIFEST}" )

echo
echo "Sanitized log   : ${LOG_FILE#"${PROJECT_ROOT}"/}"
echo "sha256 manifest : ${MANIFEST#"${PROJECT_ROOT}"/}"
echo "Exit status     : ${STATUS}"
exit "${STATUS}"
