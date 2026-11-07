#!/usr/bin/env bash
# =============================================================================
#  Gate 02 : Buildroot build with pinned sources
#  Project : RISC-V-OP-TEE-On-QEMU-Reproduction
#  Target  : https://gitlab.com/riseproject/riscv-optee  (baseline: rp016_m1)
#
#  Steps
#    1. Pre-checks   : memory, disk, .gitignore, Buildroot HEAD, local.mk
#    2. Pin custom/  : clone QEMU / OpenSBI / OP-TEE OS / bm-app and create the
#                      local branch rp016_m1 AT THE PINNED SHA. The local.mk hook
#                      re-checks out the branch *name* at every build, and
#                      'git fetch' never moves a local branch, so the pin holds
#                      without editing local.mk.
#    3. Configure    : apply the upstream defconfig, then set the Linux and
#                      U-Boot versions to their SHAs in .config (olddefconfig).
#    4. Build        : 'make -j$(nproc)' as in the official instructions.
#                      The full output goes to a log file; the console shows
#                      only Buildroot '>>>' steps and local.mk '[BR]' messages.
#    5. Verify       : commits actually used, artifacts, Buildroot host QEMU.
#
#  Modes
#    bash scripts/gate02_build.sh --prepare-only   steps 1-3 only (no build)
#    bash scripts/gate02_build.sh                  steps 1-5
#
#  Logging: exit code of every command ([rc=N]), pipefail, sanitized logs in
#  logs/gate02/, unmasked raw logs + sha256 manifest in logs/gate02/raw/
#  (local only, never published). The upstream local.mk and defconfig are
#  never modified.
# =============================================================================
set -uo pipefail

MODE="full"
case "${1:-}" in
  "")             ;;
  --prepare-only) MODE="prepare-only" ;;
  *) echo "usage: bash scripts/gate02_build.sh [--prepare-only]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "${SCRIPT_DIR}")" != "scripts" ]; then
  echo "ERROR: place this script in <project-root>/scripts/ and run it from there." >&2
  exit 1
fi
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
BR_DIR="${PROJECT_ROOT}/work/buildroot"
LOG_DIR="${PROJECT_ROOT}/logs/gate02"
RAW_DIR="${LOG_DIR}/raw"                      # local only - excluded from GitHub
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/gate02_build_${TS}.log"
RAW_FILE="${RAW_DIR}/gate02_build_${TS}.raw.log"
MAKE_RAW="${RAW_DIR}/gate02_make_${TS}.raw.log"
MAKE_LOG="${LOG_DIR}/gate02_make_${TS}.log"
MANIFEST="${RAW_DIR}/gate02_build_${TS}.sha256"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

# ---- pins (rp016_m1 branch tips recorded in G01 on 2026-11-06) --------------
DEFCONFIG_NAME="qemu_riscv64_virt_optee_defconfig"
BASE_BRANCH="rp016_m1"
PIN_BUILDROOT="d7204671a32ca2edc521c35de758ce650ebf1cb6"
PIN_LINUX="2912ca616fc806dbeeba2e1ac7a157e0843d6987"
PIN_UBOOT="32bdb252fab83028768a269fb304b9356547ccbd"
# <custom dir name>|<local.mk variable prefix>|<pinned SHA>
CUSTOM_PINS=(
  "qemu|QEMU|9c23f2a7b0b45277693a14074b1aaa827eecdb92"
  "opensbi|OPENSBI|cdd401f1517b4599b7d08ce13cd83859acc4cbb2"
  "optee-os|OPTEE_OS|814978eb15b92c3b97255a8c000f44cd84aac008"
  "bm-app|BM_APP|97545c35a74ad387f7790b02a35b0f2b4d29bb6e"
)
REQUIRED_IMAGES="u-boot-spl u-boot.itb qemu_rv64_virt_domain.dtb sdcard.img start-qemu.sh fw_jump.bin bm-app.elf start-qemu-bm.sh"
EXPECTED_IMAGES="tee.bin Image rootfs.ext2"
MEM_OK=8;   MEM_ABORT=4     # GiB available
DISK_OK=50; DISK_ABORT=30   # GiB free

mkdir -p "${LOG_DIR}" "${RAW_DIR}"
export GIT_TERMINAL_PROMPT=0   # fail fast instead of waiting for credentials

# ---- sanitizer (same rules as G01; loopback 127.0.0.1 is kept) -------------
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
run() {   # run <command-string> : print, run, record the exit code
  local rc
  printf '$ %s\n' "$1"
  bash -c "$1" 2>&1; rc=$?
  printf '[rc=%d]\n' "${rc}"
  [ "${rc}" -ne 0 ] && fail
  return "${rc}"
}
lm_var() {   # value of a variable assigned in local.mk
  sed -nE "s/^$1[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\\1/p" local.mk | head -n1
}

# ---- 1. pre-checks ----------------------------------------------------------
step_precheck() {
  section "1. Pre-checks"
  local mem disk pat head e name prefix sha url br
  mem="$(awk '/^MemAvailable:/{printf "%d", $2/1048576}' /proc/meminfo)"
  disk="$(df -BG --output=avail "${PROJECT_ROOT}" | tail -n1 | tr -dc '0-9')"
  if   [ "${mem}" -lt "${MEM_ABORT}" ]; then echo "[NG]   MemAvailable ${mem} GiB (< ${MEM_ABORT}) - free memory first"; fail; return 1
  elif [ "${mem}" -lt "${MEM_OK}" ];    then echo "[WARN] MemAvailable ${mem} GiB (< ${MEM_OK} recommended)"
  else                                       echo "[OK]   MemAvailable ${mem} GiB"; fi
  if   [ "${disk}" -lt "${DISK_ABORT}" ]; then echo "[NG]   free disk ${disk} GiB (< ${DISK_ABORT})"; fail; return 1
  elif [ "${disk}" -lt "${DISK_OK}" ];    then echo "[WARN] free disk ${disk} GiB (< ${DISK_OK} recommended)"
  else                                         echo "[OK]   free disk ${disk} GiB"; fi

  for pat in 'work/' 'logs/**/raw/' 'logs/**/G*_checkpoint.md'; do
    if grep -qxF "${pat}" "${PROJECT_ROOT}/.gitignore" 2>/dev/null; then
      echo "[OK]   .gitignore contains ${pat}"
    else
      echo "[WARN] .gitignore does not contain ${pat}"
    fi
  done

  if ss -ltn 2>/dev/null | grep -Eq ':(64320|64321|2200)[[:space:]]'; then
    echo "[INFO] port 64320 / 64321 / 2200 already in use (matters only for G03)"
  else
    echo "[OK]   ports 64320 / 64321 / 2200 are free (used in G03)"
  fi

  head="$(git rev-parse HEAD)"
  if [ "${head}" = "${PIN_BUILDROOT}" ]; then
    echo "[OK]   Buildroot HEAD ${head}"
  else
    echo "[NG]   Buildroot HEAD ${head} != pinned ${PIN_BUILDROOT}"; fail; return 1
  fi
  if git diff --quiet HEAD; then
    echo "[OK]   no tracked file of the Buildroot tree is modified"
  else
    echo "[NG]   tracked files of the Buildroot tree are modified:"; git diff --stat HEAD; fail; return 1
  fi
  if [ -x utils/config ]; then echo "[OK]   utils/config available"; else echo "[NG]   utils/config missing"; fail; return 1; fi

  echo "-- local.mk entries --"
  for e in "${CUSTOM_PINS[@]}"; do
    IFS='|' read -r name prefix sha <<<"${e}"
    url="$(lm_var "CUSTOM_${prefix}_GITURL")"
    br="$(lm_var "CUSTOM_${prefix}_BRANCH")"
    if [ -n "${url}" ] && [ "${br}" = "${BASE_BRANCH}" ]; then
      printf '[OK]   %-9s url=%s branch=%s\n' "${name}" "${url}" "${br}"
    else
      printf '[NG]   %-9s unexpected local.mk entry (url=%s branch=%s)\n' "${name}" "${url:-?}" "${br:-?}"; fail; return 1
    fi
  done
  return 0
}

# ---- 2. pin the custom/ checkouts --------------------------------------------
step_seed() {
  section "2. Pin custom/ checkouts (local branch ${BASE_BRANCH} at the pinned SHA)"
  local e name prefix sha url dir origin head
  for e in "${CUSTOM_PINS[@]}"; do
    IFS='|' read -r name prefix sha <<<"${e}"
    url="$(lm_var "CUSTOM_${prefix}_GITURL")"
    dir="custom/${name}"
    echo; echo "--- ${name}"
    if [ ! -d "${dir}/.git" ]; then
      run "git clone --quiet '${url}' '${dir}'" || return 1
    else
      origin="$(git -C "${dir}" remote get-url origin 2>/dev/null)"
      if [ "${origin}" != "${url}" ]; then
        echo "[NG]   ${dir} origin is ${origin}, expected ${url}"; fail; return 1
      fi
      run "git -C '${dir}' fetch --quiet --all --tags" || return 1
    fi
    if [ -n "$(git -C "${dir}" status --porcelain --untracked-files=no)" ]; then
      echo "[NG]   ${dir} has modified tracked files - not touching it"; git -C "${dir}" status --short; fail; return 1
    fi
    run "git -C '${dir}' checkout --quiet -B '${BASE_BRANCH}' '${sha}'" || return 1
    head="$(git -C "${dir}" rev-parse HEAD)"
    if [ "${head}" = "${sha}" ]; then
      echo "[OK]   ${dir} HEAD = ${head} (branch ${BASE_BRANCH})"
    else
      echo "[NG]   ${dir} HEAD ${head} != ${sha}"; fail; return 1
    fi
  done
  return 0
}

# ---- 3. configure ------------------------------------------------------------
step_config() {
  section "3. Configure (upstream defconfig + Linux / U-Boot pinned in .config)"
  local p key sha
  run "make -s ${DEFCONFIG_NAME}" || return 1
  run "utils/config --file .config --set-str BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION ${PIN_LINUX}" || return 1
  run "utils/config --file .config --set-str BR2_TARGET_UBOOT_CUSTOM_REPO_VERSION ${PIN_UBOOT}" || return 1
  run "make -s olddefconfig" || return 1
  for p in "BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION|${PIN_LINUX}" "BR2_TARGET_UBOOT_CUSTOM_REPO_VERSION|${PIN_UBOOT}"; do
    IFS='|' read -r key sha <<<"${p}"
    if grep -qxF "${key}=\"${sha}\"" .config; then
      echo "[OK]   .config ${key}=\"${sha}\""
    else
      echo "[NG]   .config ${key} is not the pinned SHA:"; grep -E "^${key}=" .config; fail; return 1
    fi
  done
  run "make -s --no-print-directory printvars VARS='LINUX_VERSION UBOOT_VERSION OPENSBI_VERSION OPTEE_OS_VERSION QEMU_VERSION OPTEE_CLIENT_VERSION OPTEE_TEST_VERSION OPTEE_EXAMPLES_VERSION'" || return 1
  return 0
}

# ---- 4. build ----------------------------------------------------------------
step_build() {
  section "4. Build (make -j$(nproc))"
  echo "Full build output : logs/gate02/raw/$(basename "${MAKE_RAW}") (raw, local only)"
  echo "                    logs/gate02/$(basename "${MAKE_LOG}") (sanitized, written after the build)"
  echo "Console shows only Buildroot '>>>' steps and local.mk '[BR]' messages, with timestamps."
  local start end rc
  start="$(date +%s)"
  make -j"$(nproc)" 2>&1 | tee "${MAKE_RAW}" \
    | grep --line-buffered -E '^(>>> |\[BR\] )' \
    | while IFS= read -r l; do printf '[%s] %s\n' "$(date +%H:%M:%S)" "${l}"; done
  rc=${PIPESTATUS[0]}
  end="$(date +%s)"
  printf '$ make -j%s\n[rc=%d]\n' "$(nproc)" "${rc}"
  echo "Elapsed : $(( (end - start) / 60 )) min $(( (end - start) % 60 )) s"
  sanitize < "${MAKE_RAW}" > "${MAKE_LOG}"
  if [ "${rc}" -ne 0 ]; then
    fail
    echo "[NG]   build failed - last 80 lines of the build output:"
    tail -n 80 "${MAKE_RAW}"
    return 1
  fi
  echo "[OK]   build finished"
  return 0
}

# ---- 5. verify ---------------------------------------------------------------
step_verify() {
  local e name prefix sha dir head br p pkg f
  section "5. Verify the commits actually used"
  for e in "${CUSTOM_PINS[@]}"; do
    IFS='|' read -r name prefix sha <<<"${e}"
    dir="custom/${name}"
    head="$(git -C "${dir}" rev-parse HEAD 2>/dev/null)"
    br="$(git -C "${dir}" rev-parse "${BASE_BRANCH}" 2>/dev/null)"
    if [ "${head}" = "${sha}" ] && [ "${br}" = "${sha}" ]; then
      printf '[OK]   %-16s HEAD = %s = %s\n' "${dir}" "${sha}" "${BASE_BRANCH}"
    else
      printf '[NG]   %-16s HEAD=%s %s=%s pinned=%s\n' "${dir}" "${head:-?}" "${BASE_BRANCH}" "${br:-?}" "${sha}"; fail
    fi
    if [ -n "$(git -C "${dir}" status --porcelain --untracked-files=no)" ]; then
      echo "[NG]   ${dir} tracked files were modified during the build"; fail
    fi
  done
  for p in "linux|${PIN_LINUX}" "uboot|${PIN_UBOOT}"; do
    IFS='|' read -r pkg sha <<<"${p}"
    if [ -d "output/build/${pkg}-${sha}" ]; then
      echo "[OK]   output/build/${pkg}-${sha} (built from the pinned commit)"
    else
      echo "[NG]   output/build/${pkg}-${sha} not found:"; ls -d output/build/"${pkg}"-* 2>/dev/null; fail
    fi
    ls dl/"${pkg}"/ 2>/dev/null | grep -F "${sha}" | sed 's#^#       download: dl/'"${pkg}"'/#'
  done
  echo "-- override build directories --"
  ls -d output/build/*-custom 2>/dev/null || echo "(none)"

  section "6. Build artifacts (output/images)"
  run "ls -l output/images"
  for f in ${REQUIRED_IMAGES}; do
    if [ -e "output/images/${f}" ]; then echo "[OK]   ${f}"; else echo "[NG]   ${f} missing"; fail; fi
  done
  for f in ${EXPECTED_IMAGES}; do
    if [ -e "output/images/${f}" ]; then echo "[OK]   ${f}"; else echo "[WARN] ${f} not found (expected, not required)"; fi
  done
  echo "-- sha256 of the artifacts (start scripts excluded: they contain host paths) --"
  ( cd output/images && find . -maxdepth 1 -type f ! -name '*.sh' -printf '%f\n' | sort | xargs -r sha256sum )

  section "7. Buildroot host QEMU"
  if [ -x output/host/bin/qemu-system-riscv64 ]; then
    run "output/host/bin/qemu-system-riscv64 --version"
  else
    echo "[NG]   output/host/bin/qemu-system-riscv64 not found (start-qemu.sh would fall back to the system QEMU)"; fail
  fi
  run "du -sh output dl custom"
}

# ---- main ----------------------------------------------------------------------
{
  section "0. Meta"
  echo "Gate        : 02 (Buildroot build with pinned sources)"
  echo "Mode        : ${MODE}"
  echo "Timestamp   : ${TS}"
  echo "ProjectRoot : ${PROJECT_ROOT}"
  echo "Script      : scripts/$(basename "${SCRIPT_PATH}")  sha256=$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"
  echo "Raw log     : logs/gate02/raw/$(basename "${RAW_FILE}")  (local only, not published)"
  echo "Pins        : buildroot=${PIN_BUILDROOT}"
  echo "              linux=${PIN_LINUX}"
  echo "              u-boot=${PIN_UBOOT}"
  for e in "${CUSTOM_PINS[@]}"; do IFS='|' read -r n _ s <<<"${e}"; printf '              %s=%s\n' "${n}" "${s}"; done

  if ! cd "${BR_DIR}" 2>/dev/null; then
    echo "[NG]   work/buildroot not found - run G01 first"; fail
  elif step_precheck && step_seed && step_config; then
    if [ "${MODE}" = "full" ]; then
      step_build && step_verify
    else
      echo; echo "[INFO] --prepare-only: stopped before the build (nothing was compiled)"
    fi
  fi

  section "9. Summary"
  echo "Mode            : ${MODE}"
  echo "Failed commands : ${FAILS}"
  if [ "${FAILS}" -ne 0 ]; then
    echo "Verdict         : ${FAILS} CHECK(S) / COMMAND(S) FAILED - search this log for '[rc=' / '[NG]'"
  elif [ "${MODE}" = "prepare-only" ]; then
    echo "Verdict         : PREPARED - sources pinned and configured; run without --prepare-only to build"
  else
    echo "Verdict         : BUILD COMPLETED AND VERIFIED"
  fi
  echo "Next            : upload logs/gate02/$(basename "${LOG_FILE}") (the sanitized log) to the chat"
  [ "${FAILS}" -eq 0 ]
} 2>&1 | tee "${RAW_FILE}" | sanitize | tee "${LOG_FILE}"
STATUS=$?

# manifest: all paths relative to the project root
#   verify with:  cd <project-root> && sha256sum -c logs/gate02/raw/<name>.sha256
MFILES=("${RAW_FILE}" "${LOG_FILE}")
[ -f "${MAKE_RAW}" ] && MFILES+=("${MAKE_RAW}")
[ -f "${MAKE_LOG}" ] && MFILES+=("${MAKE_LOG}")
MFILES+=("${SCRIPT_PATH}")
( cd "${PROJECT_ROOT}" && sha256sum "${MFILES[@]#"${PROJECT_ROOT}"/}" > "${MANIFEST}" )

echo
echo "Sanitized log      : ${LOG_FILE#"${PROJECT_ROOT}"/}"
[ -f "${MAKE_LOG}" ] && echo "Sanitized make log : ${MAKE_LOG#"${PROJECT_ROOT}"/}"
echo "Raw logs (local)   : ${RAW_DIR#"${PROJECT_ROOT}"/}/"
echo "sha256 manifest    : ${MANIFEST#"${PROJECT_ROOT}"/}"
echo "Exit status        : ${STATUS}"
exit "${STATUS}"
