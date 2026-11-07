#!/usr/bin/env bash
# =============================================================================
#  Gate 03 closure check (responds to the G00-G03 audit reports)
#  Project : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  Builds nothing, starts no QEMU, modifies no source tree and no image.
#  The only changes it makes are inside logs/ and work/evidence/:
#    1. Evidence preservation
#       - raw log directories -> 700, raw files -> 600 (audit: umask 0002)
#       - copies the scripts that produced G01-G03 evidence into
#         logs/gateNN/as-run/ when their sha256 equals the recorded value
#    2. G02 artifact re-verification
#       - compares output/images with the sha256 values recorded in G02;
#         a changed sdcard.img (written by the guest in G03) is preserved as
#         work/evidence/sdcard.post-G03.img - nothing is overwritten
#    3. regression_1039 control test (read-only)
#       - which public key OP-TEE actually embeds (out/core/ta_pub_key.c)
#       - history of keys/default.pem and the previous default key
#       - sign_encrypt.py display / verify of the subkey-signed TAs with the
#         CURRENT and the PREVIOUS default key (hello_world as control)
#  Logging: [rc=N], pipefail, umask 077, sanitized log in logs/gate03/, raw log
#  + sha256 manifest in logs/gate03/raw/.
#
#  Usage : bash scripts/gate03_closure_check.sh
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
EVID_DIR="${PROJECT_ROOT}/work/evidence"
LOG_DIR="${PROJECT_ROOT}/logs/gate03"
RAW_DIR="${LOG_DIR}/raw"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/gate03_closure_check_${TS}.log"
RAW_FILE="${RAW_DIR}/gate03_closure_check_${TS}.raw.log"
MANIFEST="${RAW_DIR}/gate03_closure_check_${TS}.sha256"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
mkdir -p "${LOG_DIR}" "${RAW_DIR}"
chmod 700 "${RAW_DIR}"
TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT

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
run() {      # counted: a non-zero exit code is a failure of this check
  local rc
  printf '$ %s\n' "$1"
  bash -c "$1" 2>&1; rc=$?
  printf '[rc=%d]\n' "${rc}"
  [ "${rc}" -ne 0 ] && fail
  return "${rc}"
}
probe() {    # not counted: the exit code IS the measurement (e.g. verify)
  local rc
  printf '$ %s\n' "$1"
  bash -c "$1" 2>&1 | tail -n "${2:-15}"; rc=${PIPESTATUS[0]}
  printf '[rc=%d] (measurement, not counted as failure)\n' "${rc}"
  return "${rc}"
}
modulus_int() {   # RSA modulus of a PEM file as a decimal integer
  openssl rsa -in "$1" -noout -modulus 2>/dev/null | sed -n 's/^Modulus=//p' \
    | python3 -c 'import sys; h=sys.stdin.read().strip(); print(int(h,16) if h else "")'
}
key_desc() {      # "<bits>-bit, modulus sha256 <first 16 hex>"
  python3 - "$1" <<'PYEOF'
import hashlib, sys
s = sys.argv[1].strip()
if not s:
    print("unreadable"); sys.exit()
n = int(s); b = n.to_bytes((n.bit_length() + 7) // 8, "big")
print(f"RSA-{n.bit_length()}, modulus sha256 {hashlib.sha256(b).hexdigest()[:16]}")
PYEOF
}

# executed scripts recorded in the G01-G03 manifests
AS_RUN=(
  "gate01|gate01_fetch_sources.sh|ad843b3352e00e5786b125dce7aa95441092ac34508658b04342e84c24cee7ae"
  "gate02|gate02_memory_check.sh|8708532dc29cf539e6d59c71df3a9ac3e44a1c2e2dca9c73bc3bd500165cd1d0"
  "gate02|gate02_build.sh|609db2e9747802d8b0e691d8918c932b8807d9702cb19dac585453921c1bada8"
  "gate03|gate03_boot_xtest.sh|7339bb1764efd210928e958d99adaec2cde771669a0bc5884571a6ef364b8f2a"
  "gate03|gate03_console.py|df46eb9f55aa706f8c77dfbec077af19673192c50229cecbe8a8367b14513e9a"
  "gate03|gate03_diag_subkey.sh|b17108e207ec45200d81dfe18e6e83b67fce66f625a741c4e64d872e5e10659f"
)
# artifacts recorded in G02 (logs/gate02/gate02_build_20261106-205938.log, section 6)
G02_ARTIFACTS=(
  "99fac1d9a5f458e7baff9120638458ed5e8b5a8a379dbb93c73f3ba5eb583225|bm-app.elf"
  "10705fa71fd848c6c4c887f747ffeeead03614235933c0ba4fbecb489c3001f6|fw_dynamic.bin"
  "9833f9b16b8fa0469722a84a01e6b5b81e9727e36cdd3ba3c7e24ca4d018ae06|fw_dynamic.elf"
  "de9eabd5c9a89a5e92d696234555d2dae1fff8a925836d7cf66714f349eb2fef|fw_jump.bin"
  "1d824dbeac50d71fcbc8265f0b158238112e601983ab9175c9c31d1b6da41715|fw_jump.elf"
  "66e13d43d5071e1cc44245683c192d5f74534c9fa55f9b7c6fd463dbcaa3e8ef|Image"
  "6e1e8c35e2d2b610ceb69b783e7f96ab6bdf92778855fe4f541b02ebd3697294|qemu_rv64_virt_domain.dtb"
  "2f1d2e1e33876fc22e047564a0abf42142f30e9a8abd38ecf3e716391aa1d49c|rootfs.ext2"
  "7a9480377aa0075fc625c72a7c7b856e509884acfc5e0c638b4ca9620793a9cf|rootfs.tar"
  "cebd9fe83b05be19dfc1064a5736120067dc15501bbf64005f3b37bfdfc4f23b|sdcard.img"
  "2fe97c472ac8c05c07e6a959af501c0260fd76d5b6f27749a188844b69b4c360|tee.bin"
  "7068bd390cb098067a275f8975d938e3418e0a8000b93206a7bd5ead3594edfd|u-boot.bin"
  "a5fde1f241b7308ecb189c699187c8c150ac0b1b27d98d7b55e1d977afb741a9|u-boot.itb"
  "8758196e225812389df1eafe83875c0d6f988d0359ec71b25c0db1105bb06d9d|u-boot-spl"
)
SUBKEY1_TA="5c206987-16a3-59cc-ab0f-64b9cfc9e758"
SUBKEY2_TA="a720ccbb-51da-417d-b82e-e5445d474a7a"
HELLO_TA="8aaaf200-2450-11e4-abe2-0002a5d5c51b"

{
  section "0. Meta"
  echo "Gate      : 03 closure check (audit follow-up; no build, no QEMU)"
  echo "Timestamp : ${TS}"
  echo "Script    : scripts/$(basename "${SCRIPT_PATH}")  sha256=$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"
  for t in openssl python3 git; do command -v "${t}" >/dev/null || { echo "[NG]   ${t} not found"; fail; }; done

  # ---------------------------------------------------------------------------
  section "1. Evidence preservation"
  echo "-- raw log permissions (before -> after) --"
  for d in "${PROJECT_ROOT}"/logs/gate*/raw; do
    [ -d "${d}" ] || continue
    before="$(stat -c '%a' "${d}")"
    chmod 700 "${d}" && find "${d}" -maxdepth 1 -type f -exec chmod 600 {} + || fail
    others="$(find "${d}" -maxdepth 1 -type f ! -perm 600 | wc -l)"
    printf '%-24s dir %s -> %s   files not 600: %s\n' "${d#"${PROJECT_ROOT}"/}" "${before}" "$(stat -c '%a' "${d}")" "${others}"
  done
  echo "-- scripts as run (copied only if the sha256 equals the value recorded at run time) --"
  for e in "${AS_RUN[@]}"; do
    IFS='|' read -r gate name want <<<"${e}"
    have="$(sha256sum "${SCRIPT_DIR}/${name}" 2>/dev/null | cut -d' ' -f1)"; have="${have:-missing}"
    dest="${PROJECT_ROOT}/logs/${gate}/as-run"
    if [ "${have}" = "${want}" ]; then
      mkdir -p "${dest}" && chmod 755 "${dest}" && cp -p "${SCRIPT_DIR}/${name}" "${dest}/${name}" && chmod 444 "${dest}/${name}"
      printf '[OK]   %-24s -> logs/%s/as-run/  (%s)\n' "${name}" "${gate}" "${want:0:16}"
    else
      printf '[WARN] %-24s current sha256 %s differs from the run-time value %s - not copied\n' "${name}" "${have:0:16}" "${want:0:16}"
    fi
  done
  echo "[INFO] gate00_env_check.sh: the sha256 of the version that produced the G00 log was not recorded"
  echo "       (the G00 script predates the script-hash logging); current scripts/gate00_env_check.sh is a later"
  echo "       revision (project-root detection only) and is NOT claimed to be the executed version."
  [ -f "${PROJECT_ROOT}/logs/gate01/raw/gate01_fetch_sources.pre-audit.sh" ] && \
    echo "[INFO] logs/gate01/raw/gate01_fetch_sources.pre-audit.sh (version before the audit fixes) is preserved"

  if ! cd "${BR_DIR}" 2>/dev/null; then
    echo "[NG]   work/buildroot not found"; fail
  else
    # -------------------------------------------------------------------------
    section "2. G02 artifacts: still identical?"
    changed_sd=0
    for e in "${G02_ARTIFACTS[@]}"; do
      IFS='|' read -r want name <<<"${e}"
      have="$(sha256sum "output/images/${name}" 2>/dev/null | cut -d' ' -f1)"
      if [ "${have}" = "${want}" ]; then
        printf '[SAME]    %-28s %s\n' "${name}" "${want:0:16}"
      else
        printf '[CHANGED] %-28s G02 %s  now %s\n' "${name}" "${want:0:16}" "${have:0:16}"
        [ "${name}" = "sdcard.img" ] && changed_sd=1
      fi
    done
    if [ "${changed_sd}" -eq 1 ]; then
      echo "[INFO] sdcard.img differs from G02: the G03 guest mounted its root file system read-write"
      echo "       (secure storage, xtest) and could not remount it read-only at poweroff."
      mkdir -p "${EVID_DIR}"
      if [ -e "${EVID_DIR}/sdcard.post-G03.img" ]; then
        echo "[INFO] work/evidence/sdcard.post-G03.img already exists - not overwritten"
      else
        run "cp --reflink=auto -p output/images/sdcard.img '${EVID_DIR}/sdcard.post-G03.img' && chmod 444 '${EVID_DIR}/sdcard.post-G03.img'"
      fi
      echo "post-G03 sdcard.img sha256: $(sha256sum "${EVID_DIR}/sdcard.post-G03.img" 2>/dev/null | cut -d' ' -f1)"
      echo "[INFO] output/images/sdcard.img itself is left untouched. Future boots must use a copy or -snapshot."
    fi

    # -------------------------------------------------------------------------
    section "3. regression_1039 - which key does OP-TEE actually embed?"
    OS="custom/optee-os"
    OUT="output/build/optee-os-custom/out"
    PY="python3"; [ -x output/host/bin/python3 ] && PY="output/host/bin/python3"
    echo "python used for sign_encrypt.py: ${PY}"
    PUBC="$(find output/build/optee-os-custom -name 'ta_pub_key.c' 2>/dev/null | head -n1)"
    if [ -n "${PUBC}" ]; then
      echo "generated public key file: ${PUBC}"
      EMB="$(python3 - "${PUBC}" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"modulus\w*\s*\[\s*\]\s*=\s*\{([^}]*)\}", src)
if m:
    b = bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", m.group(1)))
    print(int.from_bytes(b, "big"))
PYEOF
)"
      echo "embedded in OP-TEE     : $(key_desc "${EMB}")"
    else
      EMB=""; echo "[NG]   ta_pub_key.c not found"; fail
    fi
    echo "-- key-related settings of the OP-TEE build --"
    grep -hsE '^(TA_PUBLIC_KEY|TA_SIGN_KEY|CFG_TA_[A-Z_]*KEY[A-Z_]*|CFG_[A-Z_]*SUBKEY[A-Z_]*)[[:space:]]*:?=' \
      "${OUT}/conf.mk" "${OUT}/export-ta_rv64/mk/conf.mk" 2>/dev/null | sort -u || true
    run "ls -l ${OS}/keys/"
    CUR="$(modulus_int "${OS}/keys/default.pem")"
    echo "keys/default.pem (now) : $(key_desc "${CUR}")"
    echo "-- history of the default key (newest first, follows the 2023 rename) --"
    git -C "${OS}" log --follow --format='COMMIT %H %cs %s' --name-only -- keys/default.pem 2>/dev/null \
      | awk 'NF' > "${TMPD}/hist.txt"
    grep '^COMMIT' "${TMPD}/hist.txt" | cut -c8- | sed -E 's/^([0-9a-f]{12})[0-9a-f]+/\1/'
    PREV_C="$(awk '/^COMMIT/{c++; if (c==2) {print $2; exit}}' "${TMPD}/hist.txt")"
    PREV_P="$(awk '/^COMMIT/{c++; next} c==2 {print; exit}' "${TMPD}/hist.txt")"
    PREV=""
    if [ -n "${PREV_C}" ] && git -C "${OS}" show "${PREV_C}:${PREV_P}" > "${TMPD}/prev_default.pem" 2>/dev/null; then
      PREV="$(modulus_int "${TMPD}/prev_default.pem")"
      echo "previous default key   : $(key_desc "${PREV}")  (from ${PREV_C:0:12}:${PREV_P})"
    else
      echo "[WARN] previous version of the default key could not be extracted from git history"
    fi
    if [ -n "${EMB}" ] && [ -n "${CUR}" ]; then
      [ "${EMB}" = "${CUR}" ] && echo "[OK]   OP-TEE embeds keys/default.pem (identical modulus)" \
                               || echo "[INFO] OP-TEE embeds a key DIFFERENT from keys/default.pem"
    fi

    section "4. regression_1039 - signed headers and subkey chain"
    python3 - output/build/optee-test-4.6.0/ta/top_level_subkey.bin output/build/optee-test-4.6.0/ta/mid_level_subkey.bin \
      output/build/optee-test-4.6.0/ta/identity_subkey2.bin "output/target/lib/optee_armtz/${SUBKEY1_TA}.ta" \
      "output/target/lib/optee_armtz/${SUBKEY2_TA}.ta" "output/target/lib/optee_armtz/${HELLO_TA}.ta" <<'PYEOF'
import struct, sys
TYPES = {0: "TA", 1: "bootstrap TA", 2: "encrypted TA", 3: "subkey"}
ALGOS = {0x70414930: "RSASSA_PKCS1_PSS_MGF1_SHA256", 0x70004830: "RSASSA_PKCS1_V1_5_SHA256"}
for p in sys.argv[1:]:
    try:
        magic, typ, size, algo, hsz, ssz = struct.unpack("<IIIIHH", open(p, "rb").read(20))
    except (OSError, struct.error) as exc:
        print(f"{p}: {exc}"); continue
    print(f"{p.split('/')[-1]:<44} type={TYPES.get(typ, typ)!s:<13} algo={ALGOS.get(algo, hex(algo))} sig={ssz} B (RSA-{ssz*8})")
PYEOF
    echo "(OP-TEE subkeys: the ROOT key verifies top_level_subkey and identity_subkey2;"
    echo " top_level_subkey verifies mid_level_subkey; the last subkey verifies the TA)"
    for ta in "${SUBKEY1_TA}" "${SUBKEY2_TA}"; do
      probe "${PY} ${OS}/scripts/sign_encrypt.py display --in output/target/lib/optee_armtz/${ta}.ta" 60
    done

    section "5. regression_1039 - control test with sign_encrypt.py verify"
    vrf() {   # vrf <label> <key file> <ta uuid>  -> prints PASS/FAIL/ERROR
      local out rc
      out="$("${PY}" "${OS}/scripts/sign_encrypt.py" verify --key "$2" --uuid "$3" --in "output/target/lib/optee_armtz/$3.ta" 2>&1)"; rc=$?
      if printf '%s' "${out}" | grep -qiE 'unrecognized arguments|usage:'; then
        out="$("${PY}" "${OS}/scripts/sign_encrypt.py" verify --key "$2" --in "output/target/lib/optee_armtz/$3.ta" 2>&1)"; rc=$?
      fi
      printf '%-44s rc=%d  %s\n' "$1" "${rc}" "$(printf '%s' "${out}" | tail -n1 | cut -c1-110)"
      [ "${rc}" -eq 0 ] && echo PASS > "${TMPD}/v_$4" || echo FAIL > "${TMPD}/v_$4"
    }
    vrf "hello_world TA  / CURRENT key (control)" "${OS}/keys/default.pem" "${HELLO_TA}" hello_cur
    vrf "subkey1 TA      / CURRENT key"           "${OS}/keys/default.pem" "${SUBKEY1_TA}" s1_cur
    vrf "subkey2 TA      / CURRENT key"           "${OS}/keys/default.pem" "${SUBKEY2_TA}" s2_cur
    if [ -n "${PREV}" ]; then
      vrf "subkey1 TA      / PREVIOUS key"        "${TMPD}/prev_default.pem" "${SUBKEY1_TA}" s1_prev
      vrf "subkey2 TA      / PREVIOUS key"        "${TMPD}/prev_default.pem" "${SUBKEY2_TA}" s2_prev
    fi
    r() { cat "${TMPD}/v_$1" 2>/dev/null || echo "n/a"; }

    section "6. Interpretation"
    echo "embedded key = keys/default.pem : $([ -n "${EMB}" ] && [ "${EMB}" = "${CUR}" ] && echo yes || echo no/unknown)"
    echo "hello_world / current key       : $(r hello_cur)   (expected PASS)"
    echo "subkey TAs  / current key       : $(r s1_cur) / $(r s2_cur)   (G03 runtime: rejected)"
    echo "subkey TAs  / previous key      : $(r s1_prev) / $(r s2_prev)"
    if [ "$(r hello_cur)" != PASS ]; then
      echo "[RESULT] CONTROL FAILED: sign_encrypt.py could not verify even the ordinary hello_world TA."
      echo "         The verify command is not usable here, so this test proves nothing either way."
    elif [ "$(r hello_cur)" = PASS ] && [ "$(r s1_cur)" = FAIL ] && [ "$(r s2_cur)" = FAIL ] \
       && [ "$(r s1_prev)" = PASS ] && [ "$(r s2_prev)" = PASS ] && [ -n "${EMB}" ] && [ "${EMB}" = "${CUR}" ]; then
      echo "[RESULT] CAUSE VERIFIED: both subkey chains verify only with the PREVIOUS default key, while"
      echo "         OP-TEE embeds the CURRENT one. The rejection in regression_1039 follows from this."
    else
      echo "[RESULT] CAUSE NOT PROVEN by this test - see sections 3-5. The size mismatch remains a"
      echo "         strong hypothesis only."
    fi
  fi

  section "9. Summary"
  echo "Failed checks : ${FAILS}   (verify results are measurements, not failures)"
  echo "Next          : upload logs/gate03/$(basename "${LOG_FILE}") and its .sha256 manifest"
  [ "${FAILS}" -eq 0 ]
} 2>&1 | tee -i "${RAW_FILE}" | sanitize_stream | tee -i "${LOG_FILE}"
STATUS=$?

chmod 600 "${RAW_FILE}"
( cd "${PROJECT_ROOT}" && sha256sum "${RAW_FILE#"${PROJECT_ROOT}"/}" "${LOG_FILE#"${PROJECT_ROOT}"/}" \
    "${SCRIPT_PATH#"${PROJECT_ROOT}"/}" > "${MANIFEST}" && chmod 600 "${MANIFEST}" )
echo
echo "Sanitized log   : ${LOG_FILE#"${PROJECT_ROOT}"/}"
echo "sha256 manifest : ${MANIFEST#"${PROJECT_ROOT}"/}"
echo "Exit status     : ${STATUS}"
exit "${STATUS}"
