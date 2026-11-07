#!/usr/bin/env bash
# =============================================================================
#  Gate 05b-2 : interrupt tests of RP016 M2 (APLIC) and M3 (VIRQ)
#  Project    : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  Usage
#    bash scripts/gate05b_test.sh <m2|m3> --prepare-only   checks + launcher only
#    bash scripts/gate05b_test.sh <m2|m3>                  run the test
#
#  What is tested (official milestone instructions)
#    m2  start-qemu-kernel.sh    : a key on the OpenSBI console is handled in
#        M-mode ("[APLIC TEST] UART got 'a'(0x61)"); Linux registers the
#        APLIC, APLIC-DIRECT lines keep counting, IRQ affinity follows
#        smp_affinity_list.
#    m3  start-qemu-bm-kernel.sh : a key is routed as VIRQ to domain2 - hart2
#        switches domain1 -> domain2, bm-app2 handles it, then switches back;
#        Linux interrupt handling is not affected.
#
#  Facts about the generated scripts (read from the G05b-1 build log)
#    - no option parsing: QEMU arguments are passed directly ("$@"), so
#      -snapshot is given WITHOUT "--" (unlike start-qemu.sh of M1);
#    - QEMU is not exec'ed (m3 even runs QEMU twice: dumpdtb, then the real
#      run), so the whole process group is managed and always stopped;
#    - hostfwd=tcp::2200-:22 (all interfaces) appears once or more: a local
#      copy binds it to 127.0.0.1; the upstream script is not modified.
#  Safety as in G03/G05a: no root, Buildroot QEMU only (checked in the script),
#  ports on 127.0.0.1 only, -snapshot verified in every QEMU command line,
#  sdcard.img hash compared, QEMU group stopped on exit / Ctrl-C.
#  Logging: umask 077, [rc=N], pipefail, sanitized logs in logs/gate05/, raw
#  logs + sha256 manifest in logs/gate05/raw/.
# =============================================================================
set -uo pipefail
umask 077

TARGET="${1:-}"
MODE="full"
case "${2:-}" in
  "") ;;
  --prepare-only) MODE="prepare-only" ;;
  *) TARGET="" ;;
esac
case "${TARGET}" in
  m2) SRC_NAME="start-qemu-kernel.sh" ;;
  m3) SRC_NAME="start-qemu-bm-kernel.sh" ;;
  *)  echo "usage: bash scripts/gate05b_test.sh <m2|m3> [--prepare-only]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "${SCRIPT_DIR}")" != "scripts" ]; then
  echo "ERROR: place this script in <project-root>/scripts/ and run it from there." >&2
  exit 1
fi
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
TREE="${PROJECT_ROOT}/work/buildroot-${TARGET}"
IMG_DIR="${TREE}/output/images"
HOST_BIN="${TREE}/output/host/bin"
SRC="${IMG_DIR}/${SRC_NAME}"
LAUNCHER="${IMG_DIR}/${SRC_NAME%.sh}.loopback.sh"
DRIVER="${SCRIPT_DIR}/gate05b_console.py"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

LOG_DIR="${PROJECT_ROOT}/logs/gate05"
RAW_DIR="${LOG_DIR}/raw"
TS="$(date +%Y%m%d-%H%M%S)"
NAME="gate05b_${TARGET}_test"
LOG_FILE="${LOG_DIR}/${NAME}_${TS}.log"
RAW_FILE="${RAW_DIR}/${NAME}_${TS}.raw.log"
STDIO_RAW="${RAW_DIR}/${NAME}_opensbi_console_${TS}.raw.log"
LINUX_RAW="${RAW_DIR}/${NAME}_linux_console_${TS}.raw.log"
MANIFEST="${RAW_DIR}/${NAME}_${TS}.sha256"
PORTS="64321 64322 2200"

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
  -e 's#0\.0\.0\.0#__ANYADDR__#g'
  -e 's#([0-9]{1,3}\.){3}[0-9]{1,3}#<IPv4>#g'
  -e 's#__LOOPBACK__#127.0.0.1#g'
  -e 's#__ANYADDR__#0.0.0.0#g'
  -e 's#([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}#<MAC>#g'
  -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}#<EMAIL>#g'
)
sanitize() { sed "${SED_ARGS[@]}"; }
sanitize_stream() { ( trap '' INT; exec sed -u "${SED_ARGS[@]}" ); }

# ---- helpers ----------------------------------------------------------------
section() { printf '\n===== %s =====\n' "$1"; }
FAILS=0
fail() { FAILS=$((FAILS + 1)); }
listening() { ss -ltnH 2>/dev/null | awk '{print $4}'; }
check() {   # check <name> <0|1> <detail>  -> RESULT line + failure count
  if [ "$2" -eq 0 ]; then printf 'RESULT %s PASS | %s\n' "$1" "$3"; else printf 'RESULT %s FAIL | %s\n' "$1" "$3"; fail; fi
}

PGID=""; QIN=""; FIFO=""; DPID=""
cleanup() {
  trap '' PIPE
  if [ -n "${DPID}" ] && kill -0 "${DPID}" 2>/dev/null; then kill -TERM "${DPID}" 2>/dev/null; fi
  if [ -n "${PGID}" ] && kill -0 -- "-${PGID}" 2>/dev/null; then
    kill -TERM -- "-${PGID}" 2>/dev/null; sleep 3
    kill -0 -- "-${PGID}" 2>/dev/null && kill -KILL -- "-${PGID}" 2>/dev/null
    echo "[CLEANUP] QEMU process group ${PGID} stopped" 2>/dev/null || true
  fi
  PGID=""; DPID=""
  if [ -n "${QIN}" ]; then exec {QIN}>&- 2>/dev/null; QIN=""; fi
  if [ -n "${FIFO}" ]; then rm -f "${FIFO}"; FIFO=""; fi
}

# ---- 1. pre-checks -----------------------------------------------------------
step_precheck() {
  section "1. Safety pre-checks"
  local t p n
  if [ "$(id -u)" -eq 0 ]; then echo "[NG]   running as root - refused"; fail; return 1; fi
  echo "[OK]   unprivileged user (uid $(id -u))"
  for t in ss python3 setsid sha256sum; do command -v "${t}" >/dev/null 2>&1 || { echo "[NG]   '${t}' not found"; fail; return 1; }; done
  [ -f "${SRC}" ] || { echo "[NG]   ${SRC_NAME} not found - run gate05b_build.sh ${TARGET} first"; fail; return 1; }
  [ -x "${HOST_BIN}/qemu-system-riscv64" ] && echo "[OK]   Buildroot QEMU: $("${HOST_BIN}/qemu-system-riscv64" --version | head -n1)" \
                                           || { echo "[NG]   Buildroot QEMU missing"; fail; return 1; }
  [ -f "${DRIVER}" ] && echo "[OK]   scripts/$(basename "${DRIVER}")  sha256=$(sha256sum "${DRIVER}" | cut -d' ' -f1)" \
                     || { echo "[NG]   console driver missing"; fail; return 1; }
  for p in ${PORTS}; do
    if listening | grep -Eq "[:.]${p}$"; then echo "[NG]   port ${p} already in use"; fail; return 1; fi
  done
  echo "[OK]   ports ${PORTS// / / } are free"

  echo "-- shape of ${SRC_NAME} (must match what the test relies on) --"
  grep -qF "export PATH=\"${HOST_BIN}:" "${SRC}" && echo "[OK]   puts the Buildroot host/bin first in PATH" \
                                              || { echo "[NG]   PATH line unexpected"; fail; return 1; }
  grep -qE 'while \[ "\$1" \]|case "\$1"' "${SRC}" && { echo "[NG]   script parses options - test assumes it does not"; fail; return 1; }
  echo "[OK]   no option parsing (QEMU arguments are passed directly)"
  grep -qF 'port=64321,server=on,wait=on' "${SRC}" && echo "[OK]   Linux console: virtio console on TCP 64321 (waits for a client)" \
                                                  || { echo "[NG]   no waiting chardev on port 64321"; fail; return 1; }
  grep -qF 'aia=aplic' "${SRC}" && echo "[OK]   QEMU machine with APLIC (-M virt,aia=aplic)" || { echo "[NG]   aia=aplic missing"; fail; return 1; }
  grep -qF 'file=sdcard.img' "${SRC}" && echo "[OK]   uses sdcard.img (protected with -snapshot)" || echo "[INFO] no sdcard.img in the script"
  n="$(grep -c 'hostfwd=tcp::2200-:22' "${SRC}")"
  [ "${n}" -ge 1 ] && echo "[OK]   hostfwd on all interfaces found ${n} time(s) - will be restricted" \
                   || { echo "[NG]   expected hostfwd pattern not found"; fail; return 1; }
  if [ "${TARGET}" = "m3" ]; then
    grep -qF 'dumpdtb=' "${SRC}" && grep -qF 'fdtoverlay' "${SRC}" && echo "[OK]   m3: dumpdtb + overlay + second QEMU run" \
      || { echo "[NG]   m3: dumpdtb/overlay sequence not found"; fail; return 1; }
  fi
  SD_BEFORE="$(sha256sum "${IMG_DIR}/sdcard.img" 2>/dev/null | cut -d' ' -f1)"
  echo "sdcard.img sha256 before: ${SD_BEFORE}"
}

# ---- 2. loopback-only launcher -------------------------------------------------
step_launcher() {
  section "2. Loopback-only launcher (upstream ${SRC_NAME} is not modified)"
  local n
  n="$(grep -c 'hostfwd=tcp::2200-:22' "${SRC}")"
  sed 's/hostfwd=tcp::2200-:22/hostfwd=tcp:127.0.0.1:2200-:22/g' "${SRC}" > "${LAUNCHER}"; chmod 700 "${LAUNCHER}"
  if [ "$(diff "${SRC}" "${LAUNCHER}" | grep -c '^[<>]')" -eq $((2 * n)) ] && ! grep -qF 'hostfwd=tcp::' "${LAUNCHER}"; then
    echo "[OK]   $(basename "${LAUNCHER}") generated: only ${n} hostfwd address(es) differ"
  else
    echo "[NG]   unexpected launcher difference"; fail; return 1
  fi
}

# ---- 3. run -------------------------------------------------------------------
inject() { printf '%s' "$1" >&"${QIN}"; }
wait_for() {   # wait_for <fixed string> <seconds> [<minimum count>]
  local i
  for i in $(seq 1 "$2"); do
    [ "$(grep -cF -- "$1" "${STDIO_RAW}" 2>/dev/null)" -ge "${3:-1}" ] && return 0
    kill -0 -- "-${PGID}" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

step_run() {
  section "3. Run (QEMU with -snapshot, process group managed)"
  local i a qp q bad=0 drc
  FIFO="${TMPD}/stdin"; mkfifo -m 600 "${FIFO}" && exec {QIN}<>"${FIFO}"
  setsid bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "${TMPD}/pgid" "${LAUNCHER}" -snapshot <&"${QIN}" > "${STDIO_RAW}" 2>&1 &
  for i in $(seq 1 10); do [ -s "${TMPD}/pgid" ] && break; sleep 0.5; done
  PGID="$(cat "${TMPD}/pgid" 2>/dev/null)"
  [ -n "${PGID}" ] || { echo "[NG]   could not start the launcher"; fail; return 1; }
  echo "[INFO] launcher started, process group ${PGID}"
  if ! wait_for "QEMU waiting for connection on: disconnected:tcp:127.0.0.1:64321" 120; then
    echo "[NG]   QEMU did not wait for the Linux console"; tail -n 30 "${STDIO_RAW}"; fail; cleanup; return 1
  fi
  for i in $(seq 1 10); do listening | grep -Eq '[:.]64321$' && break; sleep 0.5; done
  for p in ${PORTS}; do
    a="$(listening | grep -E "[:.]${p}$" | tr '\n' ' ')"
    if [ -n "${a}" ] && printf '%s\n' ${a} | grep -qv '^127\.0\.0\.1:'; then echo "[NG]   port ${p} bound to ${a}"; bad=1
    else echo "[OK]   port ${p}: ${a:-not listening}"; fi
  done
  [ "${bad}" -eq 0 ] || { echo "[NG]   stopping QEMU for safety"; fail; cleanup; return 1; }
  i=0
  for qp in $(pgrep -g "${PGID}" -f qemu-system-riscv64); do
    i=$((i + 1))
    q="$(tr '\0' ' ' < "/proc/${qp}/cmdline" 2>/dev/null)"
    if printf '%s' "${q}" | grep -q -- ' -snapshot'; then echo "[OK]   QEMU pid ${qp}: -snapshot active"
    else echo "[NG]   QEMU pid ${qp} without -snapshot - stopping"; fail; cleanup; return 1; fi
  done
  [ "${i}" -ge 1 ] || { echo "[NG]   no QEMU process found in group ${PGID} - stopping"; fail; cleanup; return 1; }

  python3 "${DRIVER}" --target "${TARGET}" --transcript "${LINUX_RAW}" \
    --ready-file "${TMPD}/ready" --go-file "${TMPD}/go" > "${TMPD}/driver.out" 2>&1 &
  DPID=$!
  echo "[INFO] Linux console driver started (pid ${DPID})"
  for i in $(seq 1 600); do [ -e "${TMPD}/ready" ] && break; kill -0 "${DPID}" 2>/dev/null || break; sleep 1; done
  if [ ! -e "${TMPD}/ready" ]; then echo "[NG]   Linux side not ready"; cat "${TMPD}/driver.out"; fail; cleanup; return 1; fi
  echo "[OK]   Linux logged in; first Linux checks done"

  echo "-- OpenSBI console: key tests --"
  if [ "${TARGET}" = "m3" ]; then
    wait_for "Setup done. Type keys now" 120; check m3_bmapp1_ready $? "bm-app1 (domain1, hart2) ready for keys"
    inject a
    wait_for "[UART] Got 'a'(0x61)" 30;      check m3_key_a_handled_by_bmapp2 $? "bm-app2 handled 'a'"
    wait_for "switch hart2 domain1 -> domain2" 5;   check m3_switch_to_domain2 $? "hart2 switched domain1 -> domain2"
    wait_for "return hart2 domain2 -> domain1" 10;  check m3_return_to_domain1 $? "hart2 returned domain2 -> domain1"
    inject b
    wait_for "[UART] Got 'b'(0x62)" 30;      check m3_key_b_handled_by_bmapp2 $? "second key handled"
    wait_for "switch hart2 domain1 -> domain2" 10 2; check m3_switch_again $? "switched to domain2 again"
    wait_for "return hart2 domain2 -> domain1" 10 2; check m3_return_again $? "returned to domain1 again"
  else
    inject a
    wait_for "UART got 'a'(0x61)" 30;        check m2_key_a_handled_in_mmode $? "M-mode APLIC handler got 'a'"
    inject b
    wait_for "UART got 'b'(0x62)" 30;        check m2_key_b_handled_in_mmode $? "M-mode APLIC handler got 'b'"
  fi
  touch "${TMPD}/go"
  wait "${DPID}"; drc=$?; DPID=""
  cat "${TMPD}/driver.out"
  printf '[rc=%d] Linux console driver\n' "${drc}"
  [ "${drc}" -eq 0 ] || fail
  grep -q '^RESULT .* FAIL' "${TMPD}/driver.out" && fail
  for i in $(seq 1 60); do kill -0 -- "-${PGID}" 2>/dev/null || break; sleep 1; done
  cleanup

  section "4. Evidence (OpenSBI console)"
  grep -aE 'Boot HART ID|Domain[0-9]+ Name|virq|VIRQ|IRQCHIP|APLIC|BM-APP|\[domain\]|Standard SBI Extensions' "${STDIO_RAW}" | tr -d '\r' | head -n 120
  sanitize < "${STDIO_RAW}" > "${LOG_DIR}/$(basename "${STDIO_RAW%.raw.log}").log"
  sanitize < "${LINUX_RAW}" > "${LOG_DIR}/$(basename "${LINUX_RAW%.raw.log}").log" 2>/dev/null
  chmod 600 "${STDIO_RAW}" "${LINUX_RAW}" 2>/dev/null; chmod 644 "${LOG_DIR}/${NAME}"_*_"${TS}".log 2>/dev/null

  SD_AFTER="$(sha256sum "${IMG_DIR}/sdcard.img" | cut -d' ' -f1)"
  [ "${SD_AFTER}" = "${SD_BEFORE}" ] && echo "[OK]   sdcard.img unchanged (${SD_AFTER:0:16})" \
                                     || { echo "[NG]   sdcard.img changed"; fail; }
}

# ---- main ------------------------------------------------------------------------
{
  trap 'cleanup; rm -rf "${TMPD}"' EXIT
  trap 'cleanup; exit 130' INT TERM
  section "0. Meta"
  echo "Gate        : 05b-2 (${TARGET} interrupt test with ${SRC_NAME})"
  echo "Mode        : ${MODE}"
  echo "Timestamp   : ${TS}"
  echo "Script      : scripts/$(basename "${SCRIPT_PATH}")  sha256=$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"
  if step_precheck && step_launcher; then
    if [ "${MODE}" = "full" ]; then step_run; else echo; echo "[INFO] --prepare-only: QEMU was not started"; fi
  fi
  section "9. Summary"
  echo "Target          : ${TARGET}"
  echo "Mode            : ${MODE}"
  echo "Failed checks   : ${FAILS}"
  if [ "${FAILS}" -ne 0 ]; then echo "Verdict         : ${FAILS} CHECK(S) FAILED - search for '[NG]' / 'FAIL'"
  elif [ "${MODE}" = "prepare-only" ]; then echo "Verdict         : READY - run without --prepare-only"
  else echo "Verdict         : ALL ${TARGET} INTERRUPT CHECKS PASSED"; fi
  echo "Next            : upload logs/gate05/$(basename "${LOG_FILE}") and its .sha256 manifest"
  [ "${FAILS}" -eq 0 ]
} 2>&1 | tee -i "${RAW_FILE}" | sanitize_stream | tee -i "${LOG_FILE}"
STATUS=$?

chmod 600 "${RAW_FILE}"; chmod 644 "${LOG_FILE}"
( cd "${PROJECT_ROOT}" && find logs/gate05 -maxdepth 2 -type f -name "${NAME}_*${TS}*" ! -name '*.sha256' -print0 | sort -z \
    | xargs -0 sha256sum > "${MANIFEST}" && sha256sum "${SCRIPT_PATH#"${PROJECT_ROOT}"/}" "${DRIVER#"${PROJECT_ROOT}"/}" >> "${MANIFEST}" \
    && chmod 600 "${MANIFEST}" )
echo
echo "Sanitized log   : ${LOG_FILE#"${PROJECT_ROOT}"/}"
echo "sha256 manifest : ${MANIFEST#"${PROJECT_ROOT}"/}"
echo "Exit status     : ${STATUS}"
exit "${STATUS}"
