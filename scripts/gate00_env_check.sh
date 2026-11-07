#!/usr/bin/env bash
# =============================================================================
#  Gate 00 : Host environment & compute-resource check
#  Project : RISC-V-OP-TEE-On-QEMU-Reproduction
#  Target  : https://gitlab.com/riseproject/riscv-optee
#
#  - Read-only check: installs nothing and changes no system settings.
#  - Every line written to the log passes through sanitize() first
#    (home path / user name / host name / IPv4 / MAC / e-mail are masked).
#  - Creates logs/ and work/ under the project root if they do not exist yet.
#
#  Usage : bash scripts/gate00_env_check.sh   (from the project root)
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "${SCRIPT_DIR}")" != "scripts" ]; then
  echo "ERROR: place this script in <project-root>/scripts/ and run it from there." >&2
  exit 1
fi
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"   # works wherever the repository is cloned
LOG_DIR="${PROJECT_ROOT}/logs/gate00"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/gate00_env_check_${TS}.log"

# ---- project skeleton (exactly one "logs" folder per project) -------
mkdir -p "${LOG_DIR}" "${PROJECT_ROOT}/scripts" "${PROJECT_ROOT}/work"

# ---- sanitizer --------------------------------------------------------------
U_NAME="$(id -un)"
H_SHORT="$(hostname -s 2>/dev/null || true)"
H_FQDN="$(hostname -f 2>/dev/null || true)"
esc() { printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|#]/\\&/g'; }

SED_ARGS=(-E -e "s#$(esc "${HOME}")#<HOME>#g")
[ -n "${H_FQDN}" ]  && SED_ARGS+=(-e "s#\\b$(esc "${H_FQDN}")\\b#<HOST>#g")
[ -n "${H_SHORT}" ] && SED_ARGS+=(-e "s#\\b$(esc "${H_SHORT}")\\b#<HOST>#g")
[ -n "${U_NAME}" ]  && SED_ARGS+=(-e "s#\\b$(esc "${U_NAME}")\\b#<USER>#g")
SED_ARGS+=(
  -e 's#([0-9]{1,3}\.){3}[0-9]{1,3}#<IPv4>#g'
  -e 's#([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}#<MAC>#g'
  -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}#<EMAIL>#g'
)
sanitize() { sed "${SED_ARGS[@]}"; }

# ---- helpers ----------------------------------------------------------------
section() { printf '\n===== %s =====\n' "$1"; }
run()     { printf '$ %s\n' "$1"; bash -c "$1" 2>&1; }
ver() {
  case "$1" in
    perl)         perl -e 'print "perl $^V\n"' ;;
    unzip)        unzip -v 2>&1 | head -n1 ;;
    bzip2|telnet) echo "(installed)" ;;
    *)            "$1" --version </dev/null 2>&1 | head -n1 ;;
  esac
}
judge() { if [ "$1" -ge "$2" ]; then echo OK; elif [ "$1" -ge "$3" ]; then echo WARN; else echo NG; fi; }

{
  section "0. Meta"
  echo "Gate        : 00 (Host environment & compute-resource check)"
  echo "Timestamp   : ${TS}"
  echo "ProjectRoot : ${PROJECT_ROOT}"

  section "1. OS / Kernel"
  run '. /etc/os-release && echo "${PRETTY_NAME}"'
  run 'uname -srm'
  run 'systemd-detect-virt || true'

  section "2. CPU"
  run 'nproc'
  run 'lscpu | grep -E "^(Architecture|Model name|CPU\(s\)|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)|Virtualization):"'

  section "3. Memory"
  run 'free -h'

  section "4. Disk (filesystem of \$HOME)"
  run 'df -hT "$HOME"'
  run 'df -i "$HOME"'

  section "5. Host tools"
  for t in gcc g++ make git python3 perl cmake ninja dtc rsync bc cpio unzip wget \
           file patch gzip bzip2 tar flex bison pkg-config telnet qemu-system-riscv64; do
    if command -v "$t" >/dev/null 2>&1; then
      printf '[OK]   %-20s %s\n' "$t" "$(ver "$t")"
    else
      printf '[MISS] %-20s\n' "$t"
    fi
  done

  section "6. Debian packages"
  for p in build-essential git rsync bc cpio unzip wget file patch perl python3 \
           libncurses-dev libssl-dev device-tree-compiler telnet inetutils-telnet; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then
      printf '[OK]   %s\n' "$p"
    else
      printf '[MISS] %s\n' "$p"
    fi
  done

  section "7. Buildroot sanity (environment)"
  case ":${PATH}:" in
    *::*|*:.:*) echo "[WARN] PATH contains an empty or '.' entry (Buildroot refuses this)" ;;
    *)          echo "[OK]   PATH has no empty/'.' entry" ;;
  esac
  if printf '%s' "${PATH}" | grep -q '[[:space:]]'; then
    echo "[WARN] PATH contains whitespace"
  else
    echo "[OK]   PATH has no whitespace"
  fi
  case ":${LD_LIBRARY_PATH:-}:" in
    ::)          echo "[OK]   LD_LIBRARY_PATH not set" ;;
    *::*|*:.:*)  echo "[WARN] LD_LIBRARY_PATH contains an empty or '.' entry" ;;
    *)           echo "[INFO] LD_LIBRARY_PATH is set" ;;
  esac
  if [ -n "${PERL_MM_OPT:-}" ]; then echo "[WARN] PERL_MM_OPT is set"; else echo "[OK]   PERL_MM_OPT not set"; fi
  case "${PROJECT_ROOT}/work" in
    *[[:space:]]*) echo "[WARN] build dir path (work/) contains whitespace" ;;
    *)             echo "[OK]   build dir path (work/) has no whitespace" ;;
  esac
  echo "umask       : $(umask)"
  echo "LANG        : ${LANG:-unset}"
  echo "ulimit -n   : $(ulimit -n)"

  section "8. QEMU console ports (64320 / 64321)"
  if ss -ltn 2>/dev/null | grep -Eq ':(64320|64321)[[:space:]]'; then
    echo "[WARN] port 64320 or 64321 is already in use"
  else
    echo "[OK]   ports 64320 / 64321 are free"
  fi

  section "9. Git identity (privacy check before GitHub upload)"
  GE="$(git config --global user.email 2>/dev/null || true)"
  if   [ -z "${GE}" ]; then
    echo "[INFO] git user.email is not set"
  elif printf '%s' "${GE}" | grep -q '@users\.noreply\.github\.com$'; then
    echo "[OK]   git user.email is a GitHub noreply address"
  else
    echo "[WARN] git user.email is NOT a noreply address (value not shown)"
  fi

  section "10. Existing projects under ~/projects"
  ls -1 "${HOME}/projects" 2>/dev/null || echo "(none)"

  section "11. Resource summary"
  CPU_N="$(nproc)"
  MEM_G="$(awk '/^MemTotal:/{printf "%.0f", $2/1048576}' /proc/meminfo)"
  DISK_G="$(df -BG --output=avail "${HOME}" | tail -n1 | tr -dc '0-9')"
  printf '[%s] CPU threads : %s  (>=8 recommended; fewer only means slower)\n' "$(judge "${CPU_N}" 8 4)" "${CPU_N}"
  printf '[%s] RAM (GiB)   : %s  (>=15 recommended, >=8 minimum)\n'          "$(judge "${MEM_G}" 15 8)" "${MEM_G}"
  printf '[%s] Free disk   : %s GiB on $HOME  (>=50 recommended, >=30 minimum)\n' "$(judge "${DISK_G}" 50 30)" "${DISK_G}"
} 2>&1 | sanitize | tee "${LOG_FILE}"

echo
echo "Sanitized log saved to: ${LOG_FILE#"${PROJECT_ROOT}"/}"
