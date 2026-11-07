#!/usr/bin/env bash
# =============================================================================
#  Gate 05c : boot + optee_examples + full xtest on a newer stack (v9 / m8)
#  Project  : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  Usage
#    bash scripts/gate05c_xtest.sh <v9|m8> --prepare-only   safety checks + launcher only
#    bash scripts/gate05c_xtest.sh <v9|m8>                  boot, optee_examples, xtest
#
#  Derived from scripts/gate03_boot_xtest.sh (the M1 run) so that the newer
#  stacks are exercised in exactly the same way. The console driver is the
#  UNCHANGED scripts/gate03_console.py (same checks, same xtest invocation).
#  Differences to G03:
#    - tree work/buildroot-<target>, logs in logs/gate05/gate05c_<target>_*;
#    - QEMU runs with -snapshot (passed as "start-qemu.sh -- -snapshot";
#      verified in the QEMU command line); sdcard.img hash compared;
#    - m8 only: the official RP022 M8 instructions add vector extensions to the
#      CPU in start-qemu.sh (the kernel needs them). This is applied to the
#      local loopback copy, not to the generated script;
#    - evidence for the comparison with M1: OpenSBI domain regions, the core
#      PMP regions reported by OP-TEE (m8), xtest totals, regression_1039 /
#      regression_1049 and the list of failed cases;
#    - audit follow-ups: umask 077, FIFO in a private temp dir, raw logs 600.
#  Safety as in G03: no root, Buildroot QEMU only, upstream start-qemu.sh not
#  modified, ports bound to 127.0.0.1 only, QEMU always stopped on exit/Ctrl-C.
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
  v9|m8) ;;
  *) echo "usage: bash scripts/gate05c_xtest.sh <v9|m8> [--prepare-only]" >&2; exit 2 ;;
esac
CPU_OLD='-cpu rv64,zkr=on '
CPU_NEW='-cpu rv64,zkr=on,v=true,vlen=128,zvkned=on,zvkb=on '   # official RP022 M8 instructions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "${SCRIPT_DIR}")" != "scripts" ]; then
  echo "ERROR: place this script in <project-root>/scripts/ and run it from there." >&2
  exit 1
fi
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
BR_DIR="${PROJECT_ROOT}/work/buildroot-${TARGET}"
IMG_DIR="${BR_DIR}/output/images"
HOST_BIN="${BR_DIR}/output/host/bin"
HOST_QEMU="${HOST_BIN}/qemu-system-riscv64"
LAUNCHER="${IMG_DIR}/start-qemu.loopback.sh"      # local copy, never published
CONSOLE_PY="${SCRIPT_DIR}/gate03_console.py"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

LOG_DIR="${PROJECT_ROOT}/logs/gate05"
RAW_DIR="${LOG_DIR}/raw"
TS="$(date +%Y%m%d-%H%M%S)"
NAME="gate05c_${TARGET}_xtest"
LOG_FILE="${LOG_DIR}/${NAME}_${TS}.log"
RAW_FILE="${RAW_DIR}/${NAME}_${TS}.raw.log"
CONSOLE_RAW="${RAW_DIR}/gate05c_${TARGET}_console_${TS}.raw.log"
CONSOLE_LOG="${LOG_DIR}/gate05c_${TARGET}_console_${TS}.log"
STDIO_RAW="${RAW_DIR}/gate05c_${TARGET}_qemu_stdio_${TS}.raw.log"
STDIO_LOG="${LOG_DIR}/gate05c_${TARGET}_qemu_stdio_${TS}.log"
MANIFEST="${RAW_DIR}/${NAME}_${TS}.sha256"

BOOT_TIMEOUT="${G03_BOOT_TIMEOUT:-900}"       # s, until the login prompt
CMD_TIMEOUT="${G03_CMD_TIMEOUT:-300}"         # s, per ordinary command
XTEST_TIMEOUT="${G03_XTEST_TIMEOUT:-10800}"   # s, whole xtest run
PORTS="64320 64321 2200"

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
sanitize() { sed "${SED_ARGS[@]}"; }                              # files
# live log stream: line-buffered (progress appears immediately) and immune to
# Ctrl-C, so the lines written by the cleanup trap still reach both logs
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
listening() { ss -ltnH 2>/dev/null | awk '{print $4}'; }          # local address:port

# ---- QEMU lifetime: always stopped on exit / Ctrl-C / error -------------------
QPID=""; QIN=""; FIFO=""
cleanup() {
  trap '' PIPE
  if [ -n "${QPID}" ] && kill -0 "${QPID}" 2>/dev/null; then
    kill -TERM "${QPID}" 2>/dev/null; sleep 3
    kill -0 "${QPID}" 2>/dev/null && kill -KILL "${QPID}" 2>/dev/null
    echo "[CLEANUP] QEMU (pid ${QPID}) was still running and has been stopped" 2>/dev/null || true
  fi
  QPID=""
  if [ -n "${QIN}" ]; then exec {QIN}>&- 2>/dev/null; QIN=""; fi
  if [ -n "${FIFO}" ]; then rm -f "${FIFO}"; FIFO=""; fi
}
open_stdin_fifo() {   # stdin for QEMU that stays open but never delivers input
  FIFO="${TMPD}/qemu-stdin"; rm -f "${FIFO}"
  mkfifo -m 600 "${FIFO}" && exec {QIN}<>"${FIFO}"
}

# ---- 1. safety pre-checks -----------------------------------------------------
step_precheck() {
  section "1. Safety pre-checks"
  local f p line pw found
  if [ "$(id -u)" -eq 0 ]; then echo "[NG]   running as root - refused (run QEMU as an unprivileged user)"; fail; return 1; fi
  echo "[OK]   running as an unprivileged user (uid $(id -u))"

  if [ -x "${HOST_QEMU}" ]; then
    echo "[OK]   Buildroot QEMU: $("${HOST_QEMU}" --version | head -n1)"
  else
    echo "[NG]   ${HOST_QEMU} not found"; fail; return 1
  fi
  line="$(grep -E '^[[:space:]]*export PATH=' "${IMG_DIR}/start-qemu.sh" 2>/dev/null | head -n1)"
  if printf '%s' "${line}" | grep -qF "${HOST_BIN}:"; then
    echo "[OK]   start-qemu.sh puts output/host/bin first in PATH"
  else
    echo "[NG]   start-qemu.sh does not put output/host/bin first in PATH: ${line:-<none>}"; fail; return 1
  fi

  for f in u-boot-spl u-boot.itb qemu_rv64_virt_domain.dtb sdcard.img start-qemu.sh tee.bin; do
    if [ -e "${IMG_DIR}/${f}" ]; then echo "[OK]   output/images/${f}"; else echo "[NG]   output/images/${f} missing"; fail; return 1; fi
  done

  if true; then
    if ! command -v ss >/dev/null 2>&1; then
      echo "[NG]   'ss' (iproute2) not found - the port-binding safety check cannot run"; fail; return 1
    fi
    for p in ${PORTS}; do
      if listening | grep -Eq "[:.]${p}$"; then echo "[NG]   port ${p} is already in use"; fail; return 1; fi
    done
    echo "[OK]   ports ${PORTS// / / } are free"
    if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
      echo "[OK]   $(python3 --version)"
    else
      echo "[NG]   python3 >= 3.8 is required for the console driver"; fail; return 1
    fi
    if [ -f "${CONSOLE_PY}" ]; then
      echo "[OK]   scripts/$(basename "${CONSOLE_PY}")  sha256=$(sha256sum "${CONSOLE_PY}" | cut -d' ' -f1)"
    else
      echo "[NG]   scripts/$(basename "${CONSOLE_PY}") missing"; fail; return 1
    fi
  fi

  echo "-- guest root filesystem (output/target) --"
  pw="$(sed -nE 's/^BR2_TARGET_GENERIC_ROOT_PASSWD="(.*)"$/\1/p' "${BR_DIR}/.config")"
  if [ -z "${pw}" ]; then
    echo "[INFO] guest root account has no password (Buildroot default)"
  else
    echo "[INFO] guest root account has a password set in .config"
    if [ "${MODE}" = "full" ]; then echo "[NG]   the console driver cannot log in with a password"; fail; return 1; fi
  fi
  found=""
  for f in usr/sbin/dropbear usr/bin/dropbear usr/sbin/sshd; do
    [ -e "${BR_DIR}/output/target/${f}" ] && found="${found} /${f}"
  done
  if [ -n "${found}" ]; then
    echo "[INFO] SSH server present in the guest:${found} (port 2200 stays restricted to 127.0.0.1)"
  else
    echo "[INFO] no SSH server in the guest (dropbear / sshd not installed); port 2200 leads nowhere"
  fi
  for f in usr/bin/xtest usr/bin/tee-supplicant usr/sbin/tee-supplicant; do
    [ -e "${BR_DIR}/output/target/${f}" ] && echo "[OK]   guest has /${f}"
  done
  echo "guest optee_example_* : $(ls "${BR_DIR}"/output/target/usr/bin/optee_example_* 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
  echo "guest TEE init scripts: $(ls "${BR_DIR}/output/target/etc/init.d" 2>/dev/null | grep -iE 'tee|optee' | tr '\n' ' ')"
  grep -qF -- ' -drive format=raw,file=sdcard.img' "${IMG_DIR}/start-qemu.sh" && echo "[OK]   start-qemu.sh uses sdcard.img (protected with -snapshot)"
  grep -qE 'while \[ "\$1" \]' "${IMG_DIR}/start-qemu.sh" && echo "[OK]   start-qemu.sh parses options: QEMU arguments go after '--'" \
    || { echo "[NG]   start-qemu.sh does not parse options - '-- -snapshot' would be wrong"; fail; return 1; }
  SD_BEFORE="$(sha256sum "${IMG_DIR}/sdcard.img" | cut -d' ' -f1)"
  echo "sdcard.img sha256 before: ${SD_BEFORE}"
  return 0
}

# ---- 2. loopback-only launcher --------------------------------------------------
step_launcher() {
  section "2. Loopback-only launcher (upstream start-qemu.sh is not modified)"
  local n
  n="$(grep -c 'hostfwd=tcp::2200-:22' "${IMG_DIR}/start-qemu.sh")"
  if [ "${n}" -ne 1 ]; then
    echo "[NG]   expected exactly one 'hostfwd=tcp::2200-:22' in start-qemu.sh, found ${n}"; fail; return 1
  fi
  sed 's/hostfwd=tcp::2200-:22/hostfwd=tcp:127.0.0.1:2200-:22/' "${IMG_DIR}/start-qemu.sh" > "${LAUNCHER}"
  if [ "${TARGET}" = "m8" ]; then
    if [ "$(grep -cF -- "${CPU_OLD}" "${LAUNCHER}")" -ne 1 ]; then
      echo "[NG]   m8: expected exactly one '${CPU_OLD}' in start-qemu.sh"; fail; return 1
    fi
    sed -i "s/${CPU_OLD}/${CPU_NEW}/" "${LAUNCHER}"
    echo "[OK]   m8: CPU extended as in the official instructions: ${CPU_NEW}"
  fi
  chmod 700 "${LAUNCHER}"
  if [ "$(diff "${IMG_DIR}/start-qemu.sh" "${LAUNCHER}" | grep -c '^[<>]')" -eq 2 ] \
     && [ "$(grep -c 'hostfwd=tcp:127.0.0.1:2200-:22' "${LAUNCHER}")" -eq 1 ]; then
    echo "[OK]   launcher generated: output/images/$(basename "${LAUNCHER}") (only the QEMU line differs: hostfwd$( [ "${TARGET}" = m8 ] && echo ', -cpu'))"
  else
    echo "[NG]   unexpected difference between start-qemu.sh and the launcher"; fail; return 1
  fi
  echo "-- diff start-qemu.sh -> $(basename "${LAUNCHER}") --"
  diff "${IMG_DIR}/start-qemu.sh" "${LAUNCHER}" | grep '^[<>]' | sed -E 's/^(.).*(hostfwd=[^ ]*).*$/\1 ... \2 .../'
  echo "-- QEMU command line used (from the launcher) --"
  grep -E '^exec ' "${LAUNCHER}" | sed 's/^exec //'
  return 0
}

# ---- 3a. boot + console driver ---------------------------------------------------
step_boot() {
  section "3. Boot, optee_examples, xtest"
  local i addr bad=0 drc qrc seen=0 r
  echo "QEMU stdio (OP-TEE semihosting console) : logs/gate05/raw/$(basename "${STDIO_RAW}")"
  echo "Guest UART (OpenSBI / U-Boot / Linux)   : logs/gate05/raw/$(basename "${CONSOLE_RAW}")"
  echo "Timeouts: boot ${BOOT_TIMEOUT} s, command ${CMD_TIMEOUT} s, xtest ${XTEST_TIMEOUT} s"
  open_stdin_fifo || { echo "[NG]   cannot create the stdin FIFO"; fail; return 1; }
  "${LAUNCHER}" -- -snapshot <&"${QIN}" > "${STDIO_RAW}" 2>&1 &   # options of start-qemu.sh end at "--"
  QPID=$!
  echo "[INFO] QEMU started (pid ${QPID}); waiting for 127.0.0.1:64320"
  for i in $(seq 1 30); do
    if listening | grep -Eq '[:.]64320$'; then seen=1; break; fi
    if ! kill -0 "${QPID}" 2>/dev/null; then
      echo "[NG]   QEMU exited early - last lines of its output:"; tail -n 30 "${STDIO_RAW}"; fail; QPID=""; return 1
    fi
    sleep 1
  done

  if [ "${seen}" -ne 1 ]; then
    echo "[NG]   port 64320 not listening after 30 s - stopping QEMU"; tail -n 30 "${STDIO_RAW}"; fail; cleanup; return 1
  fi
  echo "-- listening sockets of the guest (must be 127.0.0.1 only) --"
  for p in 64320 2200; do
    addr="$(listening | grep -E "[:.]${p}$" | tr '\n' ' ')"
    if [ -z "${addr}" ]; then
      echo "[WARN] nothing listening on port ${p}"
    elif printf '%s\n' ${addr} | grep -qv '^127\.0\.0\.1:'; then
      echo "[NG]   port ${p} is bound to: ${addr}"; bad=1
    else
      echo "[OK]   port ${p} bound to ${addr}"
    fi
  done
  if [ "${bad}" -ne 0 ]; then echo "[NG]   stopping QEMU for safety"; fail; cleanup; return 1; fi
  if tr '\0' ' ' < "/proc/${QPID}/cmdline" 2>/dev/null | grep -q -- ' -snapshot'; then
    echo "[OK]   QEMU pid ${QPID}: -snapshot active"
  else
    echo "[NG]   -snapshot not found in the QEMU command line - stopping"; fail; cleanup; return 1
  fi

  echo; echo "-- console driver --"
  python3 "${CONSOLE_PY}" --port 64320 --transcript "${CONSOLE_RAW}" \
    --boot-timeout "${BOOT_TIMEOUT}" --cmd-timeout "${CMD_TIMEOUT}" --xtest-timeout "${XTEST_TIMEOUT}"
  drc=$?
  printf '$ python3 scripts/%s ...\n[rc=%d]\n' "$(basename "${CONSOLE_PY}")" "${drc}"
  case "${drc}" in
    0) echo "[OK]   console driver: all checks passed" ;;
    1) echo "[NG]   console driver: a check or test failed (see SUMMARY / STEP lines)"; fail ;;
    *) echo "[NG]   console driver: infrastructure problem (see SUMMARY infrastructure_error)"; fail ;;
  esac

  for i in $(seq 1 60); do kill -0 "${QPID}" 2>/dev/null || break; sleep 1; done
  if kill -0 "${QPID}" 2>/dev/null; then
    echo "[WARN] QEMU did not exit within 60 s after poweroff - stopping it"; cleanup
  else
    wait "${QPID}" 2>/dev/null; qrc=$?
    echo "[OK]   QEMU exited by itself (exit status ${qrc})"; QPID=""
  fi
  cleanup

  sanitize < "${CONSOLE_RAW}" > "${CONSOLE_LOG}" 2>/dev/null
  sanitize < "${STDIO_RAW}"   > "${STDIO_LOG}"
  chmod 600 "${CONSOLE_RAW}" "${STDIO_RAW}" 2>/dev/null; chmod 644 "${CONSOLE_LOG}" "${STDIO_LOG}" 2>/dev/null
  SD_AFTER="$(sha256sum "${IMG_DIR}/sdcard.img" | cut -d' ' -f1)"
  if [ "${SD_AFTER}" = "${SD_BEFORE}" ]; then echo "[OK]   sdcard.img unchanged (${SD_AFTER:0:16})"
  else echo "[NG]   sdcard.img changed: ${SD_BEFORE:0:16} -> ${SD_AFTER:0:16}"; fail; fi

  section "4. Boot evidence"
  echo "-- guest UART: boot chain --"
  grep -aE 'U-Boot SPL|OpenSBI v|Platform Name|Firmware Base|Domain[0-9]+ Name|U-Boot 20[0-9]{2}|Linux version|optee: |login:' "${CONSOLE_RAW}" 2>/dev/null \
    | tr -d '\r' | head -n 40
  echo "-- guest UART: OpenSBI domain report --"
  grep -aE '^Domain[0-9]+ ' "${CONSOLE_RAW}" 2>/dev/null | tr -d '\r' | head -n 60
  echo "-- QEMU stdio: OP-TEE semihosting console (key lines) --"
  grep -aE 'OP-TEE version|Primary CPU|Initializing|Switching to normal world|Secondary CPU|QEMU waiting' "${STDIO_RAW}" | tr -d '\r' | head -n 20
  echo "-- QEMU stdio: core PMP regions reported by OP-TEE (RP022 M8) --"
  grep -aE 'Core PMP regions|(text|rodata|data) base = ' "${STDIO_RAW}" | tr -d '\r' | head -n 8 || true
  echo "-- guest UART: OpenSBI and Boot HART --"
  grep -aE 'OpenSBI v[0-9]|Boot HART ID|Runtime SBI Version' "${CONSOLE_RAW}" 2>/dev/null | tr -d '\r' | head -n 6

  section "5. xtest results for the comparison with M1"
  echo "-- totals --"
  grep -aE 'subtests of which|test cases of which|test cases were skipped' "${CONSOLE_RAW}" 2>/dev/null | tr -d '\r' | tail -n 6
  echo "-- regression_1039 (failed in M1: subkey signatures vs. RSA-4096 default key) --"
  r="$(grep -aE 'regression_1039[^.]* (OK|FAILED)' "${CONSOLE_RAW}" 2>/dev/null | tr -d '\r' | tail -n 3)"
  [ -n "${r}" ] && echo "${r}" || echo "(no result line found)"
  echo "-- regression_1049 (RP022 M8: core PMP data permissions) --"
  r="$(grep -aE 'regression_1049[^.]* (OK|FAILED)' "${CONSOLE_RAW}" 2>/dev/null | tr -d '\r' | tail -n 3)"
  [ -n "${r}" ] && echo "${r}" || echo "(not present in this optee_test)"
  echo "-- cases reported as FAILED --"
  grep -aE '^[[:space:]]*[a-z_]+_[0-9]+[^ ]* FAILED' "${CONSOLE_RAW}" 2>/dev/null | tr -d '\r' | sort -u | head -n 40 || true
  printf 'QEMU stdio log : %s lines, %s bytes\n' "$(wc -l < "${STDIO_RAW}")" "$(wc -c < "${STDIO_RAW}")"
  [ -f "${CONSOLE_RAW}" ] && printf 'Console log    : %s lines, %s bytes\n' "$(wc -l < "${CONSOLE_RAW}")" "$(wc -c < "${CONSOLE_RAW}")"
}

# ---- main --------------------------------------------------------------------------
{
  trap 'cleanup; rm -rf "${TMPD}"' EXIT
  trap 'cleanup; exit 130' INT TERM

  section "0. Meta"
  echo "Gate        : 05c (${TARGET}: boot, optee_examples, full xtest - same driver as G03)"
  echo "Mode        : ${MODE}"
  echo "Timestamp   : ${TS}"
  echo "ProjectRoot : ${PROJECT_ROOT}"
  echo "Script      : scripts/$(basename "${SCRIPT_PATH}")  sha256=$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"
  echo "Raw log     : logs/gate05/raw/$(basename "${RAW_FILE}")  (local only, not published)"

  if ! cd "${BR_DIR}" 2>/dev/null; then
    echo "[NG]   work/buildroot-${TARGET} not found - run gate05b_build.sh ${TARGET} first"; fail
  elif step_precheck; then
    case "${MODE}" in
      prepare-only) step_launcher && { echo; echo "[INFO] --prepare-only: QEMU was not started"; } ;;
      full)         step_launcher && step_boot ;;
    esac
  fi

  section "9. Summary"
  echo "Mode            : ${MODE}"
  echo "Failed checks   : ${FAILS}"
  if [ "${FAILS}" -ne 0 ]; then
    echo "Verdict         : ${FAILS} CHECK(S) FAILED - search this log for '[NG]' / 'rc=' / 'SUMMARY'"
  else
    case "${MODE}" in
      prepare-only) echo "Verdict         : READY - safety checks passed and launcher generated; run without --prepare-only to boot" ;;
      full)         echo "Verdict         : BOOT, OPTEE_EXAMPLES AND XTEST PASSED" ;;
    esac
  fi
  echo "Next            : upload logs/gate05/$(basename "${LOG_FILE}") and its .sha256 manifest"
  [ "${FAILS}" -eq 0 ]
} 2>&1 | tee -i "${RAW_FILE}" | sanitize_stream | tee -i "${LOG_FILE}"
STATUS=$?

MFILES=("${RAW_FILE}" "${LOG_FILE}")
chmod 600 "${RAW_FILE}"; chmod 644 "${LOG_FILE}"
for f in "${CONSOLE_RAW}" "${CONSOLE_LOG}" "${STDIO_RAW}" "${STDIO_LOG}"; do
  [ -f "${f}" ] && MFILES+=("${f}")
done
MFILES+=("${SCRIPT_PATH}")
[ -f "${CONSOLE_PY}" ] && MFILES+=("${CONSOLE_PY}")
( cd "${PROJECT_ROOT}" && sha256sum "${MFILES[@]#"${PROJECT_ROOT}"/}" > "${MANIFEST}" && chmod 600 "${MANIFEST}" )

echo
echo "Sanitized log      : ${LOG_FILE#"${PROJECT_ROOT}"/}"
echo "sha256 manifest    : ${MANIFEST#"${PROJECT_ROOT}"/}"
echo "Exit status        : ${STATUS}"
exit "${STATUS}"
