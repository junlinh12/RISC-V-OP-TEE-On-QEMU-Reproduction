#!/usr/bin/env bash
# =============================================================================
#  Gate 05a : isolation demonstration (PMP) + bare-metal app, on the M1 images
#  Project  : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  Modes
#    bash scripts/gate05a_isolation.sh --prepare-only   checks + launcher, no QEMU
#    bash scripts/gate05a_isolation.sh                  three boots + bm-app
#
#  Boots (every one with QEMU -snapshot: sdcard.img is never written)
#    U1  U-Boot md: control 0x80200000 (readable), probe 0xF1000000 (OP-TEE)
#    U2  U-Boot md: control 0x80200000 (readable), probe 0x80100000 (OpenSBI)
#    L   Linux: /proc/iomem, devmem control 0x0C000004 (PLIC) and the same
#        probes (supplementary: Linux may block /dev/mem before the access)
#  U-Boot runs in S-mode in the untrusted domain, like Linux, but without any
#  /dev/mem filter, so it shows the PMP enforcement directly.
#  READ accesses only. No source, build output or image is modified.
#
#  Safety (inherited from G03): refuses root; Buildroot QEMU only; upstream
#  start-qemu.sh untouched, loopback-only copy; ports must bind to 127.0.0.1;
#  QEMU always stopped on exit / Ctrl-C; -snapshot verified in the QEMU
#  command line; sdcard.img sha256 compared before and after.
#  Logging: umask 077, [rc=N], pipefail, sanitized logs in logs/gate05/, raw
#  logs + sha256 manifest in logs/gate05/raw/.
# =============================================================================
set -uo pipefail
umask 077

MODE="full"
case "${1:-}" in
  "")             ;;
  --prepare-only) MODE="prepare-only" ;;
  *) echo "usage: bash scripts/gate05a_isolation.sh [--prepare-only]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "${SCRIPT_DIR}")" != "scripts" ]; then
  echo "ERROR: place this script in <project-root>/scripts/ and run it from there." >&2
  exit 1
fi
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
BR_DIR="${PROJECT_ROOT}/work/buildroot"
IMG_DIR="${BR_DIR}/output/images"
HOST_BIN="${BR_DIR}/output/host/bin"
HOST_QEMU="${HOST_BIN}/qemu-system-riscv64"
LNX_CFG="${BR_DIR}/output/build/linux-2912ca616fc806dbeeba2e1ac7a157e0843d6987/.config"
LAUNCHER="${IMG_DIR}/start-qemu.loopback.sh"
DRIVER="${SCRIPT_DIR}/gate05a_console.py"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

LOG_DIR="${PROJECT_ROOT}/logs/gate05"
RAW_DIR="${LOG_DIR}/raw"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/gate05a_isolation_${TS}.log"
RAW_FILE="${RAW_DIR}/gate05a_isolation_${TS}.raw.log"
BM_RAW="${RAW_DIR}/gate05a_bm_app_${TS}.raw.log"
MANIFEST="${RAW_DIR}/gate05a_isolation_${TS}.sha256"
BOOT_TIMEOUT="${G05_BOOT_TIMEOUT:-600}"
BM_TIMEOUT="${G05_BM_TIMEOUT:-60}"
PORTS="64320 64321 2200"
CTRL_UB="0x80200000"; CTRL_LX="0x0c000004"
PROBE_OPTEE="0xf1000000"; PROBE_OSBI="0x80100000"

mkdir -p "${LOG_DIR}" "${RAW_DIR}" && chmod 755 "${LOG_DIR}" && chmod 700 "${RAW_DIR}"
TMPD="$(mktemp -d)"

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
sub()     { printf '\n--- %s\n' "$1"; }
FAILS=0
fail() { FAILS=$((FAILS + 1)); }
listening() { ss -ltnH 2>/dev/null | awk '{print $4}'; }

QPID=""; QIN=""; FIFO=""
cleanup() {
  trap '' PIPE
  if [ -n "${QPID}" ] && kill -0 "${QPID}" 2>/dev/null; then
    kill -TERM "${QPID}" 2>/dev/null; sleep 3
    kill -0 "${QPID}" 2>/dev/null && kill -KILL "${QPID}" 2>/dev/null
    echo "[CLEANUP] QEMU (pid ${QPID}) stopped" 2>/dev/null || true
  fi
  QPID=""
  if [ -n "${QIN}" ]; then exec {QIN}>&- 2>/dev/null; QIN=""; fi
  if [ -n "${FIFO}" ]; then rm -f "${FIFO}"; FIFO=""; fi
}
open_stdin_fifo() {
  FIFO="${TMPD}/qemu-stdin"; rm -f "${FIFO}"
  mkfifo -m 600 "${FIFO}" && exec {QIN}<>"${FIFO}"
}

# ---- 1. pre-checks ------------------------------------------------------------
step_precheck() {
  section "1. Safety pre-checks"
  local f p line found
  if [ "$(id -u)" -eq 0 ]; then echo "[NG]   running as root - refused"; fail; return 1; fi
  echo "[OK]   unprivileged user (uid $(id -u))"
  for t in ss python3 sha256sum timeout; do
    command -v "${t}" >/dev/null 2>&1 || { echo "[NG]   '${t}' not found"; fail; return 1; }
  done
  [ -x "${HOST_QEMU}" ] && echo "[OK]   Buildroot QEMU: $("${HOST_QEMU}" --version | head -n1)" \
                        || { echo "[NG]   ${HOST_QEMU} not found"; fail; return 1; }
  line="$(grep -E '^[[:space:]]*export PATH=' "${IMG_DIR}/start-qemu.sh" 2>/dev/null | head -n1)"
  printf '%s' "${line}" | grep -qF "${HOST_BIN}:" && echo "[OK]   start-qemu.sh puts output/host/bin first in PATH" \
                                                 || { echo "[NG]   start-qemu.sh PATH line unexpected"; fail; return 1; }
  for f in u-boot-spl u-boot.itb qemu_rv64_virt_domain.dtb sdcard.img start-qemu.sh start-qemu-bm.sh fw_jump.bin bm-app.elf; do
    [ -e "${IMG_DIR}/${f}" ] || { echo "[NG]   output/images/${f} missing"; fail; return 1; }
  done
  echo "[OK]   required images present"
  for p in ${PORTS}; do
    if listening | grep -Eq "[:.]${p}$"; then echo "[NG]   port ${p} already in use"; fail; return 1; fi
  done
  echo "[OK]   ports ${PORTS// / / } are free"
  [ -f "${DRIVER}" ] && echo "[OK]   scripts/$(basename "${DRIVER}")  sha256=$(sha256sum "${DRIVER}" | cut -d' ' -f1)" \
                     || { echo "[NG]   scripts/$(basename "${DRIVER}") missing"; fail; return 1; }
  echo "-- guest facts relevant to the Linux run (supplementary) --"
  grep -E '^CONFIG_(DEVMEM|STRICT_DEVMEM|IO_STRICT_DEVMEM)=|^# CONFIG_(DEVMEM|STRICT_DEVMEM|IO_STRICT_DEVMEM) is not set' "${LNX_CFG}" 2>/dev/null \
    | sed 's/^/kernel  /' || echo "kernel  (Linux .config not readable)"
  found=""
  for f in sbin/devmem usr/sbin/devmem bin/devmem usr/bin/devmem; do
    { [ -L "${BR_DIR}/output/target/${f}" ] || [ -e "${BR_DIR}/output/target/${f}" ]; } && found="/${f}"
  done
  if [ -n "${found}" ]; then
    echo "guest   devmem present (${found})"
  else
    echo "guest   devmem not found in output/target (Linux probes will be reported as OTHER)"
  fi
  SD_BEFORE="$(sha256sum "${IMG_DIR}/sdcard.img" | cut -d' ' -f1)"
  echo "sdcard.img sha256 before: ${SD_BEFORE}"
  return 0
}

# ---- 2. loopback-only launcher (identical to G03) --------------------------------
step_launcher() {
  section "2. Loopback-only launcher (upstream start-qemu.sh is not modified)"
  if [ "$(grep -c 'hostfwd=tcp::2200-:22' "${IMG_DIR}/start-qemu.sh")" -ne 1 ]; then
    echo "[NG]   unexpected hostfwd in start-qemu.sh"; fail; return 1
  fi
  sed 's/hostfwd=tcp::2200-:22/hostfwd=tcp:127.0.0.1:2200-:22/' "${IMG_DIR}/start-qemu.sh" > "${LAUNCHER}"
  chmod 700 "${LAUNCHER}"
  if [ "$(diff "${IMG_DIR}/start-qemu.sh" "${LAUNCHER}" | grep -c '^[<>]')" -eq 2 ]; then
    echo "[OK]   launcher regenerated (only the hostfwd address differs); every boot adds -snapshot"
  else
    echo "[NG]   unexpected launcher difference"; fail; return 1
  fi
  echo "-- plan --"
  echo "U1  U-Boot md: control ${CTRL_UB}, probe ${PROBE_OPTEE} (OP-TEE)"
  echo "U2  U-Boot md: control ${CTRL_UB}, probe ${PROBE_OSBI} (OpenSBI)"
  echo "L   Linux devmem: control ${CTRL_LX} (PLIC), probes ${PROBE_OPTEE} ${PROBE_OSBI}"
  echo "BM  start-qemu-bm.sh (timeout ${BM_TIMEOUT} s)"
}

# ---- 3. one guest run ------------------------------------------------------------
# qemu_run <label> <yes|no: wait for the guest to power off> <driver arguments...>
qemu_run() {
  local label="$1" waitexit="$2"; shift 2
  local craw="${RAW_DIR}/gate05a_${label}_console_${TS}.raw.log"
  local sraw="${RAW_DIR}/gate05a_${label}_qemu_stdio_${TS}.raw.log"
  local i seen=0 addr bad=0 drc
  sub "run ${label}"
  open_stdin_fifo || { echo "[NG]   cannot create stdin FIFO"; fail; return 1; }
  "${LAUNCHER}" -- -snapshot <&"${QIN}" > "${sraw}" 2>&1 &   # start-qemu.sh passes args after "--" to QEMU
  QPID=$!
  for i in $(seq 1 30); do
    if listening | grep -Eq '[:.]64320$'; then seen=1; break; fi
    kill -0 "${QPID}" 2>/dev/null || break
    sleep 1
  done
  if [ "${seen}" -ne 1 ]; then echo "[NG]   console port not listening"; tail -n 20 "${sraw}"; fail; cleanup; return 1; fi
  for p in 64320 2200; do
    addr="$(listening | grep -E "[:.]${p}$" | tr '\n' ' ')"
    if [ -n "${addr}" ] && printf '%s\n' ${addr} | grep -qv '^127\.0\.0\.1:'; then echo "[NG]   port ${p} bound to ${addr}"; bad=1; fi
  done
  [ "${bad}" -ne 0 ] && { echo "[NG]   stopping QEMU for safety"; fail; cleanup; return 1; }
  if tr '\0' ' ' < "/proc/${QPID}/cmdline" 2>/dev/null | grep -q -- ' -snapshot'; then
    echo "[OK]   QEMU pid ${QPID}: ports on 127.0.0.1, -snapshot active"
  else
    echo "[NG]   -snapshot not found in the QEMU command line - stopping"; fail; cleanup; return 1
  fi
  python3 "${DRIVER}" --transcript "${craw}" --boot-timeout "${BOOT_TIMEOUT}" "$@" | tee -a "${TMPD}/results.txt"
  drc=${PIPESTATUS[0]}
  printf '[rc=%d] console driver (%s)\n' "${drc}" "${label}"
  [ "${drc}" -ne 0 ] && fail
  if [ "${waitexit}" = "yes" ]; then
    for i in $(seq 1 60); do kill -0 "${QPID}" 2>/dev/null || break; sleep 1; done
  fi
  cleanup
  sanitize < "${craw}" > "${LOG_DIR}/$(basename "${craw%.raw.log}").log" 2>/dev/null
  sanitize < "${sraw}" > "${LOG_DIR}/$(basename "${sraw%.raw.log}").log"
  chmod 600 "${craw}" "${sraw}" 2>/dev/null
  chmod 644 "${LOG_DIR}/$(basename "${craw%.raw.log}").log" "${LOG_DIR}/$(basename "${sraw%.raw.log}").log" 2>/dev/null
}

step_runs() {
  section "3. Guest runs (all with -snapshot)"
  qemu_run U1 no --mode uboot --control "${CTRL_UB}" --probe "${PROBE_OPTEE}"
  qemu_run U2 no --mode uboot --control "${CTRL_UB}" --probe "${PROBE_OSBI}"
  qemu_run L yes --mode linux --control "${CTRL_LX}" --probe "${PROBE_OPTEE}" --probe "${PROBE_OSBI}"
  SD_AFTER="$(sha256sum "${IMG_DIR}/sdcard.img" | cut -d' ' -f1)"
  if [ "${SD_AFTER}" = "${SD_BEFORE}" ]; then
    echo "[OK]   sdcard.img unchanged (${SD_AFTER:0:16})"
  else
    echo "[NG]   sdcard.img changed: ${SD_BEFORE:0:16} -> ${SD_AFTER:0:16}"; fail
  fi
}

step_bm() {
  section "4. Bare-metal SBI test application (start-qemu-bm.sh)"
  local i missing=0 l
  # documented expected end of the output (RISE RP016 build instructions)
  local expect=("Welcome to OpenSBI bare-metal app!" "SBI Spec Version: 3.0" "SBI Implementation: OpenSBI"
                "OpenSBI Version: 1.6" "Init timer successfully 10000000 ticks/s")
  open_stdin_fifo || { echo "[NG]   cannot create stdin FIFO"; fail; return 1; }
  timeout "${BM_TIMEOUT}" "${IMG_DIR}/start-qemu-bm.sh" <&"${QIN}" > "${BM_RAW}" 2>&1 &
  QPID=$!                      # the timeout process: TERM is forwarded to the whole run
  for i in $(seq 1 "${BM_TIMEOUT}"); do
    grep -qF "${expect[4]}" "${BM_RAW}" 2>/dev/null && { sleep 1; break; }
    kill -0 "${QPID}" 2>/dev/null || break
    sleep 1
  done
  echo "\$ timeout ${BM_TIMEOUT} output/images/start-qemu-bm.sh   (stopped after the documented last line or the timeout)"
  cleanup
  for l in "${expect[@]}"; do
    if grep -qF "${l}" "${BM_RAW}"; then echo "[OK]   found: ${l}"; else echo "[NG]   missing: ${l}"; missing=1; fi
  done
  if [ "${missing}" -eq 0 ]; then
    echo "[OK]   output matches the expected end documented in the RP016 build instructions"
    echo "[INFO] the application does not power off QEMU; it is stopped by this script"
  else
    fail
  fi
  sanitize < "${BM_RAW}" > "${LOG_DIR}/$(basename "${BM_RAW%.raw.log}").log"; chmod 600 "${BM_RAW}"
  echo "-- output (first 60 lines) --"; head -n 60 "${BM_RAW}" | tr -d '\r'
}

verdict() {
  section "5. Verdict"
  r() { grep -E "^RESULT $1 $2 " "${TMPD}/results.txt" 2>/dev/null | tail -n1 | awk '{print $4}'; }
  UC="$(r uboot_control "${CTRL_UB}")"; UO="$(r uboot_probe "${PROBE_OPTEE}")"; US="$(r uboot_probe "${PROBE_OSBI}")"
  LC="$(r linux_control "${CTRL_LX}")"; LO="$(r linux_probe "${PROBE_OPTEE}")"; LS="$(r linux_probe "${PROBE_OSBI}")"
  printf 'U-Boot (S-mode, untrusted domain): control %-14s OP-TEE %-14s OpenSBI %s\n' "${UC:-n/a}" "${UO:-n/a}" "${US:-n/a}"
  printf 'Linux user space via devmem      : control %-14s OP-TEE %-14s OpenSBI %s\n' "${LC:-n/a}" "${LO:-n/a}" "${LS:-n/a}"
  if [ "${UC}" = READ_OK ] && [ "${UO}" = DENIED_FAULT ] && [ "${US}" = DENIED_FAULT ]; then
    ISO="ISOLATION DEMONSTRATED: from the untrusted domain (S-mode) the OP-TEE and OpenSBI regions fault, while the control address is readable"
  elif [ "${UO}" = READ_OK ] || [ "${US}" = READ_OK ] || [ "${LO}" = READ_OK ] || [ "${LS}" = READ_OK ]; then
    ISO="ISOLATION NOT ENFORCED for at least one protected region - review the transcripts"; fail
  else
    ISO="INCONCLUSIVE - see the RESULT lines and transcripts"; fail
  fi
  echo "${ISO}"
}

# ---- main ------------------------------------------------------------------------
{
  trap 'cleanup; rm -rf "${TMPD}"' EXIT
  trap 'cleanup; exit 130' INT TERM
  section "0. Meta"
  echo "Gate        : 05a (isolation demonstration + bare-metal app; M1 images, -snapshot)"
  echo "Mode        : ${MODE}"
  echo "Timestamp   : ${TS}"
  echo "Script      : scripts/$(basename "${SCRIPT_PATH}")  sha256=$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"
  ISO=""
  if ! cd "${BR_DIR}" 2>/dev/null; then
    echo "[NG]   work/buildroot not found"; fail
  elif step_precheck && step_launcher; then
    if [ "${MODE}" = "full" ]; then
      step_runs; step_bm; verdict
    else
      echo; echo "[INFO] --prepare-only: QEMU was not started"
    fi
  fi
  section "9. Summary"
  echo "Mode            : ${MODE}"
  echo "Failed checks   : ${FAILS}"
  if [ "${MODE}" = "prepare-only" ] && [ "${FAILS}" -eq 0 ]; then
    echo "Verdict         : READY - run without --prepare-only"
  elif [ -n "${ISO}" ]; then
    echo "Verdict         : ${ISO}"
  else
    echo "Verdict         : ${FAILS} CHECK(S) FAILED - search this log for '[NG]'"
  fi
  echo "Next            : upload logs/gate05/$(basename "${LOG_FILE}") and its .sha256 manifest"
  [ "${FAILS}" -eq 0 ]
} 2>&1 | tee -i "${RAW_FILE}" | sanitize_stream | tee -i "${LOG_FILE}"
STATUS=$?

chmod 600 "${RAW_FILE}"; chmod 644 "${LOG_FILE}"
( cd "${PROJECT_ROOT}" && find logs/gate05 -maxdepth 2 -type f -name "*${TS}*" ! -name '*.sha256' -print0 | sort -z \
    | xargs -0 sha256sum > "${MANIFEST}" && sha256sum "${SCRIPT_PATH#"${PROJECT_ROOT}"/}" "${DRIVER#"${PROJECT_ROOT}"/}" >> "${MANIFEST}" \
    && chmod 600 "${MANIFEST}" )
echo
echo "Sanitized log   : ${LOG_FILE#"${PROJECT_ROOT}"/}"
echo "sha256 manifest : ${MANIFEST#"${PROJECT_ROOT}"/}"
echo "Exit status     : ${STATUS}"
exit "${STATUS}"
