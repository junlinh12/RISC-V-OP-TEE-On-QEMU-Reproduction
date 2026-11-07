# G00 — Host Baseline (Development Environment & Compute Resources)

| Item | Value |
|---|---|
| Project | RISC-V-OP-TEE-On-QEMU-Reproduction |
| Target | https://gitlab.com/riseproject/riscv-optee |
| Date | 2026-11-05 |
| Result | **Conditional PASS** (see §1.1) |
| Log | `logs/gate00/gate00_env_check_20261105-211827.log` |
| Revised | 2026-11-07, for publication (G06): result wording, sanitization scope, outcome of the open items |

A Japanese version of this document is available as `G00_host_baseline.ja.md`.

## 1. Goal

Before starting the reproduction, confirm that the host provides the tools and compute resources the build needs, and create the project directory skeleton.

### 1.1 Why "conditional"

The host itself met every requirement, but the evidence for this gate is weaker than for the later gates:

- The log was produced by the first version of the script. That version did not yet record an exit code for each command, did not keep a raw (unsanitized) log, and did not run with `pipefail`. These were introduced from G01 on, after an external review.
- The script's hash was not recorded at run time. The `scripts/gate00_env_check.sh` in this repository is a later revision that only adds project-root detection; it is **not** claimed to be the exact version that produced the log.
- The check was not repeated, because the later gates (G01–G05) exercised the same host successfully.

## 2. Steps

### Step 1. Place the script

If you cloned this repository, `scripts/gate00_env_check.sh` is already in place and you can skip this step. If you obtained the script separately:

```bash
mkdir -p ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction/scripts
cp <download-dir>/gate00_env_check.sh ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction/scripts/
```

### Step 2. Run the environment check

```bash
cd ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction
bash scripts/gate00_env_check.sh
```

What the script does:

- It is read-only: it installs nothing and changes no system settings.
- Its output passes through a sanitizer before it is written to `logs/gate00/`. The sanitizer masks the home path, user name, host name, IPv4 and MAC addresses, and e-mail addresses; it does not cover every possible identifier. All published logs were therefore scanned again before publication (G06-1).
- On the first run it creates `logs/`, `scripts/` and `work/`.

### Step 3. Review the log

```bash
cat logs/gate00/*.log
```

## 3. Results

| Category | Observed value | Verdict |
|---|---|---|
| OS | Ubuntu 24.04.5 LTS | OK |
| Kernel | Linux 7.0.0-38-generic x86_64 | OK |
| Machine type | Bare metal (`systemd-detect-virt`: none) | OK |
| CPU | Intel Core Ultra 7 265K, 20 threads | OK |
| RAM | 30 GiB total (10 GiB available and 5.7 GiB swap in use at check time) | OK (see finding 4) |
| Disk | 461 GiB free (ext4), 8% inodes used | OK |
| Build tools | All 24 checked tools present (gcc/g++ 13.3.0, make 4.3, git 2.43.0, Python 3.12.3, perl 5.38.2, cmake 3.28.3, ninja 1.11.1, dtc 1.7.0, ...) | OK |
| Debian packages | All 16 checked packages installed | OK |
| Buildroot environment | No issues with PATH / LD_LIBRARY_PATH / PERL_MM_OPT; no whitespace in the build path | OK |
| QEMU console ports | 64320 and 64321 are free | OK |
| git user.email | Not a GitHub noreply address | **WARN** |
| System QEMU | qemu-system-riscv64 8.2.2 (Ubuntu package) | Info (not used; see §6) |

## 4. Findings

1. No additional packages need to be installed.
2. The upstream build instructions require `CMAKE_POLICY_VERSION_MINIMUM=3.5` only when CMake is newer than 3.30. This host has CMake 3.28.3, so the workaround is not expected to be needed.
3. The system QEMU 8.2.2 is not expected to be used. Buildroot is expected to build the RISE QEMU fork (with WorldGuard support). Which QEMU binary the start script launches is confirmed in G01.
4. Total memory is sufficient, but 20 GiB was in use and 5.7 GiB of swap was occupied at check time. Before the G02 build, check for leftover processes (for example, QEMU instances from other projects).
5. `git user.email` is not a noreply address. Before publishing (G06), set a noreply address for this repository only; the global setting stays unchanged.
6. `ulimit -n 1024` and `umask 0002` are not expected to cause Buildroot problems. They will be revisited only if a related error appears.

## 5. Project conventions established in G00

- Project location: `~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction`
- Directory layout:
  - `logs/`: the single log location for the project (one project, one log system)
  - `scripts/`: reproduction scripts
  - `work/`: sources and build output (not published)
  - `docs/`: created in the final gate
- Gates are numbered with two digits (G00, G01, ...).
- Each gate record is named after its content: `G<NN>_<topic>.md`.
- Host-specific paths and tool availability are never assumed; only values confirmed in the G00 log or provided by the user are used.

## 6. Open items and how they were resolved

| Due | Item | Outcome |
|---|---|---|
| G01 | Identify which QEMU binary is used (Buildroot-built or system) | Resolved: `start-qemu.sh` puts the Buildroot host directory first in `PATH`. G03 verified at run time that the Buildroot-built RISE QEMU 10.1.93 is used. |
| Before G02 | Check memory usage and stop unneeded processes | Resolved in G02 (`gate02_memory_check.sh`); the M1 build ran with 20 jobs. Later builds in G05 were limited to 2 jobs, at the user's request, to avoid running out of memory. |
| Before G06 | Set a repository-local noreply `git user.email` | Handled when the repository is created (G06-4); the global setting stays unchanged. |

## 7. Summary

The host (Ubuntu 24.04.5, 20 CPU threads, 30 GiB RAM, 461 GiB free disk) has every required tool and package, so no installation was needed, and the CMake workaround was not necessary (confirmed by the G02 build). The result is a conditional PASS only because this first log predates the logging safeguards used from G01 on (§1.1). The open items were resolved in later gates (§6).
