#!/usr/bin/env bash
# =============================================================================
#  Gate 01 : Source acquisition, branch survey and version pinning
#  Project : RISC-V-OP-TEE-On-QEMU-Reproduction
#  Target  : https://gitlab.com/riseproject/riscv-optee  (baseline: rp016_m1)
#
#  - Clones Buildroot (umbrella project) into work/buildroot. NO build is run.
#  - Records the remote branches of every component repo of the group.
#  - Lists every source the defconfig / package files point to and resolves
#    branch or tag names to exact commit SHAs.
#  - Runs 'make <defconfig>' and 'make printvars' only (configuration step;
#    no package is downloaded or built).
#  - Logging (audit requirements):
#      * every command run through run() records its exit code ([rc=N]);
#        failures are counted and decide the final verdict / exit status;
#      * pipefail is enabled, so a failure inside the logging pipeline is
#        not hidden by tee;
#      * the unmasked raw output is kept LOCALLY in logs/gate01/raw/
#        (never published), next to a sha256 manifest of the raw log,
#        the sanitized log, the branch list and this script itself.
#  - Every line of the publishable log passes through sanitize() first.
#
#  Usage : bash scripts/gate01_fetch_sources.sh   (from the project root)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "${SCRIPT_DIR}")" != "scripts" ]; then
  echo "ERROR: place this script in <project-root>/scripts/ and run it from there." >&2
  exit 1
fi
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"   # works wherever the repository is cloned
WORK_DIR="${PROJECT_ROOT}/work"
BR_DIR="${WORK_DIR}/buildroot"
LOG_DIR="${PROJECT_ROOT}/logs/gate01"
TS="$(date +%Y%m%d-%H%M%S)"
RAW_DIR="${LOG_DIR}/raw"                       # local only - excluded from GitHub
LOG_FILE="${LOG_DIR}/gate01_fetch_sources_${TS}.log"
BRANCH_FILE="${LOG_DIR}/gate01_remote_branches_${TS}.txt"
RAW_FILE="${RAW_DIR}/gate01_fetch_sources_${TS}.raw.log"
MANIFEST="${RAW_DIR}/gate01_fetch_sources_${TS}.sha256"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

GROUP_URL="https://gitlab.com/riseproject/riscv-optee"
BASE_BRANCH="rp016_m1"
DEFCONFIG="configs/qemu_riscv64_virt_optee_defconfig"
REPOS="buildroot optee_os opensbi u-boot linux qemu bm-app"

mkdir -p "${LOG_DIR}" "${RAW_DIR}" "${WORK_DIR}"
export GIT_TERMINAL_PROMPT=0   # fail fast instead of waiting for credentials

# ---- sanitizer (Gate 00 rules; loopback 127.0.0.1 is kept as-is) ----------
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
fail()    { FAILS=$((FAILS + 1)); }
# run <command-string> : print the command, run it, record its exit code
run() {
  local rc
  printf '$ %s\n' "$1"
  bash -c "$1" 2>&1; rc=$?
  printf '[rc=%d]\n' "${rc}"
  [ "${rc}" -ne 0 ] && fail
  return "${rc}"
}

# resolve <url> <ref> : print the commit SHA a branch / tag name points to
resolve() {
  local url="$1" ref="$2" refs hit
  if printf '%s' "${ref}" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "    -> ${ref}  (already a full commit SHA)"; return
  fi
  refs="$(git ls-remote --heads --tags "${url}" 2>&1)" || { fail; echo "    -> [NG] ls-remote failed: ${refs}" | head -n3; return; }
  hit="$(printf '%s\n' "${refs}" | grep -E "[[:space:]]refs/tags/${ref}\^\{\}$" | head -n1)"
  [ -z "${hit}" ] && hit="$(printf '%s\n' "${refs}" | grep -E "[[:space:]]refs/(heads|tags)/${ref}$" | head -n1)"
  if [ -n "${hit}" ]; then
    echo "    -> ${hit%%[[:space:]]*}  ($(printf '%s' "${hit}" | awk '{print $2}'))"
  else
    echo "    -> [INFO] '${ref}' is not a branch/tag name (short SHA or variable?) - resolve manually"
  fi
}

CLONE_OK=0
{
  section "0. Meta"
  echo "Gate        : 01 (Source acquisition, branch survey, version pinning)"
  echo "Timestamp   : ${TS}"
  echo "ProjectRoot : ${PROJECT_ROOT}"
  echo "Group       : ${GROUP_URL}"
  echo "Baseline    : ${BASE_BRANCH}"
  echo "Script      : scripts/$(basename "${SCRIPT_PATH}")  sha256=$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"
  echo "Raw log     : logs/gate01/raw/$(basename "${RAW_FILE}")  (local only, not published)"

  section "1. Remote branches of each component repo"
  echo "(full lists -> $(basename "${BRANCH_FILE}"))"
  for r in ${REPOS}; do
    url="${GROUP_URL}/${r}.git"
    heads="$(git ls-remote --heads "${url}" 2>&1)"; rc=$?
    { printf '### %s  (%s)\n' "${r}" "${url}"; printf '%s\n\n' "${heads}"; } | sanitize >> "${BRANCH_FILE}"
    if [ ${rc} -ne 0 ]; then
      printf '[NG]   %-10s ls-remote failed (rc=%d)\n' "${r}" "${rc}"
      fail
      continue
    fi
    n="$(printf '%s\n' "${heads}" | grep -c 'refs/heads/')"
    base="$(printf '%s\n' "${heads}" | grep -E "[[:space:]]refs/heads/${BASE_BRANCH}$" | awk '{print $1}')"
    printf '[OK]   %-10s %3s branches   %s: %s\n' "${r}" "${n}" "${BASE_BRANCH}" "${base:-(not present)}"
  done

  section "2. Clone Buildroot (${BASE_BRANCH})"
  if [ -d "${BR_DIR}/.git" ]; then
    echo "[INFO] work/buildroot already exists - not cloning again"
    CLONE_OK=1
  else
    echo "cloning ... (this can take a few minutes)"
    if run "git clone --quiet -b '${BASE_BRANCH}' '${GROUP_URL}/buildroot.git' '${BR_DIR}'"; then
      echo "[OK]   clone finished"; CLONE_OK=1
    else
      echo "[NG]   clone failed - later sections are skipped"
    fi
  fi

  if [ ${CLONE_OK} -eq 1 ]; then
    cd "${BR_DIR}" || exit 1

    section "3. Buildroot HEAD (pin this)"
    run "git branch --show-current"
    run "git log -1 --format='commit  %H%ndate    %cI%nsubject %s'"
    run "git describe --tags --always"
    run "git status --short | head -n 20"

    section "4. Defconfig (${DEFCONFIG})"
    if [ -f "${DEFCONFIG}" ]; then
      run "cat '${DEFCONFIG}'"
    else
      fail
      echo "[NG]   ${DEFCONFIG} not found. Available riscv defconfigs:"
      ls configs | grep -i riscv
    fi

    section "5. Custom sources in the defconfig -> commit SHA"
    if [ -f "${DEFCONFIG}" ]; then
      while IFS='=' read -r key val; do
        prefix="${key%_CUSTOM_REPO_URL}"
        url="$(printf '%s' "${val}" | tr -d '"')"
        ver="$(grep -E "^${prefix}_CUSTOM_REPO_VERSION=" "${DEFCONFIG}" | head -n1 | cut -d= -f2- | tr -d '"')"
        echo "${prefix}"
        echo "    url     : ${url}"
        echo "    version : ${ver:-(not set)}"
        [ -n "${ver}" ] && resolve "${url}" "${ver}"
      done < <(grep -E '^BR2_[A-Z0-9_]+_CUSTOM_REPO_URL=' "${DEFCONFIG}")
      echo
      echo "-- other source-related lines (tarballs / custom git / host-qemu / optee packages) --"
      grep -nE 'TARBALL|CUSTOM_GIT|CUSTOM_VERSION|HOST_QEMU|OPTEE|OPENSBI|UBOOT|LINUX_KERNEL_VERSION|TOOLCHAIN' "${DEFCONFIG}" || echo "(none)"
    fi

    section "6. Resolved versions of packages without a custom repo (configuration only, nothing is built)"
    run "make -s $(basename "${DEFCONFIG}")"
    echo
    echo "-- Buildroot package files that reference riseproject --"
    grep -rlE 'riseproject' package boot linux toolchain --include='*.mk' 2>/dev/null || echo "(none: these packages use their upstream sources)"
    echo
    echo "-- resolved make variables --"
    run "make -s --no-print-directory printvars VARS='QEMU_VERSION QEMU_SOURCE QEMU_SITE OPTEE_CLIENT_VERSION OPTEE_CLIENT_SITE OPTEE_TEST_VERSION OPTEE_TEST_SITE OPTEE_EXAMPLES_VERSION OPTEE_EXAMPLES_SITE TOOLCHAIN_EXTERNAL_BOOTLIN_VERSION TOOLCHAIN_EXTERNAL_BOOTLIN_SOURCE TOOLCHAIN_EXTERNAL_BOOTLIN_SITE'"
    echo
    echo "-- selected toolchain / OP-TEE / host-qemu options in .config (in-tree build) --"
    grep -E '^BR2_(TOOLCHAIN_EXTERNAL_[A-Z0-9_]+|PACKAGE_OPTEE[A-Z0-9_]*|PACKAGE_HOST_QEMU[A-Z0-9_]*|GCC_VERSION|TOOLCHAIN_HEADERS_AT_LEAST)=' .config || echo "(none)"

    section "6b. Local source overrides (custom/ directory)"
    echo "-- files that print the '[BR] ... override enabled' messages --"
    ovr_files="$(grep -rlE 'override enabled' --exclude-dir=output --exclude-dir=dl --exclude-dir=.git . 2>/dev/null)"
    if [ -z "${ovr_files}" ]; then
      echo "(none found)"
    else
      for f in ${ovr_files}; do
        n="$(wc -l < "${f}")"
        echo; echo "--- ${f} (${n} lines)"
        if [ "${n}" -le 300 ]; then
          cat "${f}"
        else
          grep -nE -B3 -A12 'override|custom/' "${f}" | head -n 200
        fi
      done
    fi
    echo
    echo "-- top commit of the Buildroot fork (files changed) --"
    run "git show --stat --format='commit  %H%nsubject %s' HEAD"
    echo
    echo "-- recent commits on ${BASE_BRANCH} --"
    run "git log --format='%h %cs %s' -15"
    echo
    echo "-- state of custom/ --"
    if [ -d custom ]; then
      for d in custom/*/; do
        [ -e "${d}" ] || continue
        d="${d%/}"
        if [ -d "${d}/.git" ]; then
          printf '%-20s %s  branch=%s  origin=%s\n' "${d}" "$(git -C "${d}" rev-parse HEAD 2>/dev/null)" \
            "$(git -C "${d}" branch --show-current 2>/dev/null)" "$(git -C "${d}" remote get-url origin 2>/dev/null)"
        else
          printf '%-20s (not a git checkout)\n' "${d}"
        fi
      done
    else
      echo "custom/ does not exist yet (presumably populated at build time)"
    fi

    section "7. QEMU start script sources (board/qemu/riscv64-virt-optee)"
    BOARD="board/qemu/riscv64-virt-optee"
    if [ -d "${BOARD}" ]; then
      echo "-- files in ${BOARD} --"
      find "${BOARD}" -type f | sort
    else
      echo "[NG]   ${BOARD} not found"
    fi
    for f in "${BOARD}/readme.txt" "${BOARD}/genimage_sdcard.cfg" board/qemu/post-image.sh board/qemu/start-qemu.sh.in; do
      if [ -f "${f}" ]; then
        echo; echo "--- ${f}"; cat "${f}"
      else
        echo; echo "--- ${f} (not found)"
      fi
    done
    echo
    echo "-- files under board/qemu that mention port 64320 / 64321 --"
    grep -rnwE '6432[01]' board/qemu 2>/dev/null || echo "(none)"

    section "8. Size of work/buildroot"
    run "du -sh ."
    run "du -sh output 2>/dev/null || true"
  fi

  section "9. Summary"
  if [ ${CLONE_OK} -eq 1 ]; then
    echo "[OK]   Buildroot cloned: $(git -C "${BR_DIR}" rev-parse HEAD)"
  else
    echo "[NG]   Buildroot not available"
  fi
  echo "Failed commands : ${FAILS}"
  if [ "${FAILS}" -eq 0 ]; then
    echo "Verdict         : COMPLETED WITHOUT COMMAND ERRORS"
  else
    echo "Verdict         : ${FAILS} COMMAND(S) FAILED - search this log for '[rc=' / '[NG]'"
  fi
  echo "Next   : upload this log ($(basename "${LOG_FILE}")) to the chat"
  [ "${FAILS}" -eq 0 ]
} 2>&1 | tee "${RAW_FILE}" | sanitize | tee "${LOG_FILE}"
STATUS=$?

# all paths in the manifest are relative to the project root:
#   verify with:  cd <project-root> && sha256sum -c logs/gate01/raw/<name>.sha256
( cd "${PROJECT_ROOT}" && sha256sum "${RAW_FILE#"${PROJECT_ROOT}"/}" "${LOG_FILE#"${PROJECT_ROOT}"/}" \
    "${BRANCH_FILE#"${PROJECT_ROOT}"/}" "${SCRIPT_PATH#"${PROJECT_ROOT}"/}" > "${MANIFEST}" )

echo
echo "Sanitized log      : ${LOG_FILE#"${PROJECT_ROOT}"/}"
echo "Remote branch list : ${BRANCH_FILE#"${PROJECT_ROOT}"/}"
echo "Raw log (local)    : ${RAW_FILE#"${PROJECT_ROOT}"/}"
echo "sha256 manifest    : ${MANIFEST#"${PROJECT_ROOT}"/}"
echo "Exit status        : ${STATUS}"
exit "${STATUS}"
