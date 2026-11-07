#!/usr/bin/env bash
# =============================================================================
#  Gate 03 : boot the RISC-V OP-TEE guest on QEMU and run xtest
#  Project : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  Modes
#    bash scripts/gate03_boot_xtest.sh --prepare-only   safety checks + launcher only
#    bash scripts/gate03_boot_xtest.sh                  boot, optee_examples, xtest
#    bash scripts/gate03_boot_xtest.sh --bm-app         optional: bare-metal SBI test app
#
#  Safety measures
#    - refuses to run as root;
#    - requires the Buildroot-built QEMU and checks that start-qemu.sh puts
#      output/host/bin first in PATH (no silent fallback to the system QEMU);
#    - the upstream start-qemu.sh is NOT modified: a local copy is generated in
#      which only  hostfwd=tcp::2200-:22  becomes  hostfwd=tcp:127.0.0.1:2200-:22 ;
#    - while QEMU runs, ports 64320 / 2200 must be bound to 127.0.0.1 only,
#      otherwise QEMU is stopped immediately;
#    - QEMU is always stopped on exit, Ctrl-C or error (trap);
#    - semihosting stays enabled (the OP-TEE console needs it); QEMU runs as the
#      current unprivileged user with output/images as its working directory.
#
#  Consoles
#    QEMU stdout/stderr = OP-TEE semihosting console -> gate03_qemu_stdio_*.log
#    TCP 127.0.0.1:64320 = OpenSBI / U-Boot / Linux   -> gate03_console_*.log
#                          (driven by scripts/gate03_console.py)
#
#  Logging: [rc=N] per command, pipefail, sanitized logs in logs/gate03/,
#  raw logs + sha256 manifest in logs/gate03/raw/ (local only). The live log
#  pipeline is line-buffered and ignores Ctrl-C, so nothing is lost on abort.
# =============================================================================
set -uo pipefail

MODE="full"
case "${1:-}" in
  "")             ;;
  --prepare-only) MODE="prepare-only" ;;
  --bm-app)       MODE="bm-app" ;;
  *) echo "usage: bash scripts/gate03_boot_xtest.sh [--prepare-only | --bm-app]" >&2; exit 2 ;;
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
LAUNCHER="${IMG_DIR}/start-qemu.loopback.sh"      # local copy, never published
CONSOLE_PY="${SCRIPT_DIR}/gate03_console.py"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

LOG_DIR="${PROJECT_ROOT}/logs/gate03"
RAW_DIR="${LOG_DIR}/raw"
TS="$(date +%Y%m%d-%H%M%S)"
if [ "${MODE}" = "bm-app" ]; then NAME="gate03_bm_app"; else NAME="gate03_boot_xtest"; fi
LOG_FILE="${LOG_DIR}/${NAME}_${TS}.log"
RAW_FILE="${RAW_DIR}/${NAME}_${TS}.raw.log"
CONSOLE_RAW="${RAW_DIR}/gate03_console_${TS}.raw.log"
CONSOLE_LOG="${LOG_DIR}/gate03_console_${TS}.log"
STDIO_RAW="${RAW_DIR}/gate03_qemu_stdio_${TS}.raw.log"
STDIO_LOG="${LOG_DIR}/gate03_qemu_stdio_${TS}.log"
BM_RAW="${RAW_DIR}/gate03_bm_app_output_${TS}.raw.log"
BM_LOG="${LOG_DIR}/gate03_bm_app_output_${TS}.log"
MANIFEST="${RAW_DIR}/${NAME}_${TS}.sha256"

BOOT_TIMEOUT="${G03_BOOT_TIMEOUT:-900}"       # s, until the login prompt
CMD_TIMEOUT="${G03_CMD_TIMEOUT:-300}"         # s, per ordinary command
XTEST_TIMEOUT="${G03_XTEST_TIMEOUT:-10800}"   # s, whole xtest run
BM_TIMEOUT="${G03_BM_TIMEOUT:-180}"           # s, bare-metal app run
PORTS="64320 64321 2200"

mkdir -p "${LOG_DIR}" "${RAW_DIR}"

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
  FIFO="$(mktemp -u "${RAW_DIR}/.qemu-stdin.XXXXXX")"
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

  for f in u-boot-spl u-boot.itb qemu_rv64_virt_domain.dtb sdcard.img start-qemu.sh start-qemu-bm.sh fw_jump.bin bm-app.elf; do
    if [ -e "${IMG_DIR}/${f}" ]; then echo "[OK]   output/images/${f}"; else echo "[NG]   output/images/${f} missing"; fail; return 1; fi
  done

  if [ "${MODE}" != "bm-app" ]; then
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
  chmod 700 "${LAUNCHER}"
  if [ "$(diff "${IMG_DIR}/start-qemu.sh" "${LAUNCHER}" | grep -c '^[<>]')" -eq 2 ] \
     && [ "$(grep -c 'hostfwd=tcp:127.0.0.1:2200-:22' "${LAUNCHER}")" -eq 1 ]; then
    echo "[OK]   launcher generated: output/images/$(basename "${LAUNCHER}") (only the hostfwd address differs)"
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
  local i addr bad=0 drc qrc seen=0
  echo "QEMU stdio (OP-TEE semihosting console) : logs/gate03/raw/$(basename "${STDIO_RAW}")"
  echo "Guest UART (OpenSBI / U-Boot / Linux)   : logs/gate03/raw/$(basename "${CONSOLE_RAW}")"
  echo "Timeouts: boot ${BOOT_TIMEOUT} s, command ${CMD_TIMEOUT} s, xtest ${XTEST_TIMEOUT} s"
  open_stdin_fifo || { echo "[NG]   cannot create the stdin FIFO"; fail; return 1; }
  "${LAUNCHER}" <&"${QIN}" > "${STDIO_RAW}" 2>&1 &
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

  section "4. Boot evidence"
  echo "-- guest UART: boot chain --"
  grep -aE 'U-Boot SPL|OpenSBI v|Platform Name|Firmware Base|Domain[0-9]+ Name|U-Boot 20[0-9]{2}|Linux version|optee: |login:' "${CONSOLE_RAW}" 2>/dev/null \
    | tr -d '\r' | head -n 40
  echo "-- guest UART: OpenSBI domain report (input for G04) --"
  grep -aE '^Domain[0-9]+ ' "${CONSOLE_RAW}" 2>/dev/null | tr -d '\r' | head -n 60
  echo "-- QEMU stdio: OP-TEE semihosting console (key lines) --"
  grep -aE 'OP-TEE version|Primary CPU|Initializing|Switching to normal world|Secondary CPU|QEMU waiting' "${STDIO_RAW}" | tr -d '\r' | head -n 20
  printf 'QEMU stdio log : %s lines, %s bytes\n' "$(wc -l < "${STDIO_RAW}")" "$(wc -c < "${STDIO_RAW}")"
  [ -f "${CONSOLE_RAW}" ] && printf 'Console log    : %s lines, %s bytes\n' "$(wc -l < "${CONSOLE_RAW}")" "$(wc -c < "${CONSOLE_RAW}")"
}

# ---- 3b. optional: bare-metal SBI test application -------------------------------
step_bm() {
  section "3. Bare-metal SBI test application (start-qemu-bm.sh)"
  local rc
  echo "Output : logs/gate03/raw/$(basename "${BM_RAW}")   timeout ${BM_TIMEOUT} s"
  open_stdin_fifo || { echo "[NG]   cannot create the stdin FIFO"; fail; return 1; }
  timeout "${BM_TIMEOUT}" "${IMG_DIR}/start-qemu-bm.sh" <&"${QIN}" > "${BM_RAW}" 2>&1
  rc=$?
  cleanup
  printf '$ timeout %s output/images/start-qemu-bm.sh\n[rc=%d]\n' "${BM_TIMEOUT}" "${rc}"
  case "${rc}" in
    0)   echo "[OK]   QEMU exited by itself" ;;
    124) echo "[WARN] stopped by the ${BM_TIMEOUT} s timeout (the application may not power off QEMU)" ;;
    *)   echo "[NG]   QEMU exited with status ${rc}"; fail ;;
  esac
  sanitize < "${BM_RAW}" > "${BM_LOG}"
  echo "-- first 40 lines --"; head -n 40 "${BM_RAW}" | tr -d '\r'
  echo "-- last 60 lines --";  tail -n 60 "${BM_RAW}" | tr -d '\r'
}

# ---- main --------------------------------------------------------------------------
{
  trap cleanup EXIT
  trap 'cleanup; exit 130' INT TERM

  section "0. Meta"
  echo "Gate        : 03 (boot on QEMU, optee_examples, xtest)"
  echo "Mode        : ${MODE}"
  echo "Timestamp   : ${TS}"
  echo "ProjectRoot : ${PROJECT_ROOT}"
  echo "Script      : scripts/$(basename "${SCRIPT_PATH}")  sha256=$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"
  echo "Raw log     : logs/gate03/raw/$(basename "${RAW_FILE}")  (local only, not published)"

  if ! cd "${BR_DIR}" 2>/dev/null; then
    echo "[NG]   work/buildroot not found - run G01 / G02 first"; fail
  elif step_precheck; then
    case "${MODE}" in
      prepare-only) step_launcher && { echo; echo "[INFO] --prepare-only: QEMU was not started"; } ;;
      full)         step_launcher && step_boot ;;
      bm-app)       step_bm ;;
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
      bm-app)       echo "Verdict         : BARE-METAL APP RUN RECORDED" ;;
    esac
  fi
  echo "Next            : upload logs/gate03/$(basename "${LOG_FILE}") and its .sha256 manifest"
  [ "${FAILS}" -eq 0 ]
} 2>&1 | tee -i "${RAW_FILE}" | sanitize_stream | tee -i "${LOG_FILE}"
STATUS=$?

MFILES=("${RAW_FILE}" "${LOG_FILE}")
for f in "${CONSOLE_RAW}" "${CONSOLE_LOG}" "${STDIO_RAW}" "${STDIO_LOG}" "${BM_RAW}" "${BM_LOG}"; do
  [ -f "${f}" ] && MFILES+=("${f}")
done
MFILES+=("${SCRIPT_PATH}")
[ -f "${CONSOLE_PY}" ] && MFILES+=("${CONSOLE_PY}")
( cd "${PROJECT_ROOT}" && sha256sum "${MFILES[@]#"${PROJECT_ROOT}"/}" > "${MANIFEST}" )

echo
echo "Sanitized log      : ${LOG_FILE#"${PROJECT_ROOT}"/}"
echo "sha256 manifest    : ${MANIFEST#"${PROJECT_ROOT}"/}"
echo "Exit status        : ${STATUS}"
exit "${STATUS}"
