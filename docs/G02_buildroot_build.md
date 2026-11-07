# G02 — Buildroot Build with Pinned Sources

| Item | Value |
|---|---|
| Project | RISC-V-OP-TEE-On-QEMU-Reproduction |
| Baseline | RISE RP016 Milestone 1 (`rp016_m1`), pinned to commit SHAs |
| Date | 2026-11-06 |
| Result | **PASS**: build completed and verified (0 failed commands) |
| Build time | 19 min 52 s (`make -j20`, 20 CPU threads) |
| Script | `scripts/gate02_build.sh` (sha256 `609db2e9747802d8b0e691d8918c932b8807d9702cb19dac585453921c1bada8`) |
| Log | `logs/gate02/gate02_build_20261106-205938.log` (full make output: `gate02_make_20261106-205938.log.gz`, see §3.5) |
| Revised | 2026-11-07, for publication (G06): non-fatal messages in the build log, scope of the verification, `sdcard.img` note, reproducibility wording, outcome of the notes for G03 |

A Japanese version of this document is available as `G02_buildroot_build.ja.md`.

## 1. Goal

Build every image with Buildroot from the commits recorded in G01. Record evidence that the sources actually used match those commits.

## 2. Steps

### Step 1 (optional). Check host memory

```bash
cd ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction
bash scripts/gate02_memory_check.sh
```

This script is read-only: it kills nothing, uses no `sudo`, and drops no cache. It reports:

- a breakdown of `/proc/meminfo`;
- the top processes by resident memory and by swap, grouped by program name;
- the memory charged to cgroups (your session, other users, system services);
- tmpfs usage.

Process owners appear only as `me` / `root` / `system` / `other-user`. Command lines are never printed.

### Step 2. Prepare (no compilation)

```bash
bash scripts/gate02_build.sh --prepare-only
```

This runs the pre-checks, pins the `custom/` checkouts, and writes the configuration. It stops before the build.

### Step 3. Build and verify

```bash
bash scripts/gate02_build.sh
```

Run the build inside `tmux` (or `screen`), so that a dropped SSH connection does not stop it. Steps 1–3 below are repeated quickly before the build starts.

What the script does:

1. **Pre-checks.** It verifies available memory (stops below 4 GiB) and free disk space (stops below 30 GiB). It also checks the `.gitignore` entries, that Buildroot `HEAD` equals the pinned SHA, that no tracked file in the Buildroot tree is modified, and the `local.mk` entries.
2. **Pin the `custom/` checkouts.** It clones QEMU, OpenSBI, OP-TEE OS and bm-app, then runs `git checkout -B rp016_m1 <pinned SHA>`. The `local.mk` hooks later run `git fetch` and `git checkout rp016_m1`. Because `git fetch` never moves a local branch, the pin holds without editing `local.mk`.
3. **Configure.** It applies the upstream `qemu_riscv64_virt_optee_defconfig`. It then sets `BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION` and `BR2_TARGET_UBOOT_CUSTOM_REPO_VERSION` to their SHAs with `utils/config` and runs `make olddefconfig`. This order matters: applying the defconfig again would reset the two versions.
4. **Build.** It runs `make -j$(nproc)`, as in the official instructions. The full output goes to a log file. The console shows only Buildroot `>>>` steps and `local.mk` `[BR]` messages, with timestamps.
5. **Verify.** It checks the commits actually used, the required artifacts with their sha256, and the Buildroot-built host QEMU.

### Step 4. Review the result

```bash
LOG="$(ls -t logs/gate02/gate02_build_*.log | head -n 1)"
grep -nE '^\[rc=[1-9]|\[NG\]' "$LOG"        # no output = no failures
sed -n '/===== 9. Summary/,$p' "$LOG"
```

### Run history

| Time | Run | Outcome |
|---|---|---|
| 20:20, 20:34 | `gate02_memory_check.sh` | Available memory 12.8–13.1 GiB. The largest consumer was a desktop web browser. No system service or other user was involved. |
| 20:43 | `gate02_build.sh --prepare-only` | PREPARED. Real Buildroot confirmed the pins (`LINUX_VERSION` / `UBOOT_VERSION` = SHAs; OpenSBI / OP-TEE OS / QEMU = `custom`). |
| 20:59 | `gate02_build.sh` | **BUILD COMPLETED AND VERIFIED**. 16 GiB was available at the start. |

## 3. Results

### 3.1 Commits actually used

| Component | Evidence | Commit |
|---|---|---|
| Buildroot | `git rev-parse HEAD` (pre-check) | `d7204671a32ca2edc521c35de758ce650ebf1cb6` |
| Linux | build directory `output/build/linux-<SHA>`, download `dl/linux/linux-<SHA>-git4.tar.gz` | `2912ca616fc806dbeeba2e1ac7a157e0843d6987` |
| U-Boot | build directory `output/build/uboot-<SHA>`, download `dl/uboot/uboot-<SHA>-git4.tar.gz` | `32bdb252fab83028768a269fb304b9356547ccbd` |
| QEMU (host) | `custom/qemu`: HEAD = local `rp016_m1` after the build | `9c23f2a7b0b45277693a14074b1aaa827eecdb92` |
| OpenSBI | `custom/opensbi`: HEAD = local `rp016_m1` after the build | `cdd401f1517b4599b7d08ce13cd83859acc4cbb2` |
| OP-TEE OS | `custom/optee-os`: HEAD = local `rp016_m1` after the build | `814978eb15b92c3b97255a8c000f44cd84aac008` |
| bm-app | `custom/bm-app`: HEAD = local `rp016_m1` after the build | `97545c35a74ad387f7790b02a35b0f2b4d29bb6e` |

During the build, every `local.mk` hook printed "dev tree exists. Fetching updates... Checking out rp016_m1". After the build, all four checkouts were still at their pinned SHAs, with no modified tracked files. This confirms that the pre-seeded local branch keeps the pin through the hooks.

**Scope of this verification.** For each checkout, `HEAD` and modified *tracked* files were checked. Submodule commits and untracked files were not recorded. *(Added in revision, following an external review.)*

The overridden packages were built in `output/build/host-qemu-custom`, `output/build/opensbi-custom` and `output/build/optee-os-custom`. The OP-TEE user-space packages (optee_client, optee_test, optee_examples) are version 4.6.0, from upstream tarballs checked against Buildroot's hash files.

### 3.2 Artifacts (`output/images`)

| File | Size (bytes) | sha256 |
|---|---:|---|
| `u-boot-spl` | 1,268,440 | `8758196e225812389df1eafe83875c0d6f988d0359ec71b25c0db1105bb06d9d` |
| `u-boot.itb` | 1,601,867 | `a5fde1f241b7308ecb189c699187c8c150ac0b1b27d98d7b55e1d977afb741a9` |
| `u-boot.bin` | 635,260 | `7068bd390cb098067a275f8975d938e3418e0a8000b93206a7bd5ead3594edfd` |
| `fw_dynamic.bin` | 273,120 | `10705fa71fd848c6c4c887f747ffeeead03614235933c0ba4fbecb489c3001f6` |
| `fw_dynamic.elf` | 1,747,648 | `9833f9b16b8fa0469722a84a01e6b5b81e9727e36cdd3ba3c7e24ca4d018ae06` |
| `fw_jump.bin` | 273,080 | `de9eabd5c9a89a5e92d696234555d2dae1fff8a925836d7cf66714f349eb2fef` |
| `fw_jump.elf` | 1,747,224 | `1d824dbeac50d71fcbc8265f0b158238112e601983ab9175c9c31d1b6da41715` |
| `tee.bin` | 696,880 | `2fe97c472ac8c05c07e6a959af501c0260fd76d5b6f27749a188844b69b4c360` |
| `Image` | 27,386,880 | `66e13d43d5071e1cc44245683c192d5f74534c9fa55f9b7c6fd463dbcaa3e8ef` |
| `qemu_rv64_virt_domain.dtb` | 6,907 | `6e1e8c35e2d2b610ceb69b783e7f96ab6bdf92778855fe4f541b02ebd3697294` |
| `rootfs.ext2` | 272,629,760 | `2f1d2e1e33876fc22e047564a0abf42142f30e9a8abd38ecf3e716391aa1d49c` |
| `rootfs.tar` | 134,717,440 | `7a9480377aa0075fc625c72a7c7b856e509884acfc5e0c638b4ca9620793a9cf` |
| `sdcard.img` | 272,630,272 | `cebd9fe83b05be19dfc1064a5736120067dc15501bbf64005f3b37bfdfc4f23b` (as built; changed later by the G03 boot, see note) |
| `bm-app.elf` | 17,592 | `99fac1d9a5f458e7baff9120638458ed5e8b5a8a379dbb93c73f3ba5eb583225` |
| `start-qemu.sh`, `start-qemu-bm.sh` | — | Not hashed: they embed the absolute host path of `output/host` |

The artifacts are not expected to be byte-identical across hosts or build dates, because they contain timestamps and paths. The hashes identify this particular build; they do not define a reproducibility target.

**Note on `sdcard.img`.** The G03 boot mounted the guest root file system read-write, without `-snapshot`, so `sdcard.img` changed afterwards (`dec31312…`). The other 13 artifacts were re-checked and were unchanged. All later boots (G05a–G05c) used QEMU `-snapshot` and verified that the image hash did not change.

### 3.3 Host QEMU

`output/host/bin/qemu-system-riscv64 --version` reports **QEMU emulator version 10.1.93**, built from `custom/qemu` at `9c23f2a7…`. The start scripts put `output/host/bin` first in `PATH`, so this binary, not the distribution QEMU (8.2.2), is used; G03 verified this at run time.

### 3.4 Resource usage

| Item | Value |
|---|---|
| `output/` | 19 GB |
| `dl/` (downloads) | 7.2 GB |
| `custom/` (git checkouts) | 4.4 GB |
| Available memory at build start | 16 GiB |

### 3.5 Non-fatal messages in the build output

`make` finished with exit status 0. The full output nevertheless contains messages that look like errors but did not stop the build:

- the primary download URL of zlib returned HTTP 404, and Buildroot fetched the tarball from its backup mirror (the tarball is checked by Buildroot's hash file);
- two errors that `make` reports as ignored.

The full make output is published as a cleaned, gzip-compressed copy (`gate02_make_20261106-205938.log.gz`): the query strings of the download URLs, which carry expiring signatures, the ANSI colour sequences and the time zone are removed. *(Added in revision.)*

## 4. Deviation from the official instructions

The official instructions build from branch names (`rp016_m1`). This reproduction builds from the commits those branches pointed to on 2026-11-06:

- The upstream `local.mk` and defconfig are not modified.
- Only `.config` (Linux, U-Boot) and the local branch of each `custom/` checkout are set to the SHAs.

The sources are therefore the ones the official instructions would have used on that date, and they stay the same after the branches move. This is a source-level reproduction, not a bit-for-bit one (see G01, §4). *(Revised: the first version claimed identical content.)*

## 5. Notes for G03

| Item | Plan | Outcome |
|---|---|---|
| SSH port forwarding | The generated `start-qemu.sh` contains `hostfwd=tcp::2200-:22`, which listens on all host interfaces. Launch from a local copy that binds `127.0.0.1` instead, and record the change. | Done in G03 and in every later boot. |
| SSH server in the guest | Check whether the root filesystem contains an SSH server at all. | Done: none is installed, so port 2200 leads nowhere. |
| Semihosting | Keep it, because the OP-TEE console depends on it. Run QEMU as an unprivileged user, only with this guest. | Done. |
| Consoles | OP-TEE prints through semihosting on the terminal running QEMU. OpenSBI, U-Boot and Linux use TCP port 64320, and QEMU waits for that connection before booting. Both consoles must be logged. | Done: both are logged separately. |

## 6. Summary

The full image set (U-Boot SPL / U-Boot FIT image, OpenSBI, OP-TEE OS, Linux, root filesystem, SD-card image, bare-metal test application) was built in about 20 minutes from the pinned commits. Every component was verified to have been built from its pinned commit. The Buildroot-built QEMU 10.1.93 is in place for the boot and `xtest` run in G03.
