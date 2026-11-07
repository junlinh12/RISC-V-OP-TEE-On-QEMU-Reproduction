#!/usr/bin/env bash
# =============================================================================
#  Gate 03 : diagnosis of xtest regression_1039 (subkey verification)
#  Project : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  READ-ONLY. Builds nothing, changes nothing, starts no QEMU.
#  Hypothesis: optee_test 4.6.0 ships test subkeys that were pre-signed with
#  the (enlarged) upstream default TA key, while the RISE optee_os fork embeds
#  an older default key. Ordinary TAs are signed at build time with the same
#  optee_os key and therefore load; only the subkey-signed TAs are rejected
#  with TEE_ERROR_SECURITY.
#  The script compares:
#    1. the default TA key of custom/optee-os (size, history, TA dev kit copy)
#    2. the signed headers (shdr) of the subkeys and TAs from optee_test 4.6.0
#  Logging: [rc=N], pipefail, sanitized log in logs/gate03/, raw log +
#  sha256 manifest in logs/gate03/raw/ (local only).
#
#  Usage : bash scripts/gate03_diag_subkey.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "${SCRIPT_DIR}")" != "scripts" ]; then
  echo "ERROR: place this script in <project-root>/scripts/ and run it from there." >&2
  exit 1
fi
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
BR_DIR="${PROJECT_ROOT}/work/buildroot"
LOG_DIR="${PROJECT_ROOT}/logs/gate03"
RAW_DIR="${LOG_DIR}/raw"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/gate03_diag_subkey_${TS}.log"
RAW_FILE="${RAW_DIR}/gate03_diag_subkey_${TS}.raw.log"
MANIFEST="${RAW_DIR}/gate03_diag_subkey_${TS}.sha256"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
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
key_bits() {   # RSA key size of a PEM file (private or public)
  openssl pkey -in "$1" -noout -text 2>/dev/null | head -n1 | grep -oE '[0-9]+ bit' \
    || openssl pkey -pubin -in "$1" -noout -text 2>/dev/null | head -n1 | grep -oE '[0-9]+ bit'
}
shdr() {       # print the signed header (struct shdr) of OP-TEE signed images
  python3 - "$@" <<'PYEOF'
import struct, sys
TYPES = {0: "TA", 1: "bootstrap TA", 2: "encrypted TA", 3: "subkey"}
for path in sys.argv[1:]:
    try:
        raw = open(path, "rb").read(20)
        magic, img_type, img_size, algo, hash_size, sig_size = struct.unpack("<IIIIHH", raw)
    except (OSError, struct.error) as exc:
        print(f"{path}: cannot read ({exc})"); continue
    ok = "ok" if magic == 0x4F545348 else "BAD MAGIC"
    print(f"{path.split('/')[-1]:<48} magic={ok:<9} type={TYPES.get(img_type, img_type)!s:<13} "
          f"hash={hash_size:>3} B  sig={sig_size:>3} B  => signed with RSA-{sig_size * 8}")
PYEOF
}

OS_DIR="custom/optee-os"
TEST_DIR="output/build/optee-test-4.6.0"
TA_DIR="output/target/lib/optee_armtz"
SUBKEY1_TA="5c206987-16a3-59cc-ab0f-64b9cfc9e758"
SUBKEY2_TA="a720ccbb-51da-417d-b82e-e5445d474a7a"
HELLO_TA="8aaaf200-2450-11e4-abe2-0002a5d5c51b"

{
  section "0. Meta"
  echo "Gate      : 03 diagnosis of xtest regression_1039 (read-only)"
  echo "Timestamp : ${TS}"
  echo "Script    : scripts/$(basename "${SCRIPT_PATH}")  sha256=$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"

  if ! cd "${BR_DIR}" 2>/dev/null; then
    echo "[NG]   work/buildroot not found"; fail
  else
    command -v openssl >/dev/null 2>&1 || { echo "[NG]   openssl not found"; fail; }

    section "1. RISE optee_os fork (custom/optee-os)"
    run "git -C ${OS_DIR} log -1 --format='HEAD    %H %cs %s'"
    run "grep -E '^CFG_OPTEE_REVISION_(MAJOR|MINOR) ' ${OS_DIR}/mk/config.mk"
    OS_BITS="$(key_bits "${OS_DIR}/keys/default_ta.pem")"
    echo "keys/default_ta.pem : ${OS_BITS:-unknown}"
    echo "-- last commits that changed keys/default_ta.pem --"
    run "git -C ${OS_DIR} log -3 --format='%h %cs %s' -- keys/default_ta.pem"
    echo "-- default keys inside the installed TA dev kit(s) --"
    find output -path '*export-ta_*' -name '*.pem' 2>/dev/null | while read -r k; do
      printf '%-80s %s\n' "${k}" "$(key_bits "${k}")"
    done

    section "2. optee_test 4.6.0: pre-signed test subkeys (signed with the ROOT key)"
    shdr "${TEST_DIR}/ta/top_level_subkey.bin" "${TEST_DIR}/ta/mid_level_subkey.bin" "${TEST_DIR}/ta/identity_subkey2.bin"

    section "3. TAs installed in the guest root filesystem"
    shdr "${TA_DIR}/${SUBKEY1_TA}.ta" "${TA_DIR}/${SUBKEY2_TA}.ta" "${TA_DIR}/${HELLO_TA}.ta"
    echo "(subkey-signed TAs start with the subkey chain; hello_world is signed directly with the build-time key)"

    section "4. Result"
    ROOT_SIG="$(python3 -c 'import struct,sys; print(struct.unpack("<IIIIHH", open(sys.argv[1],"rb").read(20))[5]*8)' \
                "${TEST_DIR}/ta/top_level_subkey.bin" 2>/dev/null)"
    OS_N="$(printf '%s' "${OS_BITS}" | grep -oE '[0-9]+')"
    echo "optee_os default TA key          : RSA-${OS_N:-?}"
    echo "root signature on the test subkey: RSA-${ROOT_SIG:-?}"
    if [ -n "${OS_N}" ] && [ -n "${ROOT_SIG}" ] && [ "${OS_N}" != "${ROOT_SIG}" ]; then
      echo "[RESULT] MISMATCH CONFIRMED - the test subkeys of optee_test 4.6.0 were signed with an"
      echo "         RSA-${ROOT_SIG} root key, but this optee_os embeds an RSA-${OS_N} default key."
      echo "         OP-TEE correctly rejects the chain (TEE_ERROR_SECURITY). This is a test-suite /"
      echo "         key version mismatch, not a defect of the RISC-V OP-TEE port."
    elif [ -n "${OS_N}" ] && [ -n "${ROOT_SIG}" ]; then
      echo "[RESULT] key sizes match (RSA-${OS_N}) - the size-mismatch hypothesis is NOT confirmed;"
      echo "         the keys may still differ in content. Further analysis is needed."
    else
      echo "[RESULT] could not determine both key sizes - see the sections above"; fail
    fi
  fi

  section "9. Summary"
  echo "Failed commands : ${FAILS}"
  echo "This script changed nothing."
  echo "Next            : upload logs/gate03/$(basename "${LOG_FILE}") and its .sha256 manifest"
  [ "${FAILS}" -eq 0 ]
} 2>&1 | tee -i "${RAW_FILE}" | sanitize_stream | tee -i "${LOG_FILE}"
STATUS=$?

( cd "${PROJECT_ROOT}" && sha256sum "${RAW_FILE#"${PROJECT_ROOT}"/}" "${LOG_FILE#"${PROJECT_ROOT}"/}" \
    "${SCRIPT_PATH#"${PROJECT_ROOT}"/}" > "${MANIFEST}" )
echo
echo "Sanitized log   : ${LOG_FILE#"${PROJECT_ROOT}"/}"
echo "sha256 manifest : ${MANIFEST#"${PROJECT_ROOT}"/}"
echo "Exit status     : ${STATUS}"
exit "${STATUS}"
