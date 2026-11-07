# G05b — RP016 M2 (APLIC) and M3 (VIRQ): Builds and Interrupt Tests

| Item | Value |
|---|---|
| Project | RISC-V-OP-TEE-On-QEMU-Reproduction |
| Date | 2026-11-07 |
| Result | **PASS**: both builds completed and verified; every M2 and M3 interrupt check passed |
| Scripts | `scripts/gate05b_build.sh` (sha256 `6536d20a…`; the earlier `0e948eec…` is kept in `logs/gate05/as-run/`), `scripts/gate05b_test.sh` (`4ad18fe8…`), `scripts/gate05b_console.py` (`6f6e8bbc…`) |
| Logs | `logs/gate05/gate05b_m2_build_20261107-143028.log`, `gate05b_m3_build_20261107-145829.log`, `gate05b_m2_test_20261107-154518.log`, `gate05b_m3_test_20261107-154510.log`, plus the OpenSBI and Linux console logs of each test |

A Japanese version of this document is available as `G05b_interrupts_m2_m3.ja.md`.

## 1. Goal

M1 has no secure interrupts: OP-TEE has no interrupt controller and leaves on any foreign interrupt (G04, D1–D2). RP016 addresses interrupts in two later milestones:

- **M2** adds M-mode handling of wired interrupts through the APLIC.
- **M3** adds VIRQ, which routes an interrupt to the OpenSBI domain that owns it and switches the hart to that domain if necessary.

G05b builds both milestones and runs the tests described in their official instructions.

## 2. Steps

```bash
cd ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction
# G05b-1: build (each milestone in its own tree)
bash scripts/gate05b_build.sh m2 --prepare-only
bash scripts/gate05b_build.sh m3 --prepare-only
bash scripts/gate05b_build.sh m2 && bash scripts/gate05b_build.sh m3
# G05b-2: interrupt tests
bash scripts/gate05b_test.sh m3 --prepare-only
bash scripts/gate05b_test.sh m2 --prepare-only
bash scripts/gate05b_test.sh m3; bash scripts/gate05b_test.sh m2
```

### 2.1 Builds

- **Separate trees.** Each milestone has its own tree (`work/buildroot-m2`, `work/buildroot-m3`). The M1 reference tree is not modified.
- **Shared downloads.** Downloads use `work/dl-g05`. It was seeded with hard links to the M1 tarballs (git caches excluded), so the M1 download directory is unchanged. Buildroot replaces a downloaded file by renaming it, never by rewriting it in place.
- **Discovered pins.** The components are read from `local.mk` and the defconfig. Each branch is resolved to a commit SHA at prepare time and recorded in a pins file; an unknown component would stop the script. Pinning works as in G02:
  - each `custom/` checkout gets a local branch at the pinned SHA;
  - the Linux and U-Boot versions are set in `.config`.
- **Limited parallelism.** The build runs with 2 jobs. Both the top-level `make -j2` and the per-package `BR2_JLEVEL=2` in `.config` are set; `-j` alone does not limit the parallel compiles inside each package, which caused the risk of running out of memory. Each build took about 28 minutes.

### 2.2 Tests

The test design follows the start scripts that the build actually generated, as printed in the build logs:

| Fact about the generated scripts | Consequence for the test |
|---|---|
| M2 (`start-qemu-kernel.sh`) and M3 (`start-qemu-bm-kernel.sh`) both run QEMU twice: first to dump the device tree, then, after `dtc` and `fdtoverlay` merge the milestone's overlay, for the real run | The ports are checked only after the second QEMU reports that it is waiting for the Linux console |
| They do not parse options; QEMU arguments are passed directly | `-snapshot` is passed **without** `--` (unlike `start-qemu.sh` of M1) |
| QEMU is not `exec`ed | The whole process group is managed, and it is always stopped on exit or `Ctrl-C` |
| `hostfwd=tcp::2200-:22` listens on all interfaces (1× in M2, 2× in M3) | A local copy binds it to `127.0.0.1`; the upstream script is not modified |
| OpenSBI and the bare-metal apps use the QEMU stdio console; Linux uses a virtio console on TCP `127.0.0.1:64321` | Key presses are written to QEMU's stdin (a FIFO); Linux is driven through the TCP console |

Safety measures, as in G03 and G05a:

- no root;
- the Buildroot-built QEMU only;
- every listening port must be on `127.0.0.1`;
- `-snapshot` is verified in the QEMU command line;
- the `sdcard.img` hash is compared before and after the run.

The pass criteria are the outputs named in the official milestone instructions.

The prepare step checked the overlay sequence only for M3. In the M2 log, that sequence was found afterwards; the test handled it correctly because it manages the whole process group.

## 3. What differs from M1 (pinned commits)

| Component | M1 | M2 | M3 |
|---|---|---|---|
| Buildroot | `d7204671` (`rp016_m1`) | `8fba3ebe` (`rp016_m2_aplic_up_v2`) | `f2e760ef` (`rp016_m3_virq_up_v1`) |
| **OpenSBI** | `cdd401f1` (v1.6) | **`4533a2a9`** (`rp016_m2_aplic_up_v2`, v1.8) | **`7ca03a0f`** (`rp016_m3_virq_up_v1`, v1.8) |
| **bm-app** | `97545c35` | `97545c35` (same as M1) | **`cad8639a`** (`rp016_m3_virq_v2`) |
| OP-TEE OS, QEMU, Linux, U-Boot | `814978eb`, `9c23f2a7`, `2912ca61`, `32bdb252` | same as M1 | same as M1 |

The milestone work is entirely in **OpenSBI**, plus the bare-metal test application in M3. QEMU is 10.1.93 in all three builds.

## 4. Results

### 4.1 M2 — wired interrupts handled in M-mode (APLIC)

| Check | Result |
|---|---|
| Key `a` on the OpenSBI console is handled in M-mode | PASS: `[APLIC TEST] UART got 'a'(0x61)` |
| Key `b` | PASS: `[APLIC TEST] UART got 'b'(0x62)` |
| Linux registers the APLIC | PASS: `riscv-aplic d000000.interrupt-controller: 96 interrupts directly connected to 2 CPUs` |
| APLIC-DIRECT lines keep counting | PASS: 694 → 998 |
| IRQ affinity to CPU1 (virtio0 = `vda`, irq 15) | PASS: CPU0 +0, CPU1 +66 |
| IRQ affinity back to CPU0 | PASS: CPU0 +64, CPU1 +0 |

OpenSBI reports two APLIC instances:

- the M-mode root APLIC at `0xC000000` (`targets_mmode=1`), which receives the UART line;
- the S-mode APLIC at `0xD000000` used by Linux.

The interrupt path is the one the documentation describes: IRQ chip handler → APLIC raw handler → UART handler → completion.

### 4.2 M3 — interrupt-driven domain context switch (VIRQ)

Four harts are used. Linux runs on harts 0 and 1 in the root domain. Hart 2 runs bm-app1 in `domain1` and bm-app2 in `domain2`. The device-tree routing rule sends UART RX (hwirq 10) to `domain2`.

| Check | Result |
|---|---|
| bm-app1 (`domain1`, hart 2) is ready for keys | PASS |
| Key `a` → hart 2 switches `domain1 → domain2` | PASS |
| bm-app2 handles it | PASS: `[UART] Got 'a'(0x61)` |
| hart 2 returns `domain2 → domain1` | PASS |
| Key `b` → the same switch, handling and return | PASS |
| Linux registers the APLIC | PASS: `96 interrupts directly connected to 4 CPUs` |
| APLIC-DIRECT lines keep counting | PASS: 712 → 1111 |

Excerpt of the OpenSBI console for the first key:

```
[IRQCHIP] Calling handler for hwirq 10
[VIRQ] route hwirq 10, chip_uid 8176 -> dom (domain2), channel 4, VIRQ 0
[VIRQ] virq courier switching hart2 domain1 -> domain2
[IRQCHIP] Set mip.SEIP (mip before=0x20, after=0x220)
BM-APP (domain 2, hart 2): [trap] enter: scause=8000000000000009 ...
BM-APP (domain 2, hart 2): [UART] Got 'a'(0x61)
[IRQCHIP] Calling EOI of hwirq 10
[domain] return hart2 domain2 -> domain1 (mideleg=0x1666)
```

In words:

1. The physical interrupt is taken in M-mode.
2. It is mapped to a virtual IRQ and routed to the owning domain.
3. Hart 2 is switched into that domain, and the interrupt is signalled to S-mode (`scause` `0x8000000000000009`, supervisor external interrupt).
4. The payload pops and completes the VIRQ through the VIRQ ECALL extension (listed among the SBI extensions as `virq`).
5. OpenSBI switches back to the previous domain.

## 5. Scope: what these tests do and do not show

- **OP-TEE does not take part in the M2 and M3 tests.** Following the official instructions, they boot OpenSBI (`fw_jump`) directly with Linux and the bare-metal applications. They demonstrate the OpenSBI interrupt infrastructure: M-mode wired IRQs in M2, and routing an interrupt to its owning domain with a domain switch in M3. They do not show OP-TEE receiving interrupts.
- **The interface for OP-TEE is the next step.** According to the RISE documentation, RP022 M1:
  - replaces the VIRQ ECALL with the RPMI SYSTEM_IRQ service group over MPXY;
  - adds a yield ECALL suitable for OP-TEE.

  Its status is "Delivered": the patch series, combined with VIRQ series v2, was posted to the OpenSBI mailing list on 2026-10-29 and is under review. It was not part of this reproduction. (An earlier version of this record called it "planned"; that information was out of date.)
- **Not covered.** Later RP016 milestones (M4 hardware-isolation framework, M5 WorldGuard, M6 FP/vector context) and real hardware were not tested.

## 6. Observations

| Observation | Assessment |
|---|---|
| In M2, each key press invoked the APLIC handler twice; the second call received no character | Not investigated. The M2 documentation mentions a QEMU APLIC register behaviour that needed a workaround in OpenSBI. |
| M3 booted with `Boot HART ID : 1` without problems | The G05a hang (cold-boot hart 1) was in the OP-TEE configuration; the two configurations differ, so no conclusion is drawn. |
| M3 Linux prints `riscv-aplic ... invalid cpuid for IDC2` | Consistent with `maxcpus=2` (hart 2 belongs to the bare-metal domains). The APLIC is registered right after. |
| `dtc` warns about `interrupts-extended` in the M3 overlay | The official overlay uses literal phandle numbers, as documented. |
| In the second M3 cycle, a COMPLETE call appears before the POP of the new VIRQ | Not investigated. |
| `tee-supplicant` fails to start in the M2 and M3 Linux boots | Expected, because OP-TEE is not part of these configurations (§5). |

## 7. Summary

Both RP016 milestones build from pinned commits in separate trees. The only changed components are OpenSBI (v1.8) and, in M3, the bare-metal test application.

- **M2** handles a UART wired interrupt end to end in M-mode through the APLIC, without disturbing Linux interrupt handling or IRQ affinity.
- **M3** routes the same interrupt as a virtual IRQ to the owning domain: hart 2 switches from `domain1` to `domain2`, the payload handles and completes the interrupt, and the hart returns to `domain1`, repeatably. Linux interrupt handling is unaffected.

This is the OpenSBI groundwork for interrupt-driven world switching, which M1 lacks. Connecting it to OP-TEE is the subject of RP022 M1, which was delivered for review in October 2026 and was not reproduced here.
