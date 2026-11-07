#!/usr/bin/env bash
# =============================================================================
#  Gate 06-1 : inventory and leak scan of the publication candidates
#  Project   : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  Usage : bash scripts/gate06_inventory.sh                 project mode (G06-1)
#          bash scripts/gate06_inventory.sh --tree publish  scan every file of an
#                                                           assembled tree (G06-3)
#  v2: --tree mode; .gz files are scanned decompressed; the two gate06 scripts
#      (which contain the patterns by design) are not scanned in either mode.
#
#  READ-ONLY: nothing is moved, changed or deleted. Writes only its own logs
#  under logs/gate06/.
#  Candidates: everything under logs/gate*/ except raw/ and *checkpoint*.md
#  (sanitized logs, work records, figures, DTS, pins, as-run scripts), plus
#  scripts/*.sh|*.py, README* and docs/ if present.
#  Findings
#    BLOCKER  must be 0 before publishing: home path, user name, host name,
#             e-mail address, signed-URL query or token, private key, >100 MB
#    REVIEW   decided one by one: IPv4 (QEMU user-net 10.0.2.x shown apart),
#             IPv6, MAC (QEMU OUI 52:54:00 shown apart), "<EMAIL>" placeholder
#             (possible over-masking), files >50 MB
#    INFO     time zone (+0900 / JST), ANSI escape sequences
#  The report never prints the user name, host name or full addresses: only
#  counts, e-mail domains, URL hosts and masked values.
#  Also checks .gitignore and whether git user.email is a GitHub noreply
#  address (the address itself is not printed).
# =============================================================================
set -uo pipefail
umask 077

TREE=""
case "${1:-}" in
  "") ;;
  --tree) TREE="${2:-}"; [ -n "${TREE}" ] || { echo "usage: bash scripts/gate06_inventory.sh [--tree DIR]" >&2; exit 2; } ;;
  *) echo "usage: bash scripts/gate06_inventory.sh [--tree DIR]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "${SCRIPT_DIR}")" != "scripts" ]; then
  echo "ERROR: place this script in <project-root>/scripts/ and run it from there." >&2
  exit 1
fi
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
LOG_DIR="${PROJECT_ROOT}/logs/gate06"
RAW_DIR="${LOG_DIR}/raw"
TS="$(date +%Y%m%d-%H%M%S)"
TAG="inventory"; [ -n "${TREE}" ] && TAG="treescan"
LOG_FILE="${LOG_DIR}/gate06_${TAG}_${TS}.log"
RAW_FILE="${RAW_DIR}/gate06_${TAG}_${TS}.raw.log"
TSV_FILE="${LOG_DIR}/gate06_${TAG}_files_${TS}.tsv"
MANIFEST="${RAW_DIR}/gate06_${TAG}_${TS}.sha256"
mkdir -p "${LOG_DIR}" "${RAW_DIR}" && chmod 755 "${LOG_DIR}" && chmod 700 "${RAW_DIR}"
TMPD="$(mktemp -d)"; trap 'rm -rf "${TMPD}"' EXIT

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

section() { printf '\n===== %s =====\n' "$1"; }

# ---- scanner (Python, standard library) -------------------------------------
cat > "${TMPD}/scan.py" <<'PYEOF'
import gzip, hashlib, ipaddress, os, re, sys
root, out_tsv = sys.argv[1], sys.argv[2]
files = [l.rstrip("\n") for l in sys.stdin if l.strip()]
home, user = os.environ["SCAN_HOME"], os.environ["SCAN_USER"]
hosts = [h for h in (os.environ.get("SCAN_HOST_S", ""), os.environ.get("SCAN_HOST_F", "")) if h]
wb = lambda s: re.compile(r"(?<![A-Za-z0-9_.-])" + re.escape(s) + r"(?![A-Za-z0-9_-])")
RX = {
    "home": re.compile(re.escape(home) + r"|/home/[A-Za-z0-9._-]+"),
    "user": wb(user) if user else None,
    "host": [wb(h) for h in hosts],
    "email": re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})"),
    "signed": re.compile(r"(https?://([^/\s\"'<>]+)[^\s\"'<>]*[?&](X-Amz-[A-Za-z]+|Signature|Expires|AWSAccessKeyId|token|access_token|sig|se|sp|sv|sr|response-content-disposition)=)", re.I),
    "secret": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{10,}|Authorization:\s*\S+|(?<![A-Za-z])password\s*[:=]\s*\S+", re.I),
    "ipv4": re.compile(r"(?<![0-9.])((?:[0-9]{1,3}\.){3}[0-9]{1,3})(?![0-9.])"),
    "ipv6": re.compile(r"(?<![0-9A-Za-z:])[0-9A-Fa-f:]{3,39}(?![0-9A-Za-z:])"),
    "mac": re.compile(r"(?<![0-9A-Fa-f:])((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})(?![0-9A-Fa-f:])"),
    "ph_email": re.compile(r"<EMAIL>"),
    "tz": re.compile(r"\+0900|\bJST\b"),
    "ansi": re.compile(r"\x1b\["),
}
BLOCK = ("home", "user", "host", "email", "signed", "secret", "big100")
REVIEW = ("ipv4", "ipv6", "mac", "ph_email", "big50")
tot = {}
details = {}
rows = []
def add(f, k, n=1, note=None):
    if n <= 0: return
    tot[k] = tot.get(k, 0) + n
    d = details.setdefault(f, {}); d[k] = d.get(k, 0) + n
    if note: details.setdefault(("notes", f), set()).add(f"{k}: {note}")
def cls(p):
    if p.endswith(".gz"): p = p[:-3]
    if "/as-run/" in p: return "as-run"
    if p.startswith("scripts/"): return "script"
    if p.endswith((".svg", ".png")): return "figure"
    if p.endswith(".md"): return "record"
    if p.endswith(".log"): return "log"
    if p.endswith(".dts"): return "dts"
    if p.endswith((".txt", ".tsv")) or os.path.basename(p) == "SHA256SUMS": return "list"
    return "other"
for p in files:
    full = os.path.join(root, p)
    data = open(full, "rb").read()
    size = len(data); sha = hashlib.sha256(data).hexdigest()
    if size > 100 * 1024 * 1024: add(p, "big100")
    elif size > 50 * 1024 * 1024: add(p, "big50")
    if p.endswith(".gz"):
        try: data = gzip.decompress(data)
        except OSError: add(p, "secret", 1, "unreadable .gz - check by hand"); data = b""
    if b"\x00" not in data[:8192]:
        t = data.decode("utf-8", "replace")
        add(p, "home", len(RX["home"].findall(t)))
        if RX["user"]: add(p, "user", len(RX["user"].findall(t)))
        for h in RX["host"]: add(p, "host", len(h.findall(t)))
        for m in RX["email"].finditer(t): add(p, "email", 1, "domain " + m.group(1))
        for m in RX["signed"].finditer(t): add(p, "signed", 1, "host " + m.group(2) + " param " + m.group(3))
        add(p, "secret", len(RX["secret"].findall(t)))
        for m in RX["ipv4"].finditer(t):
            v = m.group(1)
            try: ip = ipaddress.ip_address(v)
            except ValueError: continue
            if v in ("127.0.0.1", "0.0.0.0"): continue
            if v.startswith("10.0.2."): add(p, "ipv4", 1, "QEMU user-net 10.0.2.x")
            elif ip.is_private: add(p, "ipv4", 1, "private " + ".".join(v.split(".")[:2]) + ".x.x")
            else: add(p, "ipv4", 1, "public/other x.x.x.x (possibly a version string)")
        for m in RX["ipv6"].finditer(t):        # candidates, validated: times, MACs, PCI ids are not valid IPv6
            v = m.group(0)
            if v.count(":") < 2: continue
            try: ip6 = ipaddress.IPv6Address(v)
            except ValueError: continue
            add(p, "ipv6", 1, "link-local fe80::/10" if ip6.is_link_local else "loopback ::1" if ip6.is_loopback else
                ("documentation 2001:db8::/32" if v.lower().startswith("2001:db8") else "other (prefix " + v.split(":")[0].lower() + ":...)"))
        for m in RX["mac"].finditer(t):
            v = m.group(1).lower()
            add(p, "mac", 1, "QEMU OUI 52:54:00" if v.startswith("52:54:00") else "other OUI " + v[:8])
        if cls(p) in ("log", "dts", "record", "list"):     # scripts contain "<EMAIL>" in their own sanitizers
            add(p, "ph_email", len(RX["ph_email"].findall(t)))
        add(p, "tz", len(RX["tz"].findall(t)))
        add(p, "ansi", len(RX["ansi"].findall(t)))
    d = details.get(p, {})
    rows.append((p, size, sha, cls(p), sum(d.get(k, 0) for k in BLOCK), sum(d.get(k, 0) for k in REVIEW)))
with open(out_tsv, "w") as fh:
    fh.write("path\tbytes\tsha256\tclass\tblockers\treview\n")
    for r in rows: fh.write("\t".join(map(str, r)) + "\n")
print(f"candidates: {len(rows)} files, {sum(r[1] for r in rows)/1048576:.1f} MiB")
by = {}
for r in rows: by.setdefault(r[3], [0, 0]); by[r[3]][0] += 1; by[r[3]][1] += r[1]
for c, (n, s) in sorted(by.items()): print(f"  {c:<8} {n:4d} files {s/1048576:8.2f} MiB")
def section(title, keys):
    print(f"\n-- {title} --")
    any_ = False
    for k in keys:
        print(f"  {k:<9} {tot.get(k, 0)}")
    for r in rows:
        d = details.get(r[0], {})
        hit = {k: d[k] for k in keys if d.get(k)}
        if hit:
            any_ = True
            print(f"  {r[0]}: " + ", ".join(f"{k}={v}" for k, v in hit.items()))
            for n in sorted(details.get(("notes", r[0]), set())):
                if n.split(":")[0] in keys: print(f"      {n}")
    if not any_: print("  (none)")
section("BLOCKER findings (must be 0)", BLOCK)
section("REVIEW findings (decide one by one)", REVIEW)
print("\n-- INFO --")
for k in ("tz", "ansi"):
    files_k = [r[0] for r in rows if details.get(r[0], {}).get(k)]
    print(f"  {k:<5} {tot.get(k, 0)} occurrences in {len(files_k)} files")
b = sum(tot.get(k, 0) for k in BLOCK); rv = sum(tot.get(k, 0) for k in REVIEW)
print(f"\nSUMMARY blockers={b} review={rv}")
PYEOF

{
  section "0. Meta"
  echo "Gate        : 06 leak scan (read-only)  mode: ${TREE:+tree ${TREE}}${TREE:-project (inventory)}"
  echo "Timestamp   : ${TS}"
  echo "Script      : scripts/$(basename "${SCRIPT_PATH}")  sha256=$(sha256sum "${SCRIPT_PATH}" | cut -d' ' -f1)"
  cd "${PROJECT_ROOT}" || exit 1

  SCAN_ROOT="${PROJECT_ROOT}"
  if [ -n "${TREE}" ]; then
    section "1. Files of the assembled tree '${TREE}'"
    SCAN_ROOT="${PROJECT_ROOT}/${TREE}"
    [ -d "${SCAN_ROOT}" ] || { echo "[NG]   ${TREE} not found"; exit 1; }
    ( cd "${SCAN_ROOT}" && find . -type f -print | sed 's#^\./##' | sort ) \
      | grep -vxE 'scripts/gate06_(inventory|publish)\.sh' > "${TMPD}/candidates.txt"
    echo "files in the tree    : $(find "${SCAN_ROOT}" -type f | wc -l)"
    echo "raw logs in the tree : $(find "${SCAN_ROOT}" -path '*/raw/*' -type f | wc -l) (must be 0)"
    echo "checkpoints in tree  : $(find "${SCAN_ROOT}" -type f -iname '*checkpoint*' | wc -l) (must be 0)"
  else
    section "1. Candidates and exclusions"
    { find logs -path '*/raw' -prune -o -type f -print 2>/dev/null | grep -E '^logs/gate[0-9]' | grep -viE 'checkpoint' | grep -v '^logs/gate06/'
      find scripts -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null
      find . -maxdepth 1 -type f -name 'README*' 2>/dev/null | sed 's#^\./##'
      find docs -type f 2>/dev/null
    } | sort -u | grep -vxE 'scripts/gate06_(inventory|publish)\.sh' > "${TMPD}/candidates.txt"
    echo "excluded raw files   : $(find logs -path '*/raw/*' -type f 2>/dev/null | wc -l) (never published)"
    echo "excluded checkpoints : $(find logs -type f -iname '*checkpoint*' 2>/dev/null | wc -l) (never published)"
    echo "excluded gate06 logs : this gate's own logs are not scanned"
  fi
  echo "not scanned          : scripts/gate06_inventory.sh, scripts/gate06_publish.sh (they contain the patterns by design; both are published)"

  section "2. Leak scan of the candidates"
  SCAN_HOME="${HOME}" SCAN_USER="${U_NAME}" SCAN_HOST_S="${H_SHORT}" SCAN_HOST_F="${H_FQDN}" \
    python3 "${TMPD}/scan.py" "${SCAN_ROOT}" "${TSV_FILE}" < "${TMPD}/candidates.txt"
  echo "per-file list (path, bytes, sha256, class, counts): logs/gate06/$(basename "${TSV_FILE}")"

  section "3. Repository settings"
  if [ -f .gitignore ]; then
    for pat in 'work/' 'logs/**/raw/' 'logs/**/G*_checkpoint.md'; do
      grep -qxF "${pat}" .gitignore && echo "[OK]   .gitignore contains ${pat}" || echo "[WARN] .gitignore does not contain ${pat}"
    done
  else
    echo "[WARN] no .gitignore in the project root"
  fi
  if git -C "${PROJECT_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[INFO] the project directory is already a git repository"
  else
    echo "[INFO] the project directory is not a git repository yet"
  fi
  for scope in --global --local; do
    e="$(git -C "${PROJECT_ROOT}" config "${scope}" --get user.email 2>/dev/null)"
    if [ -z "${e}" ]; then echo "[INFO] git ${scope#--} user.email: not set"
    elif printf '%s' "${e}" | grep -q '@users\.noreply\.github\.com$'; then echo "[OK]   git ${scope#--} user.email: GitHub noreply address"
    else echo "[WARN] git ${scope#--} user.email: NOT a GitHub noreply address (value not shown)"; fi
  done
  section "9. Summary"
  echo "This step is read-only. Findings are decided in G06-2 / G06-3."
  echo "Next            : upload logs/gate06/$(basename "${LOG_FILE}"), the .tsv next to it, and the .sha256 manifest"
} 2>&1 | tee -i "${RAW_FILE}" | sanitize_stream | tee -i "${LOG_FILE}"
STATUS=${PIPESTATUS[0]}
chmod 600 "${RAW_FILE}"; chmod 644 "${LOG_FILE}" "${TSV_FILE}" 2>/dev/null
( cd "${PROJECT_ROOT}" && sha256sum "${RAW_FILE#"${PROJECT_ROOT}"/}" "${LOG_FILE#"${PROJECT_ROOT}"/}" "${TSV_FILE#"${PROJECT_ROOT}"/}" "${SCRIPT_PATH#"${PROJECT_ROOT}"/}" > "${MANIFEST}" && chmod 600 "${MANIFEST}" )
echo
echo "Sanitized log   : ${LOG_FILE#"${PROJECT_ROOT}"/}"
echo "Candidate list  : ${TSV_FILE#"${PROJECT_ROOT}"/}"
echo "sha256 manifest : ${MANIFEST#"${PROJECT_ROOT}"/}"
exit "${STATUS}"
