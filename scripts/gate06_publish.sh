#!/usr/bin/env bash
# =============================================================================
#  Gate 06-3 : assemble the publication tree publish/ and re-scan it
#  Project   : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  Usage : bash scripts/gate06_publish.sh            (refuses if publish/ exists)
#          bash scripts/gate06_publish.sh --replace  (deletes and rebuilds publish/)
#
#  The sources (logs/, docs/, scripts/, README*) are only READ. Output goes to
#  publish/ (to become the repository root) and to this gate's own logs.
#  What goes in (explicit allowlist; anything else is reported as excluded)
#    README.md, README.ja.md                                   -> /
#    docs/{source-lock,evidence-index*,known-limitations*}.md   -> docs/
#    the 16 work records (G00-G05c, EN + JA) from logs/gateNN/  -> docs/
#    the 8 concept figures from logs/gate04/figures/            -> docs/figures/
#    scripts/*.sh, scripts/*.py, scripts/*.tsv (scan acks)      -> scripts/
#  v2: also publishes scripts/gate06_scan_ack.tsv
#    logs/gateNN/{*.log,*.dts,*.txt,*.tsv}, logs/gateNN/as-run/ -> logs/gateNN/
#  Never: raw/ directories, *checkpoint*, other files under logs/.
#  Log cleaning (copies only): ANSI escape sequences removed; URL query strings
#  replaced by "?<QUERY-REMOVED>"; valid IPv6 addresses (except ::1) -> <IPv6>;
#  "+0900" and "JST" -> <TZ>. *_make_*.log and *_qemu_stdio_*.log are then
#  gzip-compressed (deterministic, mtime 0).
#  Afterwards the tree is scanned with "gate06_inventory.sh --tree publish";
#  verdict READY TO PUBLISH only if that scan reports 0 blockers.
# =============================================================================
set -uo pipefail
umask 022

REPLACE=0
case "${1:-}" in
  "") ;;
  --replace) REPLACE=1 ;;
  *) echo "usage: bash scripts/gate06_publish.sh [--replace]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "${SCRIPT_DIR}")" != "scripts" ]; then
  echo "ERROR: place this script in <project-root>/scripts/ and run it from there." >&2
  exit 1
fi
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
OUT="${PROJECT_ROOT}/publish"
LOG_DIR="${PROJECT_ROOT}/logs/gate06"
RAW_DIR="${LOG_DIR}/raw"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/gate06_publish_${TS}.log"
RAW_FILE="${RAW_DIR}/gate06_publish_${TS}.raw.log"
MANIFEST="${RAW_DIR}/gate06_publish_${TS}.sha256"
mkdir -p "${LOG_DIR}" "${RAW_DIR}" && chmod 755 "${LOG_DIR}" && chmod 700 "${RAW_DIR}"
TMPD="$(mktemp -d)"; trap 'rm -rf "${TMPD}"' EXIT

RECORDS=(
  logs/gate00/G00_host_baseline.md logs/gate00/G00_host_baseline.ja.md
  logs/gate01/G01_source_pinning.md logs/gate01/G01_source_pinning.ja.md
  logs/gate02/G02_buildroot_build.md logs/gate02/G02_buildroot_build.ja.md
  logs/gate03/G03_qemu_boot_xtest.md logs/gate03/G03_qemu_boot_xtest.ja.md
  logs/gate04/G04_architecture_verification.md logs/gate04/G04_architecture_verification.ja.md
  logs/gate05/G05a_isolation_demo.md logs/gate05/G05a_isolation_demo.ja.md
  logs/gate05/G05b_interrupts_m2_m3.md logs/gate05/G05b_interrupts_m2_m3.ja.md
  logs/gate05/G05c_version_comparison.md logs/gate05/G05c_version_comparison.ja.md
)
FIGURES=()
for n in architecture boot-flow; do for l in en ja; do for e in svg png; do
  FIGURES+=("logs/gate04/figures/riscv-optee-m1-${n}-${l}.${e}")
done; done; done
ROOTDOCS=(README.md README.ja.md)
DOCS=(docs/source-lock.md docs/evidence-index.md docs/evidence-index.ja.md docs/known-limitations.md docs/known-limitations.ja.md)

# ---- sanitizer for this script's own log (same rules as the other scripts) ----
U_NAME="$(id -un)"
H_SHORT="$(hostname -s 2>/dev/null || true)"
H_FQDN="$(hostname -f 2>/dev/null || true)"
esc() { printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|#]/\\&/g'; }
SED_ARGS=(-E -e "s#$(esc "${HOME}")#<HOME>#g")
[ -n "${H_FQDN}" ]  && SED_ARGS+=(-e "s#\\b$(esc "${H_FQDN}")\\b#<HOST>#g")
[ -n "${H_SHORT}" ] && SED_ARGS+=(-e "s#\\b$(esc "${H_SHORT}")\\b#<HOST>#g")
[ -n "${U_NAME}" ]  && SED_ARGS+=(-e "s#\\b$(esc "${U_NAME}")\\b#<USER>#g")
sanitize_stream() { ( trap '' INT; exec sed -u "${SED_ARGS[@]}" ); }
section() { printf '\n===== %s =====\n' "$1"; }
FAILS=0
fail() { FAILS=$((FAILS + 1)); }

# ---- log cleaner (Python, standard library) ------------------------------------
cat > "${TMPD}/clean.py" <<'PYEOF'
import gzip, ipaddress, re, sys
src, dst, do_gzip = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
t = open(src, "rb").read().decode("utf-8", "surrogateescape")
n = {}
def sub(key, rx, repl, text):
    out, k = rx.subn(repl, text); n[key] = k; return out
t = sub("ansi", re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][0-9A-Za-z]|\x1b[=>]"), "", t)
t = sub("url_query", re.compile(r"(https?://[^\s\"'<>?]+)\?[^\s\"'<>]*"), r"\1?<QUERY-REMOVED>", t)
v6 = 0
def ip6(m):
    global v6
    v = m.group(0)
    if v.count(":") < 2 or v in ("::1", "::"): return v
    try: ipaddress.IPv6Address(v)
    except ValueError: return v
    v6 += 1; return "<IPv6>"
t = re.sub(r"(?<![0-9A-Za-z:])[0-9A-Fa-f:]{3,39}(?![0-9A-Za-z:])", ip6, t); n["ipv6"] = v6
t = sub("tz", re.compile(r"\+0900|\bJST\b"), "<TZ>", t)
data = t.encode("utf-8", "surrogateescape")
if do_gzip:
    data = gzip.compress(data, compresslevel=9, mtime=0)
open(dst, "wb").write(data)
print(" ".join(f"{k}={v}" for k, v in n.items() if v))
PYEOF

{
  section "0. Meta"
  echo "Gate        : 06-3 assemble publish/ and re-scan"
  echo "Timestamp   : ${TS}"
  echo "Script      : scripts/$(basename "${SCRIPT_PATH}")  sha256=$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"
  cd "${PROJECT_ROOT}" || exit 1

  section "1. Pre-checks"
  missing=0
  for f in "${ROOTDOCS[@]}" "${DOCS[@]}" "${RECORDS[@]}" "${FIGURES[@]}"; do
    [ -f "${f}" ] || { echo "[NG]   required file missing: ${f}"; missing=1; }
  done
  [ "${missing}" -eq 0 ] && echo "[OK]   all $(( ${#ROOTDOCS[@]} + ${#DOCS[@]} + ${#RECORDS[@]} + ${#FIGURES[@]} )) required documents and figures are present" || fail
  [ -f "${SCRIPT_DIR}/gate06_inventory.sh" ] && echo "[OK]   scripts/gate06_inventory.sh present (used for the re-scan)" || { echo "[NG]   scripts/gate06_inventory.sh missing"; fail; }
  if [ -e "${OUT}" ]; then
    if [ "${REPLACE}" -eq 1 ]; then
      rm -rf -- "${OUT}" && echo "[OK]   existing publish/ removed (--replace)"
    else
      echo "[NG]   publish/ already exists - run with --replace to rebuild it"; fail
    fi
  fi

  if [ "${FAILS}" -eq 0 ]; then
    section "2. Assemble publish/"
    mkdir -p "${OUT}/docs/figures" "${OUT}/scripts" "${OUT}/logs"
    cp -p "${ROOTDOCS[@]}" "${OUT}/"
    cp -p "${DOCS[@]}" "${OUT}/docs/"
    cp -p "${RECORDS[@]}" "${OUT}/docs/"
    cp -p "${FIGURES[@]}" "${OUT}/docs/figures/"
    for f in scripts/*.sh scripts/*.py scripts/*.tsv; do [ -f "${f}" ] && cp -p "${f}" "${OUT}/scripts/"; done   # .tsv: scan acknowledgements
    echo "[OK]   README 2, docs ${#DOCS[@]}, records ${#RECORDS[@]}, figures ${#FIGURES[@]}, scripts $(ls "${OUT}/scripts" | wc -l)"
    echo "-- logs (cleaned copies) --"
    : > "${TMPD}/excluded.txt"
    nlog=0; ngz=0
    while IFS= read -r f; do
      rel="${f#logs/}"; dir="${OUT}/logs/$(dirname "${rel}")"
      case "${f}" in
        */raw/*|*[Cc]heckpoint*) continue ;;                                  # never published
        logs/gate[0-9][0-9]/as-run/*) mkdir -p "${dir}"; cp -p "${f}" "${dir}/"; continue ;;
        logs/gate04/figures/*)                                                # allowlisted ones were copied above
          printf '%s\n' "${FIGURES[@]}" | grep -qxF "${f}" || printf '%s\n' "${f}" >> "${TMPD}/excluded.txt"; continue ;;
        *.md) printf '%s\n' "${RECORDS[@]}" | grep -qxF "${f}" || printf '%s\n' "${f}" >> "${TMPD}/excluded.txt"; continue ;;
        logs/gate06/gate06_publish_*|logs/gate06/gate06_treescan_*) continue ;;   # this gate's own outputs
        *.log|*.dts|*.txt|*.tsv) ;;
        *) printf '%s\n' "${f}" >> "${TMPD}/excluded.txt"; continue ;;
      esac
      mkdir -p "${dir}"
      gz=0; case "$(basename "${f}")" in *_make_*.log|*_qemu_stdio_*.log) gz=1 ;; esac
      dst="${dir}/$(basename "${f}")"; [ "${gz}" -eq 1 ] && dst="${dst}.gz"
      res="$(python3 "${TMPD}/clean.py" "${f}" "${dst}" "${gz}")" || { echo "[NG]   cleaning failed: ${f}"; fail; continue; }
      nlog=$((nlog + 1)); [ "${gz}" -eq 1 ] && ngz=$((ngz + 1))
      [ -n "${res}" ] && printf '  %-62s %s\n' "${f}$( [ "${gz}" -eq 1 ] && echo ' -> .gz')" "${res}"
    done < <(find logs -type f -path 'logs/gate[0-9][0-9]/*' | sort)
    echo "[OK]   ${nlog} log files copied, ${ngz} of them gzip-compressed (files without changes are not listed)"
    echo "-- not published (excluded by the allowlist; review) --"
    if [ -s "${TMPD}/excluded.txt" ]; then sed 's/^/  /' "${TMPD}/excluded.txt"; else echo "  (none)"; fi
    echo "-- size --"
    du -sh "${OUT}" | sed "s#${OUT}#publish/#"
    big="$(find "${OUT}" -type f -size +50M | sed "s#${OUT}/##")"
    [ -z "${big}" ] && echo "[OK]   no file larger than 50 MB" || { echo "[NG]   files larger than 50 MB:"; echo "${big}"; fail; }

    section "3. Re-scan of publish/ (gate06_inventory.sh --tree publish)"
    bash "${SCRIPT_DIR}/gate06_inventory.sh" --tree publish > "${TMPD}/scan.out" 2>&1
    sed -n '/===== 1/,/===== 3/p' "${TMPD}/scan.out" | grep -v '^===== 3'
    b="$(sed -nE 's/^SUMMARY blockers=([0-9]+) .*/\1/p' "${TMPD}/scan.out" | tail -n1)"
    echo "re-scan log: $(grep -E '^Sanitized log' "${TMPD}/scan.out" | sed 's/.*: //')"
    if [ "${b:-x}" = "0" ]; then echo "[OK]   0 blockers in publish/"; else echo "[NG]   blockers in publish/: ${b:-unknown}"; fail; fi
    # ship the re-scan report itself (evidence-index #19); it holds only counts, paths and hashes
    sl="$(ls -t "${LOG_DIR}"/gate06_treescan_2*.log 2>/dev/null | head -n1)"
    st="$(ls -t "${LOG_DIR}"/gate06_treescan_files_*.tsv 2>/dev/null | head -n1)"
    if [ -n "${sl}" ] && [ -n "${st}" ]; then
      mkdir -p "${OUT}/logs/gate06" && cp -p "${sl}" "${st}" "${OUT}/logs/gate06/"
      echo "[OK]   re-scan report added: logs/gate06/$(basename "${sl}"), $(basename "${st}")"
    else
      echo "[NG]   re-scan report not found"; fail
    fi

    section "4. SHA256SUMS"
    ( cd "${OUT}" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum | sed 's#  \./#  #' > SHA256SUMS )
    echo "[OK]   publish/SHA256SUMS lists $(wc -l < "${OUT}/SHA256SUMS") files"
  fi

  section "9. Summary"
  echo "Failed checks   : ${FAILS}"
  if [ "${FAILS}" -eq 0 ]; then
    echo "Verdict         : READY TO PUBLISH - review publish/ (README, figures) before G06-4"
  else
    echo "Verdict         : NOT READY - search this log for '[NG]'"
  fi
  echo "Next            : upload logs/gate06/$(basename "${LOG_FILE}"), its .sha256 manifest, and the latest gate06_treescan_*.log/.tsv"
  [ "${FAILS}" -eq 0 ]
} 2>&1 | tee -i "${RAW_FILE}" | sanitize_stream | tee -i "${LOG_FILE}"
STATUS=${PIPESTATUS[0]}
chmod 600 "${RAW_FILE}"; chmod 644 "${LOG_FILE}"
( cd "${PROJECT_ROOT}" && sha256sum "${RAW_FILE#"${PROJECT_ROOT}"/}" "${LOG_FILE#"${PROJECT_ROOT}"/}" "${SCRIPT_PATH#"${PROJECT_ROOT}"/}" > "${MANIFEST}" && chmod 600 "${MANIFEST}" )
echo
echo "Sanitized log   : ${LOG_FILE#"${PROJECT_ROOT}"/}"
echo "sha256 manifest : ${MANIFEST#"${PROJECT_ROOT}"/}"
exit "${STATUS}"
