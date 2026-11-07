#!/usr/bin/env bash
# =============================================================================
#  Gate 05b-1 : build a later RP016 milestone in its own Buildroot tree
#  Project    : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  Usage
#    bash scripts/gate05b_build.sh <m2|m3|m8|v9> --prepare-only   clone, pin, configure
#    bash scripts/gate05b_build.sh <m2|m3|m8|v9>                  ... + build + verify
#
#  Targets (Buildroot branch from the official milestone page, commit recorded
#  in the G01 branch survey on 2026-11-05)
#    m2  rp016_m2_aplic_up_v2  8fba3ebe3c5b15b9fff51c310da1ee4195d2af4d
#    m3  rp016_m3_virq_up_v1   f2e760efebf60feb95b39a780506d5b1b12e308a
#    m8  rp022-m8-pmp-data-perms  6d7db0ab2bf7b8bf7e134948822aa6f0b7b43808  (G05c, RP022 M8)
#    v9  dev-optee-mpxy-v9        b5e20ca925d0784473c854fae92c3fc5931802ee  (G05c, Andes v9)
#
#  Rules
#    - The M1 reference tree (work/buildroot) is never modified.
#    - Each target has its own tree: work/buildroot-<target>.
#    - Downloads go to work/dl-g05 (BR2_DL_DIR). It is seeded once with HARD
#      LINKS to the tarballs of the M1 download directory (git caches
#      excluded), so nothing in work/buildroot/dl is changed.
#    - Components are NOT hard-coded: the script reads local.mk
#      (CUSTOM_<X>_GITURL / CUSTOM_<X>_BRANCH) and the defconfig
#      (BR2_*_CUSTOM_REPO_URL / _VERSION), resolves every branch to a commit
#      SHA at prepare time, records the pins, and stops on anything unknown.
#    - Pinning as in G02: custom/<dir> gets a local branch at the pinned SHA;
#      defconfig custom git repos that are not overridden by local.mk get the
#      SHA in .config. The upstream local.mk and defconfig are not modified.
#    - Parallelism is limited to 2 jobs by default (top-level -j AND BR2_JLEVEL
#      in .config) to avoid running out of memory; G05B_JOBS overrides it.
#    - After the build the generated start scripts are printed, so that the
#      G05b-2 tests can be designed from the real scripts.
#  Logging: umask 077, [rc=N], pipefail, line-buffered Ctrl-C-safe log
#  pipeline, sanitized logs in logs/gate05/, raw logs + sha256 manifest in
#  logs/gate05/raw/.
# =============================================================================
set -uo pipefail
umask 077

TARGET="${1:-}"
MODE="full"
case "${2:-}" in
  "")             ;;
  --prepare-only) MODE="prepare-only" ;;
  *) TARGET="" ;;
esac
case "${TARGET}" in
  m2) BRANCH="rp016_m2_aplic_up_v2";    PIN_BR="8fba3ebe3c5b15b9fff51c310da1ee4195d2af4d"; GATE="05b" ;;
  m3) BRANCH="rp016_m3_virq_up_v1";     PIN_BR="f2e760efebf60feb95b39a780506d5b1b12e308a"; GATE="05b" ;;
  m8) BRANCH="rp022-m8-pmp-data-perms"; PIN_BR="6d7db0ab2bf7b8bf7e134948822aa6f0b7b43808"; GATE="05c" ;;
  v9) BRANCH="dev-optee-mpxy-v9";       PIN_BR="b5e20ca925d0784473c854fae92c3fc5931802ee"; GATE="05c" ;;
  *)  echo "usage: bash scripts/gate05b_build.sh <m2|m3|m8|v9> [--prepare-only]" >&2; exit 2 ;;
esac
PIN_BR="${G05B_PIN_BR:-${PIN_BR}}"   # override only for offline tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "${SCRIPT_DIR}")" != "scripts" ]; then
  echo "ERROR: place this script in <project-root>/scripts/ and run it from there." >&2
  exit 1
fi
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
M1_TREE="${PROJECT_ROOT}/work/buildroot"
TREE="${PROJECT_ROOT}/work/buildroot-${TARGET}"
export BR2_DL_DIR="${PROJECT_ROOT}/work/dl-g05"
BR_URL="${G05B_BR_URL:-https://gitlab.com/riseproject/riscv-optee/buildroot.git}"   # override only for offline tests
DEFCONFIG_NAME="qemu_riscv64_virt_optee_defconfig"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

LOG_DIR="${PROJECT_ROOT}/logs/gate05"
RAW_DIR="${LOG_DIR}/raw"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/gate${GATE}_${TARGET}_build_${TS}.log"
RAW_FILE="${RAW_DIR}/gate${GATE}_${TARGET}_build_${TS}.raw.log"
MAKE_RAW="${RAW_DIR}/gate${GATE}_${TARGET}_make_${TS}.raw.log"
MAKE_LOG="${LOG_DIR}/gate${GATE}_${TARGET}_make_${TS}.log"
PINS_FILE="${LOG_DIR}/gate${GATE}_${TARGET}_pins_${TS}.txt"
MANIFEST="${RAW_DIR}/gate${GATE}_${TARGET}_build_${TS}.sha256"
MEM_OK=8;   MEM_ABORT=4
# Parallelism: BOTH the top-level make (-j) and the per-package jobs (BR2_JLEVEL,
# default 0 = CPUs+1) are limited; -j alone does not bound package compiles (OOM).
JOBS="${G05B_JOBS:-2}"
DISK_OK=60; DISK_ABORT=40

mkdir -p "${LOG_DIR}" "${RAW_DIR}" && chmod 755 "${LOG_DIR}" && chmod 700 "${RAW_DIR}"
TMPD="$(mktemp -d)"; trap 'rm -rf "${TMPD}"' EXIT
export GIT_TERMINAL_PROMPT=0

# local.mk variable prefix -> custom/ directory (as used by the RISE local.mk)
declare -A CUSTOM_DIR=( [QEMU]=qemu [OPENSBI]=opensbi [OPTEE_OS]=optee-os [BM_APP]=bm-app )
# defconfig custom-git key -> local.mk prefix that overrides it (if present)
declare -A OVERRIDDEN_BY=( [BR2_TARGET_OPENSBI]=OPENSBI [BR2_TARGET_OPTEE_OS]=OPTEE_OS )

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
sanitize_stream() { ( trap '' INT; exec sed -u "${SED_ARGS[@]}" ); }

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
lm_var()  { sed -nE "s/^$1[[:space:]]*:?=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\\1/p" local.mk | head -n1; }
dc_var()  { sed -nE "s/^$1=\"?([^\"]*)\"?$/\\1/p" "configs/${DEFCONFIG_NAME}" | head -n1; }
resolve() {   # resolve <url> <ref> -> commit SHA (empty if not found); annotated tags are peeled
              # ${TMPD}/lsr.err is non-empty afterwards if the repository itself was not accessible
  local out sha rc
  if printf '%s' "$2" | grep -Eq '^[0-9a-f]{40}$'; then echo "$2"; return; fi
  out="$(git ls-remote "$1" 2>"${TMPD}/lsr.err")" \
    || { rc=$?; [ -s "${TMPD}/lsr.err" ] || echo "git ls-remote failed with exit code ${rc}" > "${TMPD}/lsr.err"; echo ""; return; }
  : > "${TMPD}/lsr.err"
  sha="$(printf '%s\n' "${out}" | awk -v r="$2" '$2 == "refs/tags/" r "^{}" {print $1; exit}')"
  [ -n "${sha}" ] || sha="$(printf '%s\n' "${out}" | awk -v r="$2" '$2 == "refs/heads/" r || $2 == "refs/tags/" r {print $1; exit}')"
  echo "${sha}"
}

explain_missing() {   # explain_missing <component> <url> <ref>
  if [ -s "${TMPD}/lsr.err" ]; then
    echo "[NG]   $1: the repository is NOT accessible: ${2}"
    sed 's/^/         git: /' "${TMPD}/lsr.err" | head -n 3
  else
    echo "[NG]   $1: the repository is accessible, but '$3' is neither a branch nor a tag: $2"
    echo "         branches with a similar prefix:"
    git ls-remote --heads "$2" 2>/dev/null | awk '{sub("refs/heads/","",$2); print $2}' \
      | grep -iE "^(${3%%-*}|${3%%_*})" | head -n 15 | sed 's/^/           /'
  fi
}

# pins collected at prepare time: "<kind>|<name>|<url>|<ref>|<sha>"
PINS=()

step_precheck() {
  section "1. Pre-checks"
  local mem disk
  mem="$(awk '/^MemAvailable:/{printf "%d", $2/1048576}' /proc/meminfo)"
  disk="$(df -BG --output=avail "${PROJECT_ROOT}" | tail -n1 | tr -dc '0-9')"
  if   [ "${mem}" -lt "${MEM_ABORT}" ]; then echo "[NG]   MemAvailable ${mem} GiB"; fail; return 1
  elif [ "${mem}" -lt "${MEM_OK}" ];    then echo "[WARN] MemAvailable ${mem} GiB (< ${MEM_OK} recommended)"
  else                                       echo "[OK]   MemAvailable ${mem} GiB"; fi
  if   [ "${disk}" -lt "${DISK_ABORT}" ]; then echo "[NG]   free disk ${disk} GiB (< ${DISK_ABORT})"; fail; return 1
  elif [ "${disk}" -lt "${DISK_OK}" ];    then echo "[WARN] free disk ${disk} GiB (< ${DISK_OK} recommended)"
  else                                         echo "[OK]   free disk ${disk} GiB"; fi
  [ -d "${M1_TREE}/.git" ] && echo "[OK]   M1 reference tree present (it is not modified by this script)" \
                           || echo "[INFO] M1 reference tree not found (download seeding skipped)"
  echo "Target   : ${TARGET}   branch ${BRANCH}   pinned ${PIN_BR}"
  echo "Tree     : work/buildroot-${TARGET}"
  echo "BR2_DL_DIR: work/dl-g05"
  echo "Jobs     : make -j${JOBS}, BR2_JLEVEL=${JOBS} (set G05B_JOBS to change)"
}

step_tree() {
  section "2. Buildroot tree (pinned)"
  local tip head
  tip="$(git ls-remote "${BR_URL}" "refs/heads/${BRANCH}" 2>/dev/null | awk '{print $1}')"
  if [ -z "${tip}" ]; then echo "[NG]   branch ${BRANCH} not found on the remote"; fail; return 1; fi
  [ "${tip}" = "${PIN_BR}" ] && echo "[OK]   remote ${BRANCH} tip = pinned commit" \
                             || echo "[INFO] remote ${BRANCH} tip is now ${tip}; building the pinned ${PIN_BR}"
  if [ ! -d "${TREE}/.git" ]; then
    run "git clone --quiet -b '${BRANCH}' '${BR_URL}' '${TREE}'" || return 1
  else
    run "git -C '${TREE}' fetch --quiet origin" || return 1
  fi
  cd "${TREE}" || { echo "[NG]   cannot enter the tree"; fail; return 1; }
  if ! git diff --quiet HEAD; then echo "[NG]   tracked files of this tree are modified"; git diff --stat HEAD; fail; return 1; fi
  run "git checkout --quiet -B '${BRANCH}' '${PIN_BR}'" || return 1
  head="$(git rev-parse HEAD)"
  [ "${head}" = "${PIN_BR}" ] && echo "[OK]   HEAD ${head}" || { echo "[NG]   HEAD ${head}"; fail; return 1; }
  run "git log -1 --format='%cs %s'"
  [ -x utils/config ] || { echo "[NG]   utils/config missing"; fail; return 1; }
  PINS+=("buildroot|buildroot|${BR_URL}|${BRANCH}|${PIN_BR}")
}

step_dl() {
  section "3. Shared download directory (hard links to M1 tarballs, git caches excluded)"
  local n
  if [ -d "${BR2_DL_DIR}" ]; then
    echo "[OK]   work/dl-g05 exists ($(find "${BR2_DL_DIR}" -type f | wc -l) files) - not re-seeded"
  elif [ -d "${M1_TREE}/dl" ]; then
    mkdir -p "${BR2_DL_DIR}"
    ( cd "${M1_TREE}/dl" && find . -type f -not -path '*/git/*' -print0 \
        | while IFS= read -r -d '' f; do mkdir -p "${BR2_DL_DIR}/$(dirname "${f}")"; ln "${f}" "${BR2_DL_DIR}/${f}"; done )
    n="$(find "${BR2_DL_DIR}" -type f | wc -l)"
    echo "[OK]   seeded work/dl-g05 with ${n} hard-linked files (M1 dl unchanged)"
  else
    mkdir -p "${BR2_DL_DIR}"; echo "[INFO] empty work/dl-g05 created"
  fi
}

step_discover() {
  section "4. Components (read from local.mk and the defconfig, resolved to SHAs)"
  local p url br sha key ver d v
  echo "-- local.mk lines that define the overrides (for the record) --"
  grep -nE 'CUSTOM_[A-Z0-9_]+|custom/|OVERRIDE_SRCDIR' local.mk 2>/dev/null | head -n 60 || echo "(no local.mk)"
  echo "-- local.mk overrides --"
  for p in $(sed -nE 's/^CUSTOM_([A-Z0-9_]+)_GITURL[[:space:]]*:?=.*/\1/p' local.mk 2>/dev/null | sort -u); do
    url="$(lm_var "CUSTOM_${p}_GITURL")"; br="$(lm_var "CUSTOM_${p}_BRANCH")"
    d=""
    for v in DIR SRCDIR PATH; do
      d="$(lm_var "CUSTOM_${p}_${v}")"; [ -n "${d}" ] && break
    done
    if printf '%s' "${d}" | grep -q 'custom/'; then
      CUSTOM_DIR[${p}]="$(basename "${d}")"
    elif [ -z "${CUSTOM_DIR[${p}]:-}" ]; then
      echo "[NG]   local.mk component CUSTOM_${p}: its custom/ directory could not be determined - the script must be extended"; fail; return 1
    fi
    sha="$(resolve "${url}" "${br}")"
    [ -n "${sha}" ] || { explain_missing "${p}" "${url}" "${br}"; fail; return 1; }
    printf '[OK]   %-9s custom/%-9s %s @ %s\n' "${p}" "${CUSTOM_DIR[${p}]}" "${br}" "${sha}"
    PINS+=("local.mk|${p}|${url}|${br}|${sha}")
  done
  echo "-- defconfig custom git repos --"
  for key in $(sed -nE 's/^(BR2_[A-Z0-9_]+)_CUSTOM_REPO_URL=.*/\1/p' "configs/${DEFCONFIG_NAME}"); do
    url="$(dc_var "${key}_CUSTOM_REPO_URL")"; ver="$(dc_var "${key}_CUSTOM_REPO_VERSION")"
    sha="$(resolve "${url}" "${ver}")"
    [ -n "${sha}" ] || { explain_missing "${key}" "${url}" "${ver}"; fail; return 1; }
    if [ -n "${OVERRIDDEN_BY[${key}]:-}" ] && grep -q "^CUSTOM_${OVERRIDDEN_BY[${key}]}_GITURL" local.mk 2>/dev/null; then
      printf '[INFO] %-20s overridden by local.mk (defconfig version %s not used)\n' "${key}" "${ver}"
    else
      printf '[OK]   %-20s %s @ %s (pinned in .config)\n' "${key}" "${ver}" "${sha}"
      PINS+=("defconfig|${key}|${url}|${ver}|${sha}")
    fi
  done
  echo "-- defconfig custom tarballs (must be pinned by a commit SHA in the URL) --"
  for key in $(sed -nE 's/^(BR2_[A-Z0-9_]+)_CUSTOM_TARBALL_LOCATION=.*/\1/p' "configs/${DEFCONFIG_NAME}"); do
    url="$(dc_var "${key}_CUSTOM_TARBALL_LOCATION")"
    sha="$(printf '%s' "${url}" | grep -oE '[0-9a-f]{40}' | head -n1)"
    if [ -n "${sha}" ]; then
      printf '[OK]   %-20s tarball at commit %s\n         %s\n' "${key}" "${sha}" "${url}"
      PINS+=("tarball|${key}|${url}|-|${sha}")
    else
      printf '[NG]   %-20s tarball URL contains no commit SHA (not reproducible): %s\n' "${key}" "${url}"; fail; return 1
    fi
  done
  echo "-- version-related defconfig lines (for the record) --"
  grep -nE '_CUSTOM_|_VERSION|_LATEST|QEMU' "configs/${DEFCONFIG_NAME}" | head -n 40
  printf '%s\n' "${PINS[@]}" | sanitize > "${PINS_FILE}"; chmod 644 "${PINS_FILE}"
  echo "pins written to logs/gate05/$(basename "${PINS_FILE}")"
}

step_seed() {
  section "5. Pin custom/ checkouts (local branch at the pinned SHA)"
  local e kind name url ref sha dir origin
  for e in "${PINS[@]}"; do
    IFS='|' read -r kind name url ref sha <<<"${e}"
    [ "${kind}" = "local.mk" ] || continue
    dir="custom/${CUSTOM_DIR[${name}]}"
    echo; echo "--- ${dir}"
    if [ ! -d "${dir}/.git" ]; then
      run "git clone --quiet '${url}' '${dir}'" || return 1
    else
      origin="$(git -C "${dir}" remote get-url origin 2>/dev/null)"
      [ "${origin}" = "${url}" ] || { echo "[NG]   origin ${origin} != ${url}"; fail; return 1; }
      run "git -C '${dir}' fetch --quiet --all --tags" || return 1
    fi
    [ -z "$(git -C "${dir}" status --porcelain --untracked-files=no)" ] || { echo "[NG]   ${dir} modified"; fail; return 1; }
    run "git -C '${dir}' checkout --quiet -B '${ref}' '${sha}'" || return 1
    [ "$(git -C "${dir}" rev-parse HEAD)" = "${sha}" ] && echo "[OK]   ${dir} HEAD = ${sha} (branch ${ref})" \
                                                     || { echo "[NG]   ${dir} HEAD mismatch"; fail; return 1; }
  done
}

step_config() {
  section "6. Configure (upstream defconfig + SHAs in .config)"
  local e kind name url ref sha
  run "make -s ${DEFCONFIG_NAME}" || return 1
  for e in "${PINS[@]}"; do
    IFS='|' read -r kind name url ref sha <<<"${e}"
    [ "${kind}" = "defconfig" ] || continue
    run "utils/config --file .config --set-str ${name}_CUSTOM_REPO_VERSION ${sha}" || return 1
  done
  run "utils/config --file .config --set-val BR2_JLEVEL ${JOBS}" || return 1
  run "make -s olddefconfig" || return 1
  grep -qxF "BR2_JLEVEL=${JOBS}" .config && echo "[OK]   .config BR2_JLEVEL=${JOBS} (per-package parallel jobs)" \
                                       || { echo "[NG]   BR2_JLEVEL not set to ${JOBS}"; fail; return 1; }
  for e in "${PINS[@]}"; do
    IFS='|' read -r kind name url ref sha <<<"${e}"
    [ "${kind}" = "defconfig" ] || continue
    grep -qxF "${name}_CUSTOM_REPO_VERSION=\"${sha}\"" .config \
      && echo "[OK]   .config ${name}_CUSTOM_REPO_VERSION=${sha}" \
      || { echo "[NG]   .config ${name} not pinned"; fail; return 1; }
  done
  run "make -s --no-print-directory printvars VARS='LINUX_VERSION UBOOT_VERSION OPENSBI_VERSION OPTEE_OS_VERSION QEMU_VERSION OPTEE_TEST_VERSION'" \
    > "${TMPD}/printvars.out"          # no pipe: run() must update FAILS in this shell
  cat "${TMPD}/printvars.out"
  echo "-- every override directory Buildroot will use must be one of the pinned checkouts --"
  local seeded path ok=1 n=0
  seeded=" "; for e in "${PINS[@]}"; do IFS='|' read -r kind name url ref sha <<<"${e}"; [ "${kind}" = "local.mk" ] && seeded+="${TREE}/custom/${CUSTOM_DIR[${name}]} "; done
  while IFS= read -r path; do
    n=$((n + 1))
    case "${seeded}" in
      *" ${path} "*) echo "[OK]   ${path#"${TREE}"/}" ;;
      *) echo "[NG]   ${path#"${TREE}"/} is used by Buildroot but was not pinned"; ok=0 ;;
    esac
  done < <(sed -nE 's/^\[BR\] .* override enabled: (.*)$/\1/p' "${TMPD}/printvars.out" | sort -u)
  [ "${n}" -gt 0 ] || echo "[INFO] Buildroot reports no override directories"
  [ "${ok}" -eq 1 ] || { fail; return 1; }
}

step_build() {
  section "7. Build (make -j${JOBS}, BR2_JLEVEL=${JOBS})"
  local start end rc
  echo "Full output: logs/gate05/raw/$(basename "${MAKE_RAW}") (raw)  /  logs/gate05/$(basename "${MAKE_LOG}") (sanitized)"
  start="$(date +%s)"
  make -j"${JOBS}" 2>&1 | tee "${MAKE_RAW}" \
    | grep --line-buffered -E '^(>>> |\[BR\] )' \
    | while IFS= read -r l; do printf '[%s] %s\n' "$(date +%H:%M:%S)" "${l}"; done
  rc=${PIPESTATUS[0]}
  end="$(date +%s)"
  printf '$ make -j%s\n[rc=%d]\nElapsed : %d min %d s\n' "${JOBS}" "${rc}" $(( (end - start) / 60 )) $(( (end - start) % 60 ))
  sanitize < "${MAKE_RAW}" > "${MAKE_LOG}"; chmod 600 "${MAKE_RAW}"; chmod 644 "${MAKE_LOG}"
  if [ "${rc}" -ne 0 ]; then fail; echo "[NG]   build failed - last 80 lines:"; tail -n 80 "${MAKE_RAW}"; return 1; fi
  echo "[OK]   build finished"
}

step_verify() {
  section "8. Verify the commits actually used"
  local e kind name url ref sha dir pkg
  for e in "${PINS[@]}"; do
    IFS='|' read -r kind name url ref sha <<<"${e}"
    case "${kind}" in
      local.mk)
        dir="custom/${CUSTOM_DIR[${name}]}"
        if [ "$(git -C "${dir}" rev-parse HEAD 2>/dev/null)" = "${sha}" ] && [ -z "$(git -C "${dir}" status --porcelain --untracked-files=no)" ]; then
          printf '[OK]   %-16s HEAD = %s\n' "${dir}" "${sha}"
        else
          printf '[NG]   %-16s not at %s (or modified)\n' "${dir}" "${sha}"; fail
        fi ;;
      tarball)
        case "${name}" in
          BR2_LINUX_KERNEL) pkg=linux ;; BR2_TARGET_UBOOT) pkg=uboot ;;
          *) pkg="$(printf '%s' "${name#BR2_}" | sed -E 's/^(PACKAGE|TARGET)_//' | tr 'A-Z_' 'a-z-')" ;;
        esac
        if [ -d "output/build/${pkg}-custom" ]; then
          echo "[OK]   output/build/${pkg}-custom (tarball at ${sha:0:12})"
        else
          echo "[NG]   output/build/${pkg}-custom not found for ${name}"; fail
        fi ;;
      defconfig)
        case "${name}" in
          BR2_LINUX_KERNEL) pkg=linux ;; BR2_TARGET_UBOOT) pkg=uboot ;;
          *) pkg="$(printf '%s' "${name#BR2_}" | sed -E 's/^(PACKAGE|TARGET)_//' | tr 'A-Z_' 'a-z-')" ;;
        esac
        if [ -n "${pkg}" ] && [ -d "output/build/${pkg}-${sha}" ]; then
          echo "[OK]   output/build/${pkg}-${sha}"
        else
          echo "[NG]   build directory for ${name} @ ${sha} not found"; ls -d output/build/"${pkg}"-* 2>/dev/null; fail
        fi ;;
    esac
  done

  section "9. Artifacts and generated start scripts (input for the G05b-2 tests)"
  run "ls -l output/images"
  echo "-- sha256 (start scripts excluded) --"
  ( cd output/images && find . -maxdepth 1 -type f ! -name '*.sh' -printf '%f\n' | sort | xargs -r sha256sum )
  if [ -x output/host/bin/qemu-system-riscv64 ]; then run "output/host/bin/qemu-system-riscv64 --version | head -n1"; fi
  for f in output/images/*.sh; do
    [ -f "${f}" ] || continue
    echo; echo "----- ${f} -----"; cat "${f}"
  done
  echo; echo "-- device-tree sources / overlays shipped with the images --"
  find output/images board -maxdepth 3 \( -name '*.dts' -o -name '*.dtso' -o -name '*overlay*' \) 2>/dev/null | sort | head -n 20
  if [ -d custom ]; then run "du -sh output custom"; else run "du -sh output"; fi   # v9: no local.mk, no custom/
}

# ---- main --------------------------------------------------------------------------
{
  section "0. Meta"
  echo "Gate        : ${GATE} build (${TARGET}: ${BRANCH}, own tree)"
  echo "Mode        : ${MODE}"
  echo "Timestamp   : ${TS}"
  echo "Script      : scripts/$(basename "${SCRIPT_PATH}")  sha256=$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"
  if step_precheck && step_tree && step_dl && step_discover && step_seed && step_config; then
    if [ "${MODE}" = "full" ]; then
      step_build && step_verify
    else
      echo; echo "[INFO] --prepare-only: stopped before the build"
    fi
  fi
  section "10. Summary"
  echo "Target          : ${TARGET} (${BRANCH} @ ${PIN_BR:0:12})"
  echo "Mode            : ${MODE}"
  echo "Failed checks   : ${FAILS}"
  if [ "${FAILS}" -ne 0 ]; then
    echo "Verdict         : ${FAILS} CHECK(S) FAILED - search this log for '[NG]'"
  elif [ "${MODE}" = "prepare-only" ]; then
    echo "Verdict         : PREPARED - run without --prepare-only to build"
  else
    echo "Verdict         : BUILD COMPLETED AND VERIFIED"
  fi
  echo "Next            : upload logs/gate05/$(basename "${LOG_FILE}") and its .sha256 manifest"
  [ "${FAILS}" -eq 0 ]
} 2>&1 | tee -i "${RAW_FILE}" | sanitize_stream | tee -i "${LOG_FILE}"
STATUS=$?

chmod 600 "${RAW_FILE}"; chmod 644 "${LOG_FILE}"
( cd "${PROJECT_ROOT}" && find logs/gate05 -maxdepth 2 -type f -name "gate${GATE}_${TARGET}_*${TS}*" ! -name '*.sha256' -print0 | sort -z \
    | xargs -0 sha256sum > "${MANIFEST}" && sha256sum "${SCRIPT_PATH#"${PROJECT_ROOT}"/}" >> "${MANIFEST}" && chmod 600 "${MANIFEST}" )
echo
echo "Sanitized log   : ${LOG_FILE#"${PROJECT_ROOT}"/}"
echo "sha256 manifest : ${MANIFEST#"${PROJECT_ROOT}"/}"
echo "Exit status     : ${STATUS}"
exit "${STATUS}"
