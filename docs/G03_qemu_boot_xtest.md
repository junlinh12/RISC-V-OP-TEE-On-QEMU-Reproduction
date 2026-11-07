# G03 — Boot on QEMU, optee_examples and xtest

| Item | Value |
|---|---|
| Project | RISC-V-OP-TEE-On-QEMU-Reproduction |
| Baseline | RISE RP016 Milestone 1 (`rp016_m1`), pinned commits from G01/G02 |
| Date | 2026-11-07 |
| Result | **Completed with one exception.** Boot and TEE function were reproduced; xtest passed 110 of 111 test cases. The one failure, regression_1039, is explained (§5). |
| xtest | 111 test cases, 1 failed, 0 reported as skipped; 33,601 subtests, 2 failed; 646 s |
| Scripts | `scripts/gate03_boot_xtest.sh` (sha256 `7339bb17…`), `scripts/gate03_console.py` (`df46eb9f…`), `scripts/gate03_diag_subkey.sh` (`b17108e2…`), `scripts/gate03_closure_check.sh` (`12146082…`; the first version `5120d843…` is in `logs/gate03/as-run/`) |
| Logs | `logs/gate03/gate03_boot_xtest_20261107-084006.log`, `gate03_console_20261107-084006.log`, `gate03_qemu_stdio_20261107-084006.log.gz`, `gate03_diag_subkey_20261107-091114.log`, `gate03_closure_check_20261107-102857.log`, `gate03_closure_check_20261107-103434.log` |
| Revised | 2026-11-07, for publication (G06). This record replaces a first version that was withdrawn after an external review because it overstated the result. |

A Japanese version of this document is available as `G03_qemu_boot_xtest.ja.md`.

## 1. Goal

Boot the images built in G02 on QEMU, and confirm that OP-TEE works by running `optee_examples` and the OP-TEE test suite `xtest`. Both consoles are recorded as evidence.

## 2. Steps

```bash
cd ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction
bash scripts/gate03_boot_xtest.sh --prepare-only   # safety checks and launcher; QEMU is not started
bash scripts/gate03_boot_xtest.sh                  # boot, optee_examples, xtest
bash scripts/gate03_diag_subkey.sh                 # read-only diagnosis of regression_1039
bash scripts/gate03_closure_check.sh               # read-only: evidence preservation and the 1039 control test
```

Run the boot inside `tmux` (or `screen`). Pressing `Ctrl-C` at any time stops QEMU and keeps the logs complete.

## 3. How the run is made safe

| Measure | Implementation |
|---|---|
| No root | The script refuses to run as root. QEMU runs as the current user; semihosting stays enabled, because the OP-TEE console needs it. |
| Correct QEMU | It requires the Buildroot-built `output/host/bin/qemu-system-riscv64` (10.1.93) and checks that `start-qemu.sh` puts that directory first in `PATH`, so there is no silent fallback to the distribution QEMU. |
| Loopback only | The upstream `start-qemu.sh` is not modified. A local copy is generated in which **only** `hostfwd=tcp::2200-:22` becomes `hostfwd=tcp:127.0.0.1:2200-:22`; the script checks that the diff contains exactly that change. |
| Binding check | While QEMU runs, ports 64320 and 2200 must be bound to `127.0.0.1` only; otherwise QEMU is stopped immediately. |
| Clean shutdown | A trap stops QEMU on exit, error or `Ctrl-C`. The live log pipeline is line-buffered and ignores `Ctrl-C`. |
| Automated console | `scripts/gate03_console.py` (Python standard library only) replaces the manual `telnet localhost 64320` session of the official instructions and types the same commands. Each command ends with `echo __G03_RC<n>=$?__`, so every exit code is captured. |

The guest root file system contains **no SSH server**, so port 2200 leads nowhere; it is restricted to the loopback interface anyway. The guest `root` account has no password, which is the Buildroot default.

**Not protected in this run:** QEMU was started **without** `-snapshot`, so the guest wrote to `sdcard.img` (§4.5). All later boots (G05a–G05c) use `-snapshot` and verify that the image hash does not change.

The QEMU command line equals the official one, except for the `hostfwd` address.

## 4. Results

### 4.1 Boot

The login prompt appeared 4 s after the console was connected.

| Stage | Observed |
|---|---|
| U-Boot SPL | `U-Boot SPL 2025.01` |
| OpenSBI | `OpenSBI v1.6`, platform `riscv-virtio,qemu`, firmware base `0x80100000`, three domains (§4.4) |
| OP-TEE OS (semihosting console) | `OP-TEE version: Unknown_4.6` (built from a git tree without tags); primary hart 0 and secondary hart 1 initialized |
| U-Boot proper | `U-Boot 2025.01` |
| Linux | `Linux version 6.16.0-rc2`; `optee: revision 4.6`, dynamic shared memory enabled, driver initialized |

### 4.2 Guest checks and optee_examples

All checks returned exit code 0: `uname -a`, `cat /proc/cmdline`, `ls -l /dev/tee*`, `pidof tee-supplicant`, `dmesg | grep -i optee`, and the five examples `optee_example_hello_world`, `_random`, `_aes`, `_hotp`, `_secure_storage`.

`optee_example_acipher` (needs arguments) and `optee_example_plugins` (depends on the supplicant plugin configuration) were not run.

### 4.3 xtest

| Metric | Value |
|---|---|
| Test cases | 111, of which **1 failed** (`regression_1039`) |
| Subtests | 33,601, of which **2 failed** (`regression_1039.1`, `regression_1039.2`) |
| Reported as skipped | 0 |
| Duration | 646 s |

**What "OK" does not mean here.** Four cases report OK without exercising a feature of this platform:

- `regression_1036` (Pointer Authentication) and `regression_1038` (Memory Tagging) test Arm-only features. They are **not applicable** to RISC-V.
- `regression_1037` (remote attestation) and `regression_1041` (fTPM) find no attestation PTA and no fTPM TA in this build. They are **not tested**.

This record therefore does not claim that attestation or fTPM work.

### 4.4 OpenSBI domains (from the boot log)

| Domain | HARTs | Next address / mode | Notable regions |
|---|---|---|---|
| Domain0 `root` | 0,1 | `0x81200000`, S-mode | OpenSBI code and data (`0x80100000–0x8015ffff`) are M-only |
| Domain1 `trusted-domain` | 0\*,1\* | **`0xf1000000`** (OP-TEE), S-mode | OpenSBI regions protected; everything else S/U: R,W,X |
| Domain2 `untrusted-domain` | 0,1 | `0x81200000` (U-Boot proper → Linux), S-mode | **`0xf1000000–0xf1ffffff` M: () S/U: ()**: the 16 MiB OP-TEE region is not accessible |

This is the configured isolation. Its enforcement at run time was demonstrated later, in G05a.

### 4.5 Shutdown and the disk image

After `poweroff`, QEMU exited by itself with status 0, and nothing was left running. During the guest shutdown, however:

- `Stopping tee-supplicant: FAIL` was printed;
- `can't remount /dev/root read-only` was printed.

Because the guest had mounted its root file system read-write, and QEMU ran without `-snapshot`, `sdcard.img` changed: `cebd9fe8…` after the G02 build, `dec31312…` after this run. The closure check (§6) preserved the changed image as evidence and re-checked the other 13 artifacts, which were unchanged.

## 5. regression_1039

`regression_1039` ("Test subkey verification") loads two TAs whose signatures go through a chain of **subkeys**. Both loads were refused (`TEEC_ERROR_SECURITY`); all other TAs loaded normally.

**Facts** (`gate03_diag_subkey`, `gate03_closure_check`):

- OP-TEE embeds `keys/default.pem`, an **RSA-4096** key. In optee_os, the default key was enlarged from 2048 to 4096 bits by commit `5d5d7d0b1c03` (2025-05-09).
- The pre-signed test subkeys shipped with **optee_test 4.6.0** carry **RSA-2048** signatures.
- The chains are as follows:
  - `subkey1_ta` (1039.1): the ROOT key signs `top_level_subkey`, which signs `mid_level_subkey`, which signs the TA.
  - `subkey2_ta` (1039.2): the ROOT key signs the identity subkey `identity_subkey2`, which signs the TA.

  *(The first version of this record wrongly said that all subkeys are signed by the ROOT key.)*

| Case | Evidence | Status |
|---|---|---|
| 1039.1 | With `sign_encrypt.py verify`, the chain fails with the current key and **verifies with the previous RSA-2048 default key**; a normally signed TA verifies with the current key (control) | **Proven** |
| 1039.2 | Fails with the current key (`Verification failed`). With the previous key there is no signature error; the tool stops later, at a UUID comparison that rejects two identical UUIDs of different types (a defect of the tool). The upstream notes state that `identity_subkey2` is signed directly with `default_ta.pem` | **Strongly supported** |

**Conclusion.** The failure comes from pairing the optee_test 4.6.0 release with an optee_os snapshot taken after its default key was enlarged. It is a version mismatch between the test suite and OP-TEE OS, and the refusal is the expected behaviour for an unverifiable signature chain. G05c confirmed this from another side: the Andes v9 stack, with optee_test 4.9.0-rc1, passes `regression_1039`. The test suite was not modified.

## 6. Closure check: evidence preservation

`gate03_closure_check.sh` is read-only with respect to sources and images. It:

- set the raw-log directories to 700 and the files to 600;
- copied every executed script whose hash matches the one recorded at run time to `logs/gateNN/as-run/`;
- re-checked the G02 artifacts and preserved the changed `sdcard.img`;
- ran the 1039 control test (§5).

## 7. Other observations

| Observation | Explanation (G04) |
|---|---|
| U-Boot prints `optee optee: OP-TEE api uid mismatch` | U-Boot's OP-TEE driver only has an SMC-style call path, whereas OP-TEE is reachable only through MPXY in this design. U-Boot itself cannot use OP-TEE; Linux is not affected. |
| OP-TEE prints `CPU node does not have 'reg' property` | It is printed for the `/cpus/cpu-map` node, which is not a CPU. Both hart IDs are still collected, so the message is harmless. |
| The console driver counted one failing case three times (`failed_checks=3`) | Cosmetic: it counts the exit code, the failed subtests and the failed cases separately. The verdict is unaffected. |

## 8. Deviations from the official instructions

1. The SSH forwarding listens on `127.0.0.1` instead of all interfaces. This is done in a generated local copy; the upstream `start-qemu.sh` is unchanged.
2. The console session is automated instead of typed manually. The guest commands are the same.

## 9. Summary

The RISC-V OP-TEE stack built from the pinned RP016 M1 commits boots on QEMU 10.1.93. The boot chain is U-Boot SPL → OpenSBI v1.6 with three domains → OP-TEE OS on both harts in the trusted domain → U-Boot → Linux 6.16.0-rc2 in the untrusted domain.

All five argument-free `optee_examples` pass, and `xtest` passes 110 of 111 test cases (33,599 of 33,601 subtests). The failing case, regression_1039, is explained by a version mismatch between the test suite's pre-signed subkeys (RSA-2048) and the OP-TEE OS default key (RSA-4096):

- proven for 1039.1;
- strongly supported for 1039.2;
- fixed in a newer stack (G05c).

Four "OK" cases do not exercise this platform (two are Arm-only, two are not tested). The run modified `sdcard.img`, which later runs avoid with `-snapshot`.
