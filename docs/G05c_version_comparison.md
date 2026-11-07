# G05c — Newer Stacks Compared with M1: Andes v9 and RISE RP022 M8

| Item | Value |
|---|---|
| Project | RISC-V-OP-TEE-On-QEMU-Reproduction |
| Date | 2026-11-07 |
| Result | **v9: PASS** (all optee_examples and all 112 xtest cases pass; regression_1039 is fixed). **M8: reproduced with an approved substitution, with a significant finding.** The PMP split of the OP-TEE core is in place, but no Trusted Application can start. **The cause was confirmed by experiment (§5.4).** |
| Scripts | `scripts/gate05b_build.sh` v6 (sha256 `c32bf023…`; v1–v5 kept in `logs/gate05/as-run/`), `scripts/gate05c_xtest.sh` (`61542b2c…`), `scripts/gate03_console.py` (`df46eb9f…`, **unchanged since the M1 run in G03**). Confirmation experiment: `scripts/gate05c_m8_exp.sh` (executed v1 `2f1636c9…`, kept in `as-run/`; corrected v2 `07f5cb83…`, see §5.4), `scripts/gate05c_dt_grant_exec.py` (`b152e3cd…`) |
| Logs | `logs/gate05/gate05c_v9_build_20261107-162748.log`, `gate05c_m8_build_20261107-172559.log` (and the failed `…-171201`), `gate05c_v9_xtest_20261107-175945.log`, `gate05c_m8_xtest_20261107-181012.log`, `gate05c_m8exp_20261107-182900.log` (+ `gate05c_m8exp_domain_20261107-182900.dts`), plus the console and QEMU-stdio logs of each run |

A Japanese version of this document is available as `G05c_version_comparison.ja.md`.

## 1. Goal

Compare the reproduced M1 stack (G03) with two newer stacks, each built from pinned commits in its own tree and tested in exactly the same way:

- **Andes v9** (`dev-optee-mpxy-v9`): the latest of the lineage that M1 is identical to (v6).
- **RISE RP022 M8** (`rp022-m8-pmp-data-perms`): gives the OP-TEE core's code and data distinct PMP permissions.

The questions are:

- Does the xtest result change?
- Is regression_1039 (the subkey-versus-default-key mismatch found in G03) fixed?
- Does M8's PMP split appear and work?

## 2. Steps

```bash
cd ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction
bash scripts/gate05b_build.sh v9 --prepare-only && bash scripts/gate05b_build.sh v9
bash scripts/gate05b_build.sh m8 --prepare-only && bash scripts/gate05b_build.sh m8
bash scripts/gate05c_xtest.sh v9 --prepare-only && bash scripts/gate05c_xtest.sh v9
bash scripts/gate05c_xtest.sh m8 --prepare-only && bash scripts/gate05c_xtest.sh m8
```

**Builds.** The procedure is the same as in G05b:

- each stack has its own tree, and the M1 tree is untouched;
- every component is resolved to a commit at prepare time and recorded;
- the build fails if Buildroot would use a source directory that was not pinned;
- 2 parallel jobs.

**Tests.** `gate05c_xtest.sh` is derived from the M1 test script (`gate03_boot_xtest.sh`), and the console driver is the unchanged `gate03_console.py`. The checks, the optee_examples and the xtest invocation are therefore identical to M1. Additional measures:

- QEMU runs with `-snapshot`, verified in its command line;
- the `sdcard.img` hash is compared before and after the run;
- ports are bound to `127.0.0.1` only.

For M8 the official instructions add vector extensions to the QEMU CPU (`-cpu rv64,zkr=on,v=true,vlen=128,zvkned=on,zvkb=on`); this is applied to the local launcher copy.

## 3. What was built

| Component | M1 (G03) | Andes v9 | RP022 M8 |
|---|---|---|---|
| How components are pinned | `local.mk` branches + defconfig git, pinned by us | **tarballs with the commit SHA in the URL** (no `local.mk`) | `local.mk` branches + defconfig git, pinned by us |
| Linux | `2912ca61` (6.16.0-rc2) | `9007f552` (6.19.0-rc2) | `9007f552` (same as v9) |
| OpenSBI | `cdd401f1` (v1.6) | `a1cdb6f4` (v1.8) | `a1cdb6f4` (same as v9; branch `rp022-m2`) |
| OP-TEE OS | `814978eb` (4.6) | `f1d35540` (reports 4.8) | `c0214654` (`rp022-m8-pmp-data-perms-v2`, reports 4.8) |
| U-Boot | `32bdb252` | `32bdb252` (same as M1) | `32bdb252` (same as M1) |
| QEMU | RISE `9c23f2a7` (10.1.93) | Buildroot's own **10.0.0** | RISE `9c23f2a7` (10.1.93) |
| optee_test | 4.6.0 | **4.9.0-rc1** | **4.6.0 (substitute, see §4)** |
| `tee.bin` size | 696,880 B | 705,072 B | **1,616,856 B** (sections padded to NAPOT regions) |

M8 differs from v9 mainly in the OP-TEE OS (the PMP split) and in QEMU. Linux, OpenSBI and U-Boot are the same commits.

## 4. Reproducibility findings for M8 (approved substitutions)

1. **The official procedure cannot be followed by a third party.** The RP022 M8 `local.mk` fetches optee_test from `https://gitlab.com/riseproject/riscv-optee/optee_test.git` (branch `rp022-m8-pmp-data-perms`). Anonymous access is refused: GitLab asks for a username.
2. **First substitute, upstream optee_test pull request #852** (which adds regression_1049): it **failed to compile**. Its base, upstream master, already contains regression_1047 (RP022 M3, ASLR), which needs `PTA_INVOKE_TESTS_CMD_ASLR`. The M8 OP-TEE OS branch does not have it. In other words, the RISE milestone branches are not cumulative: M8 does not contain M3.
3. **Second substitute, upstream optee_test release `4.6.0`** (the same version as M1): it builds.
   - regression_1049 is therefore not part of this run.
   - This loses little evidence, because the M8 documentation itself states that regression_1049 does not observe PMP and passes even without the PMP entries. The PMP evidence is the OpenSBI domain report and OP-TEE's own region report (§5.2).

Both substitutions were approved by the project owner. They are applied only when the official repository is not accessible, and they are logged as `[SUBST]` lines, in the pins file and in the build summary.

## 5. Results

### 5.1 Overview

| | M1 (G03) | Andes v9 | RP022 M8 |
|---|---|---|---|
| Boot to Linux login, OP-TEE driver over MPXY | yes | yes | yes |
| optee_examples (5) | 5 / 5 | **5 / 5** | **0 / 5** (`TEEC_OpenSession` fails, `0xffff0000`, origin 3 = TEE) |
| xtest test cases | 111, 1 failed | **112, 0 failed** | not completed: every case that needs a user-mode TA fails; xtest itself crashed (`Segmentation fault`) at regression_1037 |
| xtest subtests | 33,601, 2 failed | **35,526, 0 failed** | — |
| regression_1039 | FAILED (key mismatch) | **OK** | not reached |
| Trusted-domain PMP regions (OpenSBI report) | one region, all memory R/W/X | one region, all memory R/W/X | **three core regions + all memory** (§5.2) |
| `sdcard.img` unchanged after the run | n/a (G03 had no `-snapshot`) | yes | yes |

In v9, regression_1036, 1037, 1038 and 1041 report OK. As noted for M1 in G03, these may be internal skips (ARM-only features, or a missing PTA or TA); they were not re-examined here.

### 5.2 M8: the PMP split is in place

OpenSBI's report for the trusted domain:

```
Domain1 Region03 : 0x00000000f1100000-0x00000000f117ffff M: (R)     S/U: (R)
Domain1 Region04 : 0x00000000f1180000-0x00000000f11fffff M: (R,W)   S/U: (R,W)
Domain1 Region05 : 0x00000000f1000000-0x00000000f10fffff M: (R,X)   S/U: (R,X)
Domain1 Region06 : 0x0000000000000000-0xffffffffffffffff M: (R,W,X) S/U: (R,W,X)
```

OP-TEE's own report of the regions it was linked with:

```
I/TC: Core PMP regions for the OpenSBI domain device tree:
I/TC:   text base = <0x0 0xf1000000>; order = <20>; r-x
I/TC:   rodata base = <0x0 0xf1100000>; order = <19>; r--
I/TC:   data base = <0x0 0xf1180000>; order = <19>; rw-
```

Both match the RP022 M8 documentation exactly. OP-TEE boots on both harts, and Linux registers the driver.

### 5.3 M8: Trusted Applications cannot start

Every TA session fails at the same point. When OP-TEE starts **ldelf** (its user-mode TA loader), the very first instruction faults:

```
D/TC:? 0 ldelf_load_ldelf:110 ldelf load address 0x40003000
E/TC:? 0 User mode prefetch-abort at address 0x40003000
E/TC:? 0 cause  0000000000000001 epc  0000000040003000
E/TC:? 0 tval   0000000040003000
```

`cause 1` is an **instruction access fault**, not an instruction page fault (`cause 12`). The fetch is refused at physical-access level, which in this configuration means by PMP.

| Item | Status |
|---|---|
| The fault is an instruction access fault on the first instruction of ldelf | Verified (log) |
| The secure RAM pool (`SEC_RAM_OVERALL`) starts at `0xF1180000`, i.e. it includes the core data region, which PMP makes read-write but **not executable** | Verified (OP-TEE memory map in the log) |
| The unused tail of the boot allocator (257,888 bytes) is released inside that region | Verified (log) |
| **User-mode TA code (at least ldelf) executes from that non-executable region, so PMP refuses the instruction fetch** | **Verified by experiment** (§5.4) |
| The cause lies in the M8 OP-TEE OS / domain layout, not in the substituted optee_test | Supported: ldelf is part of OP-TEE OS; the optee_examples, which are not part of optee_test, fail in the same way; v9, with the same Linux and OpenSBI, passes everything |

The M8 documentation shows only regression_1049 as its validation. That test uses a pseudo TA and needs no user-mode TA, so it would not detect this. We do not claim that the RISE environment shows the same failure: it may use the LLVM defconfig or a slightly different tree. What we claim is narrower: following the published procedure as closely as possible, the result has the PMP split in place, but no user-mode TA can run.

### 5.4 Confirmation experiment: execute permission on the core data region only

**Method.** The domain DTB passed to QEMU was decompiled, and in a **copy** a single value was changed: the trusted-domain permission of the core data region `0xF1180000`–`0xF11FFFFF` went from `0x1b` (M: R,W / S/U: R,W) to `0x3b` (S/U-execute added).

- The bit value was read from OpenSBI's `sbi_domain.h` in the M8 tree, not assumed.
- Decompiling the original and the experimental DTB showed exactly one changed line.
- The original DTB, the generated `start-qemu.sh` and all build output stayed unchanged, and nothing was rebuilt.
- Boot, optee_examples, xtest and the console driver were the same as in §5.1.
- This configuration weakens isolation on purpose. It is an experiment, **not** a recommended setting.

**Results.** OpenSBI reported `Domain1 Region04 : 0x00000000f1180000-0x00000000f11fffff M: (R,W) S/U: (R,W,X)`.

| | M8 as built | M8, S/U-execute on the data region | v9 (reference) |
|---|---|---|---|
| optee_examples | 0 / 5 | **5 / 5** | 5 / 5 |
| xtest | did not complete | **111 cases, 1 failed** (regression_1039, as in M1); 33,633 subtests, 2 failed | 112 cases, 0 failed |
| user-mode prefetch aborts, all | 222 | 6 | 6 |
| of which cause 1 (instruction access fault, ldelf at `0x40003000`) | **222** | **0** | 0 |
| of which cause 12 (instruction page fault at `0x0` / `0x80018638`, provoked by xtest on purpose) | 0 | 6 | 6 |

**Verdict: CONFIRMED.** Adding S/U-execute to the core data region alone removes every ldelf access fault, and TAs work as in M1. In this M8 build, user-mode TA code (at least ldelf) is placed in, and executed from, the core data region that the M8 split makes non-executable.

As a consequence, the core-data split is only compatible with TAs if user-mode TA memory is kept out of that region, or if execute is granted where TA code is placed. Neither option was tried here.

**Note on the script verdict.** The executed script (v1) printed `REFUTED`, because it counted *all* user-mode prefetch aborts. That count includes the six instruction page faults that xtest provokes on purpose, which appear identically in v9, where everything passes. This was an error in my criterion. v2 counts only cause-1 access faults. Applied offline to the same logs, it gives CONFIRMED, and it gives the expected counts on all three runs (0 / 0 / 222). v1 and its log are preserved. v2 was not re-run on the target.

Regression_1039 fails again in this run for the same reason as in M1: the optee_test 4.6.0 subkeys are signed with RSA-2048, while this OP-TEE embeds the RSA-4096 default key.

## 6. Summary

- **Andes v9** passes everything that M1 runs, plus one more test case: 112 cases and 35,526 subtests without a failure. The regression_1039 failure found in G03 is gone with optee_test 4.9.0-rc1. v9 pins its components by commit-SHA tarball URLs, which makes it reproducible without local pinning.
- **RISE RP022 M8** splits the OP-TEE core into read-execute, read-only and read-write PMP regions, exactly as documented, but in this reproduction no user-mode Trusted Application could start: ldelf faults on its first instruction with an instruction access fault. A one-value experiment confirmed the cause. Granting S/U-execute to the core data region alone makes all TAs work again (examples 5/5, xtest as in M1). TA code is therefore placed in the region that the split makes non-executable.
- **Reproducibility.** The official M8 procedure depends on a repository that is not publicly accessible. The first substitute failed because the milestone branches are not cumulative. The M8 result therefore rests on an approved, documented substitution: optee_test 4.6.0.
