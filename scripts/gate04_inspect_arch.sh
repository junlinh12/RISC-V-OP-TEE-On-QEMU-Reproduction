#!/usr/bin/env bash
# =============================================================================
#  Gate 04 : architecture evidence for RISC-V OP-TEE (RISE RP016 M1)
#  Project : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  READ-ONLY with respect to sources, build output and images: no build, no
#  QEMU, nothing modified. It only writes logs under logs/gate04/.
#  Collects, in ONE run, the evidence needed for the G04 record and diagrams:
#    A  isolation   : opensbi-domains (DTS source + decompiled DTB), OpenSBI
#                     domain / PMP code, meaning of '*' in the HARTs line
#    B  switching   : OpenSBI domain context switch, MPXY, OP-TEE references;
#                     OP-TEE RISC-V entry/SBI usage; Linux OP-TEE driver + MPXY
#    C  boot chain  : u-boot.itb (FIT) images and load addresses, U-Boot and
#                     OP-TEE configuration
#    D  interrupts  : OP-TEE RISC-V interrupt handling
#    E  warnings    : U-Boot "OP-TEE api uid mismatch", OP-TEE "CPU node does
#                     not have 'reg' property"
#  Searches are measurements: "no match" is a result, not a failure. Only
#  commands that must succeed (dtc, git) are counted as failures.
#  Logging: umask 077, [rc=N], pipefail, sanitized logs in logs/gate04/, raw
#  log + sha256 manifest in logs/gate04/raw/.
#
#  Usage : bash scripts/gate04_inspect_arch.sh
# =============================================================================
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "${SCRIPT_DIR}")" != "scripts" ]; then
  echo "ERROR: place this script in <project-root>/scripts/ and run it from there." >&2
  exit 1
fi
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
BR_DIR="${PROJECT_ROOT}/work/buildroot"
LOG_DIR="${PROJECT_ROOT}/logs/gate04"
RAW_DIR="${LOG_DIR}/raw"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/gate04_inspect_arch_${TS}.log"
RAW_FILE="${RAW_DIR}/gate04_inspect_arch_${TS}.raw.log"
DTS_OUT="${LOG_DIR}/gate04_qemu_rv64_virt_domain.decompiled_${TS}.dts"
FIT_OUT="${LOG_DIR}/gate04_u-boot.itb.layout_${TS}.dts"
MANIFEST="${RAW_DIR}/gate04_inspect_arch_${TS}.sha256"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
mkdir -p "${LOG_DIR}" "${RAW_DIR}" && chmod 755 "${LOG_DIR}" && chmod 700 "${RAW_DIR}"

LNX="output/build/linux-2912ca616fc806dbeeba2e1ac7a157e0843d6987"
UBT="output/build/uboot-32bdb252fab83028768a269fb304b9356547ccbd"
OSBI="custom/opensbi"
OTEE="custom/optee-os"
OTEE_OUT="output/build/optee-os-custom/out"
IMG="output/images"

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
run() {      # must succeed
  local rc
  printf '$ %s\n' "$1"
  bash -c "$1" 2>&1; rc=$?
  printf '[rc=%d]\n' "${rc}"
  [ "${rc}" -ne 0 ] && fail
  return "${rc}"
}
look() {     # look <max lines> <command> : search / listing, result is a measurement
  local rc
  printf '$ %s\n' "$2"
  bash -c "$2" 2>&1 | head -n "$1"; rc=${PIPESTATUS[0]}
  [ "${rc}" -ne 0 ] && printf '(no match / rc=%d)\n' "${rc}"
  return 0
}
around() {   # around <file> <line> <before> <after> : numbered excerpt
  awk -v a="$(( $2 - $3 ))" -v b="$(( $2 + $4 ))" 'NR >= a && NR <= b {printf "   %5d  %s\n", NR, $0}' "$1"
}
node() {     # node <dts file> <regex> : print one DTS node (brace-balanced)
  awk -v pat="$2" '
    !p && $0 ~ pat { p = 1; d = 0 }
    p { print; n = gsub(/\{/, "{"); m = gsub(/\}/, "}"); d += n - m; if (d <= 0 && (n || m)) exit }
  ' "$1"
}
first_hit() { # first_hit <dir> <fixed string> : "file:line" of the first match
  grep -rnIF --include='*.c' --include='*.h' --include='*.S' "$2" "$1" 2>/dev/null | head -n1 | cut -d: -f1,2
}

{
  section "0. Meta"
  echo "Gate      : 04 architecture evidence (read-only)"
  echo "Timestamp : ${TS}"
  echo "Script    : scripts/$(basename "${SCRIPT_PATH}")  sha256=$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"

  if ! cd "${BR_DIR}" 2>/dev/null; then
    echo "[NG]   work/buildroot not found"; fail
  else
    DTC="dtc"; [ -x output/host/bin/dtc ] && DTC="output/host/bin/dtc"
    for d in "${LNX}" "${UBT}" "${OSBI}" "${OTEE}" "${OTEE_OUT}"; do
      [ -d "${d}" ] && echo "[OK]   ${d}" || { echo "[NG]   ${d} missing"; fail; }
    done
    run "git -C ${OSBI} log -1 --format='opensbi   %h %cs %s'"
    run "git -C ${OTEE} log -1 --format='optee_os  %h %cs %s'"

    # =========================================================================
    section "A. Isolation: OpenSBI domains and PMP"
    sub "A1 domain DTS source in the Linux tree"
    SRC_DTS="$(find "${LNX}/arch/riscv/boot/dts" -name 'qemu_rv64_virt_domain.dts' 2>/dev/null | head -n1)"
    if [ -n "${SRC_DTS}" ]; then
      echo "file: ${SRC_DTS#"${LNX}"/}"
      grep -nE '^#include|/include/' "${SRC_DTS}" || echo "(no includes)"
      awk '{printf "   %4d  %s\n", NR, $0}' "${SRC_DTS}" | head -n 400
    else
      echo "[WARN] qemu_rv64_virt_domain.dts not found in the Linux tree"
    fi
    sub "A2 decompiled DTB actually passed to QEMU (full file: logs/gate04/$(basename "${DTS_OUT}"))"
    run "${DTC} -I dtb -O dts -o '${RAW_DIR}/dtb.dts' ${IMG}/qemu_rv64_virt_domain.dtb 2>/dev/null"
    if [ -f "${RAW_DIR}/dtb.dts" ]; then
      sanitize < "${RAW_DIR}/dtb.dts" > "${DTS_OUT}"; chmod 644 "${DTS_OUT}"
      echo "-- node: opensbi-domains --";  node "${RAW_DIR}/dtb.dts" 'opensbi-domains'
      echo "-- node: cpus --";             node "${RAW_DIR}/dtb.dts" '^[[:space:]]*cpus[[:space:]]*\{'
      echo "-- node: reserved-memory --";  node "${RAW_DIR}/dtb.dts" 'reserved-memory'
      echo "-- node: memory --";           node "${RAW_DIR}/dtb.dts" '^[[:space:]]*memory@'
      echo "-- node: chosen --";           node "${RAW_DIR}/dtb.dts" '^[[:space:]]*chosen'
      echo "-- nodes mentioning optee / mpxy / rpmi (compatible strings) --"
      grep -nE 'compatible = .*(optee|mpxy|rpmi|sbi)' "${RAW_DIR}/dtb.dts" || echo "(none)"
      echo "-- node: firmware --";         node "${RAW_DIR}/dtb.dts" '^[[:space:]]*firmware[[:space:]]*\{'
      rm -f "${RAW_DIR}/dtb.dts"
    fi
    sub "A3 OpenSBI: where domain regions become PMP entries"
    look 30 "git -C ${OSBI} grep -n -E '(sbi_hart_pmp_configure|sbi_hart_smepmp_configure|sbi_hart_oldpmp_configure|pmp_set)[[:space:]]*\\(' -- lib/sbi"
    sub "A4 OpenSBI: meaning of '*' in 'DomainN HARTs'"
    hit="$(git -C "${OSBI}" grep -n 'HARTs' -- lib/sbi/sbi_domain.c 2>/dev/null | head -n1 | cut -d: -f2)"
    [ -n "${hit}" ] && around "${OSBI}/lib/sbi/sbi_domain.c" "${hit}" 3 10 || echo "(HARTs print not found)"
    sub "A5 OpenSBI: opensbi-domains device-tree parser"
    look 15 "git -C ${OSBI} grep -n -E 'opensbi,domain,instance|possible-harts|next-addr|regions' -- lib/utils/fdt/fdt_domain.c"

    # =========================================================================
    section "B. Switching and communication (the role SMC plays on Arm)"
    sub "B1 OpenSBI: domain context switch"
    look 20 "git -C ${OSBI} grep -n -E 'sbi_domain_context_(enter|exit)[[:space:]]*\\(' -- lib include"
    sub "B2 OpenSBI: MPXY / RPMI"
    look 20 "git -C ${OSBI} ls-files | grep -iE 'mpxy|rpmi'"
    look 10 "git -C ${OSBI} grep -n -E 'define SBI_EXT_MPXY' -- include"
    sub "B3 OpenSBI: everything that mentions OP-TEE"
    look 60 "git -C ${OSBI} grep -n -i 'optee' -- lib platform include firmware"
    sub "B4 OP-TEE OS: RISC-V files and SBI / MPXY usage"
    look 60 "git -C ${OTEE} ls-files core/arch/riscv/kernel core/arch/riscv/include | grep -vE '\\.(md|txt)$'"
    look 40 "git -C ${OTEE} grep -n -i -E 'mpxy|rpmi' -- core"
    look 40 "git -C ${OTEE} grep -n -E 'SBI_EXT_[A-Z_]+' -- core/arch/riscv"
    sub "B5 Linux: OP-TEE driver and MPXY"
    look 30 "ls ${LNX}/drivers/tee/optee"
    look 40 "grep -rnI -i -E 'mpxy|rpmi|riscv' ${LNX}/drivers/tee/optee"
    look 20 "ls ${LNX}/drivers/mailbox ${LNX}/drivers/firmware 2>/dev/null | grep -iE 'mpxy|rpmi'"
    look 30 "grep -E '^CONFIG_(TEE|OPTEE[A-Z_]*|RISCV_SBI[A-Z_]*|MAILBOX|RISCV_SBI_MPXY[A-Z_]*|[A-Z_]*RPMI[A-Z_]*)=' ${LNX}/.config"

    # =========================================================================
    section "C. Boot chain"
    sub "C1 u-boot.itb (FIT) without payload data (full: logs/gate04/$(basename "${FIT_OUT}"))"
    "${DTC}" -I dtb -O dts "${IMG}/u-boot.itb" 2>/dev/null | grep -vE '^[[:space:]]*data = ' | sanitize > "${FIT_OUT}"
    chmod 644 "${FIT_OUT}"
    if [ -s "${FIT_OUT}" ]; then head -n 120 "${FIT_OUT}"; else echo "[NG]   could not decode u-boot.itb"; fail; fi
    sub "C2 U-Boot configuration (SPL, OpenSBI, OP-TEE)"
    look 40 "grep -E '^CONFIG_(SPL_OPENSBI[A-Z_]*|SPL_OPTEE[A-Z_]*|OPTEE[A-Z_]*|TEE|SPL_LOAD_FIT[A-Z_]*|TEXT_BASE|SPL_TEXT_BASE|SPL_RAM_DEVICE|RISCV_SMODE|SPL_RISCV_MMODE|DEFAULT_DEVICE_TREE)=' ${UBT}/.config"
    sub "C3 OP-TEE build configuration (memory layout, cores, RISC-V options)"
    look 50 "grep -hE '^(PLATFORM|PLATFORM_FLAVOR|CFG_(TDDRAM|TEE_RAM|TZDRAM|SHMEM|TEE_SHMEM|CORE_RESERVED_SHM|TEE_CORE_NB_CORE|NUM_THREADS|CORE_ASLR|RISCV[A-Z_]*|16550_UART|SEMIHOSTING[A-Z_]*|DT|EXTERNAL_DT|TEE_CORE_LOG_LEVEL)[A-Z_]*)[[:space:]]*:?=' ${OTEE_OUT}/conf.mk | sort -u"

    # =========================================================================
    section "D. Interrupts in OP-TEE (RISC-V)"
    look 40 "git -C ${OTEE} grep -n -i -E 'foreign|native_intr|interrupt' -- core/arch/riscv/kernel"

    # =========================================================================
    section "E. The two warnings seen in G03"
    sub "E1 U-Boot: 'OP-TEE api uid mismatch'"
    loc="$(first_hit "${UBT}/drivers/tee" 'api uid mismatch')"
    if [ -n "${loc}" ]; then
      echo "location: ${loc#"${UBT}"/}"; around "${loc%%:*}" "${loc##*:}" 30 5
    else
      echo "(message not found in ${UBT}/drivers/tee)"
    fi
    look 30 "grep -rnI -i -E 'riscv|sbi|mpxy|ecall|arm_smccc' ${UBT}/drivers/tee/optee"
    echo "-- UID constants: U-Boot side --"
    look 12 "grep -rnI -E 'OPTEE_MSG_UID_[0-3]|OPTEE_MSG_OS_OPTEE_UUID_[0-3]' ${UBT}/drivers/tee/optee ${UBT}/include"
    echo "-- UID constants: OP-TEE side --"
    look 12 "git -C ${OTEE} grep -n -E 'OPTEE_MSG_UID_[0-3]|OPTEE_MSG_OS_OPTEE_UUID_[0-3]' -- core"
    sub "E2 OP-TEE: 'CPU node does not have 'reg' property'"
    loc="$(first_hit "${OTEE}/core" "does not have 'reg' property")"
    if [ -n "${loc}" ]; then
      echo "location: ${loc#"${OTEE}"/}"; around "${loc%%:*}" "${loc##*:}" 25 12
    else
      echo "(message not found in ${OTEE}/core)"
    fi
  fi

  section "9. Summary"
  echo "Failed commands : ${FAILS}   (searches without a match are results, not failures)"
  echo "Next            : upload logs/gate04/$(basename "${LOG_FILE}"), the .dts files next to it,"
  echo "                  and the .sha256 manifest"
  [ "${FAILS}" -eq 0 ]
} 2>&1 | tee -i "${RAW_FILE}" | sanitize_stream | tee -i "${LOG_FILE}"
STATUS=$?

chmod 600 "${RAW_FILE}"; chmod 644 "${LOG_FILE}"
MFILES=("${RAW_FILE}" "${LOG_FILE}")
[ -f "${DTS_OUT}" ] && MFILES+=("${DTS_OUT}")
[ -f "${FIT_OUT}" ] && MFILES+=("${FIT_OUT}")
MFILES+=("${SCRIPT_PATH}")
( cd "${PROJECT_ROOT}" && sha256sum "${MFILES[@]#"${PROJECT_ROOT}"/}" > "${MANIFEST}" && chmod 600 "${MANIFEST}" )
echo
echo "Sanitized log   : ${LOG_FILE#"${PROJECT_ROOT}"/}"
echo "Decompiled DTS  : ${DTS_OUT#"${PROJECT_ROOT}"/}"
echo "FIT layout      : ${FIT_OUT#"${PROJECT_ROOT}"/}"
echo "sha256 manifest : ${MANIFEST#"${PROJECT_ROOT}"/}"
echo "Exit status     : ${STATUS}"
exit "${STATUS}"
