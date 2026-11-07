# Known limitations, deviations and corrections

日本語版: [known-limitations.ja.md](known-limitations.ja.md)

## Scope

- **QEMU only.** Nothing was run on real hardware.
- **Source-level reproduction.** Commits are pinned; binaries are not expected to be bit-identical (timestamps, paths, host tools). See G01 §4.
- **Pinned on 2026-11-05/06.** Later upstream changes are not reflected. The RISE documentation and project status were read in November 2026.

## Deviations from the official instructions

| Where | Deviation | Why |
|---|---|---|
| all boots | `hostfwd` bound to `127.0.0.1` in a local copy of the start script | Host safety; the upstream script is unchanged |
| all boots | Console sessions automated instead of typed | Recorded exit codes; the guest commands are the same |
| G03 onwards | `-snapshot` used from G05a on (not in G03) | Keep the disk image unchanged; G03 modified `sdcard.img` |
| G05b–G05c builds | 2 parallel jobs (`-j2`, `BR2_JLEVEL=2`) instead of all CPUs | Avoid running out of memory; affects build time only |
| M8 | optee_test substituted: upstream release `4.6.0` instead of the RISE branch | The official repository is not publicly accessible; PR #852 did not compile (G05c §4) |
| M8 | QEMU CPU extended with vector extensions | As in the official M8 instructions, applied to a local copy |
| M8 experiment | One permission value changed in a copy of the domain DTB | Confirmation experiment; it weakens isolation on purpose and is **not** a recommended setting (G05c §5.4) |

## Results that need care

- **G00 is a conditional PASS.** The first log predates exit-code recording and raw-log preservation, and the hash of the script that produced it was not recorded.
- **xtest "OK" without coverage.** `regression_1036` and `1038` are Arm-only (not applicable). `1037` (attestation) and `1041` (fTPM) find no PTA or TA (not tested), in M1 and probably in v9 as well (not re-examined).
- **regression_1039 on M1.** 1039.1 is proven; 1039.2 is strongly supported (a tool defect prevents a full verification).
- **G03 modified `sdcard.img`.** It ran without `-snapshot`; the changed image was preserved.
- **Boot hang once in four M1 boots** when hart 1 was the cold-boot hart (G05a §4.1). Not investigated.
- **Reset after a U-Boot access fault** leads to an OP-TEE panic (`Page is already mapped`) on the second boot (G05a §4.2). Out of scope.
- **U-Boot cannot use OP-TEE** (`api uid mismatch`): its driver only has an SMC-style path (G04 E1, supported, not traced at run time).
- **The G04 architecture call sequence** (Linux → MPXY → domain switch → OP-TEE → back) is supported by code locations, not traced at run time.
- **M2 / M3 demos do not involve OP-TEE.** They show the OpenSBI interrupt infrastructure only. Connecting it to OP-TEE is RP022 M1, delivered for review and not reproduced here.
- **M8 regression_1049 was not run** (not part of optee_test 4.6.0). Per the M8 documentation, it would not observe PMP anyway.
- **M8 TA failure.** The cause is confirmed for this reproduction. We do not claim that the RISE environment fails in the same way.

## Not demonstrated

- DMA isolation: there is no IOPMP in these stacks, and PMP covers hart accesses only.
- Secure interrupts handled by OP-TEE.
- Remote attestation and fTPM.
- RP016 M4–M6 and RP022 milestones other than M8.
- Write and instruction-fetch denial into the OP-TEE region from the untrusted domain: only reads were tested in G05a.

## Corrections made during the project

| Where | What was wrong | Correction |
|---|---|---|
| G01 | Said that U-Boot SPL loads `u-boot.itb`; claimed an identical build | QEMU's loader places the image; source-level reproduction |
| G03 (first version, withdrawn) | Overstated the result; said that all subkeys are signed by the ROOT key | Rewritten with evidence levels; corrected chains |
| G05a v1 | Passed `-snapshot` without `--` to `start-qemu.sh` (QEMU never started) | Fixed in v2 |
| G05a automated verdict | Said `INCONCLUSIVE` because of a missing U-Boot read | Reviewed verdict: demonstrated (`cause 5` through Linux) |
| G05b record (first version) | Called RP022 M1 "planned" | Status is "Delivered" (patches posted 2026-10-29) |
| G05c `gate05c_m8_exp.sh` v1 | Counted all user prefetch aborts, so it said `REFUTED` | v2 counts only `cause 1`; the reviewed verdict is CONFIRMED |

## Sanitization side effects

- `<EMAIL>` also replaces harmless strings (for example systemd unit names of the form `user@<UID>.service`, package authors).
- The time zone is masked as `<TZ>`.
- Large logs are published gzip-compressed, with URL query strings and ANSI codes removed.
