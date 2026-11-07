# G01 — Source Acquisition & Version Pinning

| Item | Value |
|---|---|
| Project | RISC-V-OP-TEE-On-QEMU-Reproduction |
| Baseline | RISE RP016 Milestone 1 (`rp016_m1`) |
| Date | 2026-11-06 |
| Result | **PASS** (0 failed commands) |
| Script | `scripts/gate01_fetch_sources.sh` (sha256 `ad843b3352e00e5786b125dce7aa95441092ac34508658b04342e84c24cee7ae`) |
| Log | `logs/gate01/gate01_fetch_sources_20261106-192647.log` |
| Revised | 2026-11-07, for publication (G06): boot-chain description, reproducibility wording, outcome of the notes for later gates |

A Japanese version of this document is available as `G01_source_pinning.ja.md`.

## 1. Goal

Obtain the Buildroot umbrella project and identify, for every component, where its source comes from, which branch or version it uses, and which exact commit that resolves to. Nothing is built in this gate.

## 2. Steps

### Step 1. Run the survey script

```bash
cd ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction
bash scripts/gate01_fetch_sources.sh
```

The script does the following:

- Records the remote branches of all seven repositories in the RISE `riscv-optee` group.
- Clones Buildroot (`rp016_m1`) into `work/buildroot`. On later runs the existing clone is reused.
- Resolves every branch name referenced by the defconfig to a commit SHA.
- Runs `make qemu_riscv64_virt_optee_defconfig` and `make printvars`. Both are configuration steps only; no package is downloaded or built.
- Prints the source-override mechanism (`local.mk`) and the QEMU start-script sources.

Logging works as follows:

- Every command records its exit code (`[rc=N]`). The script ends with a failure count, a verdict, and a non-zero exit status if anything failed.
- `pipefail` is enabled, so a failure inside the logging pipeline is not hidden.
- The publishable log is sanitized (home path, user name, host name, IPv4/MAC addresses, e-mail addresses are masked).
- The unmasked raw log is kept locally in `logs/gate01/raw/` and is never published. A sha256 manifest next to it covers the raw log, the sanitized log, the branch list, and the script itself.

### Step 2. Review the result

```bash
LOG="$(ls -t logs/gate01/gate01_fetch_sources_*.log | head -n 1)"
grep -nE '^\[rc=[1-9]|\[NG\]' "$LOG"        # no output = no failures
sed -n '/===== 9. Summary/,$p' "$LOG"
```

To verify the integrity of the logs and the script (local only):

```bash
sha256sum -c logs/gate01/raw/gate01_fetch_sources_<timestamp>.sha256
```

### Run history

| Run | Script change | Outcome |
|---|---|---|
| 2026-11-05 21:48 | First version | Start-script search too broad; QEMU and OP-TEE user-space versions not resolved |
| 2026-11-05 21:58 | Sections 6 and 7 rewritten | Revealed the `custom/` source overrides; `.config` path still wrong |
| 2026-11-06 19:26 | Section 6b added, `.config` path fixed, exit-code recording, raw log + sha256 manifest | **Final: all completion conditions met** |

Only the final run is authoritative. The raw output of the first two runs was not preserved, because they masked their output on the fly.

## 3. Results

### 3.1 Buildroot fork

| Item | Value |
|---|---|
| Repository | https://gitlab.com/riseproject/riscv-optee/buildroot.git |
| Branch | `rp016_m1` |
| Commit | `d7204671a32ca2edc521c35de758ce650ebf1cb6` (2025-12-15, "make: point all repos to RISE Gitlab") |
| Base | Appears to be the upstream Buildroot 2025.05 release commit (`fcde5363aa`, 2025-06-09). `git describe` reports `2024.08-3681-…` only because later upstream tags are not present in the fork. |

Lineage of `rp016_m1`:

- **Andes work (2025-06-22/23)**: adds the `riscv64-virt-optee` board and defconfig. The BSP versions are then bumped up to v6, ending at commit `21c6de2d77`. That commit is the tip of the `dev-optee-mpxy-v6` branch.
- **RISCstar commits (2025-12-01 to 2025-12-15)**: six commits on top. They point the components to git repositories, add `local.mk` (local source overrides), add the bare-metal application build, and finally switch all URLs to the RISE GitLab.

### 3.2 Component sources and pinning strategy

| Component | Acquisition path | Ref | Commit (2026-11-06) | Pinning method (applied in G02) |
|---|---|---|---|---|
| Buildroot | `git clone` | `rp016_m1` | `d7204671a32ca2edc521c35de758ce650ebf1cb6` | Already pinned by the clone; verify HEAD |
| Linux | Buildroot custom git (`BR2_LINUX_KERNEL_CUSTOM_REPO_*`) | `rp016_m1` | `2912ca616fc806dbeeba2e1ac7a157e0843d6987` | Set the version to the SHA in `.config` after applying the defconfig |
| U-Boot | Buildroot custom git (`BR2_TARGET_UBOOT_CUSTOM_REPO_*`) | `rp016_m1` | `32bdb252fab83028768a269fb304b9356547ccbd` | Same as Linux |
| OpenSBI | `local.mk` override → `custom/opensbi` | `rp016_m1` | `cdd401f1517b4599b7d08ce13cd83859acc4cbb2` | Pre-seed `custom/opensbi` with a local branch `rp016_m1` at the SHA |
| OP-TEE OS | `local.mk` override → `custom/optee-os` | `rp016_m1` | `814978eb15b92c3b97255a8c000f44cd84aac008` | Same as OpenSBI |
| QEMU (host) | `local.mk` override → `custom/qemu` | `rp016_m1` | `9c23f2a7b0b45277693a14074b1aaa827eecdb92` | Same as OpenSBI |
| bm-app | `local.mk` finalize hook → `custom/bm-app` | `rp016_m1` | `97545c35a74ad387f7790b02a35b0f2b4d29bb6e` | Same as OpenSBI |
| optee_client / optee_test / optee_examples | Upstream GitHub tarballs | `4.6.0` | — | Fixed by version and checked by Buildroot hash files |
| Toolchain | Bootlin pre-built tarball | `riscv64-lp64d--glibc--bleeding-edge-2024.05-1` | — | Fixed by version and checked by Buildroot hash files |

Other resolved settings: kernel headers are at least 5.15. On the target, `tee-supplicant` uses `/data/tee`, and RPMB emulation is enabled.

### 3.3 The `local.mk` override mechanism

Buildroot reads `local.mk` from the top of the tree (the default `BR2_PACKAGE_OVERRIDE_FILE`). For QEMU, OpenSBI and OP-TEE OS, the file does two things:

- It sets `<PKG>_OVERRIDE_SRCDIR` to `custom/<name>`.
- It registers a pre-rsync hook `PREPARE_GIT_TREE`, which runs:
  1. `git clone --recursive <url>` if the directory has no `.git`; otherwise `git fetch --all --tags`.
  2. `git checkout <branch>`
  3. `git submodule update --init --recursive`

bm-app is prepared the same way, but from `TARGET_FINALIZE_HOOKS`. The same hooks then build it and generate `start-qemu-bm.sh`.

Consequences for reproducibility:

1. **The defconfig versions of OpenSBI and OP-TEE OS are not used.** `BR2_TARGET_OPENSBI_CUSTOM_REPO_VERSION` and `BR2_TARGET_OPTEE_OS_CUSTOM_REPO_VERSION` are bypassed. With an override, Buildroot does not download, extract or patch the package. Only the branch in `local.mk` matters.
2. **The hook runs on every rsync and re-checks out the branch *name*.** Therefore a commit checked out manually (detached HEAD) is silently replaced at the next build. On the other hand, `git fetch` does not move an existing local branch. This is why pre-seeding a local branch `rp016_m1` at the pinned SHA gives a stable pin without editing `local.mk`.
3. **The hooks need network access at build time.** They run `git clone` / `git fetch` against gitlab.com.
4. **The `custom/` directories do not exist before the first build.** This is by design: the hooks create them.
5. **The host-qemu configure wrapper changes only the build copy.** It unsets `GIT_DIR` inside `output/build/host-qemu-custom`, not in `custom/qemu`. No destructive commands (such as `rm -rf`) appear in `local.mk`.

### 3.4 QEMU start scripts

Two start scripts are generated at build time:

- **`output/images/start-qemu.sh`**: generated by `board/qemu/post-image.sh`. It is built from the command line tagged `# qemu_riscv64_virt_optee_defconfig` in `board/qemu/riscv64-virt-optee/readme.txt` and the template `board/qemu/start-qemu.sh.in`.
- **`output/images/start-qemu-bm.sh`**: generated by `local.mk` for the bare-metal application. It boots `fw_jump.bin` and `bm-app.elf`, and puts the serial port and the QEMU monitor on the local terminal (`-serial mon:stdio`).

Both scripts prepend Buildroot's `output/host/bin` to `PATH`. In `start-qemu.sh` this can be disabled with `--use-system-qemu`. As a result, the Buildroot-built QEMU is used, not the distribution's QEMU. If the Buildroot QEMU binary were missing, the scripts would silently fall back to the system QEMU, so its presence is verified after the build.

The main command line is:

```
qemu-system-riscv64 -M virt -cpu rv64,zkr=on -dtb qemu_rv64_virt_domain.dtb -m 4096 -smp 2
  -semihosting-config enable=on,target=native -serial tcp:127.0.0.1:64320,server
  -bios u-boot-spl -device loader,file=u-boot.itb,addr=0x80200000
  -device virtio-blk-device,drive=hd0 -drive format=raw,file=sdcard.img,id=hd0,if=none
  -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp::2200-:22 -nographic
```

What the main options mean:

- **Boot chain**: QEMU's generic loader (`-device loader`) places the FIT image `u-boot.itb`, which bundles OpenSBI, OP-TEE (`tee.bin`) and U-Boot proper, at `0x80200000` before the harts start. U-Boot SPL, started as the `-bios` firmware, reads that image from RAM (`CONFIG_SPL_RAM_DEVICE`) and copies each part to its load address. *(Corrected in revision: the first version said that SPL loads the image; it only reads the copy that QEMU has already placed in RAM. The FIT layout and the U-Boot settings were confirmed in G04.)*
- **Domains**: the DTB `qemu_rv64_virt_domain.dtb` comes from the Linux tree and carries the OpenSBI domain definitions (three domains, verified in G04).
- **Consoles**: OP-TEE prints through semihosting (`CFG_SEMIHOSTING_CONSOLE=y`) to the terminal that started QEMU. OpenSBI, U-Boot and Linux use the UART, which is exposed on TCP port 64320 on the loopback interface.
- **OP-TEE settings from the defconfig**: placed at `0xF1000000` with 16 MiB, 2 cores, 2 threads, PLIC and 16550 UART disabled.

### 3.5 Observations from the branch survey

- In `optee_os`, `opensbi` and `linux`, `rp016_m1` points to the same commit as Andes' `dev-optee-mpxy-v6`. In `u-boot`, it matches `dev-optee-mpxy-v5`. The RP016 M1 baseline is therefore the Andes MPXY-based OP-TEE stack (v6).
- In `buildroot`, `rp016_m1` and `rp016_m2` point to the same commit. The actual M2 work is on the `rp016_m2_aplic*` branches.
- In `qemu`, `rp016_m1` is identical to `master`. Only `rp016_m5` differs.
- The Andes series continues up to `dev-optee-mpxy-v9`.

## 4. Decisions

1. Pin every component by acquisition path, as listed in §3.2. Do not edit `local.mk` or the upstream defconfig.
2. The pinned SHAs equal the `rp016_m1` branch tips on 2026-11-06. The **sources** are therefore the ones the official instructions would have used on that date, and they stay the same if the branches move later. This pins sources, not binaries: host tools, downloaded tarballs (checked by Buildroot hash files) and the build environment can still differ, so the reproduction is source-level, not bit-for-bit. *(Revised: the first version claimed an identical build.)*
3. After the G02 build, verify that every `custom/*` checkout is at its pinned SHA and that Linux and U-Boot were fetched at their SHAs.

## 5. Notes for later gates

| Gate | Item | Outcome |
|---|---|---|
| G02 | Pin by the methods in §3.2, then verify the commits actually used. Expect large downloads, including the Linux history, and build-time network access by the `local.mk` hooks. | Done: all seven components were verified at their pinned SHAs after the build. |
| G03 | Confirm that `output/host/bin/qemu-system-riscv64` exists before booting (to rule out a silent fallback to the system QEMU). | Done: checked before every boot. |
| G03 | `hostfwd=tcp::2200-:22` listens on all host interfaces. Restrict it to `127.0.0.1` and record this as a documented deviation. | Done: every boot uses a local copy of the start script with `hostfwd=tcp:127.0.0.1:2200-:22`; the upstream script is not modified. |
| G03 | Semihosting cannot be removed, because the OP-TEE console depends on it. Run QEMU as an unprivileged user, and only with guests built from the pinned sources. | Done: the scripts refuse to run as root. |
| G04 | Verify the OpenSBI domain definitions in `qemu_rv64_virt_domain.dts`. | Done: three domains; the OP-TEE region is denied to the untrusted domain (enforcement demonstrated in G05a). |

## 6. Summary

All seven repositories have an `rp016_m1` branch. Every component's source and commit has been identified.

QEMU, OpenSBI, OP-TEE OS and bm-app are not taken from the defconfig. They come from `custom/` checkouts that `local.mk` creates at build time and re-checks out by branch name. They will therefore be pinned by pre-seeding local branches at the recorded SHAs. Linux and U-Boot will be pinned through `.config`.

The start scripts use the Buildroot-built QEMU. Two host-safety items (the SSH port forwarding and semihosting) were deferred to G03 and handled there (§5).
