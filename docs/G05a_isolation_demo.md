# G05a — Isolation Demonstration and Bare-metal App (RP016 M1 images)

| Item | Value |
|---|---|
| Project | RISC-V-OP-TEE-On-QEMU-Reproduction |
| Images | The M1 build from G02 (no rebuild). Every boot used QEMU `-snapshot`, so `sdcard.img` was not modified. |
| Date | 2026-11-07 |
| Result | **Completed with one exception**. The PMP isolation was demonstrated at run time. The U-Boot read of the OP-TEE region was not obtained (see §4). |
| Scripts | `scripts/gate05a_isolation.sh` (sha256 `4dcbde9b…`), `scripts/gate05a_console.py` (sha256 `3ec32a25…`) |
| Logs | `logs/gate05/gate05a_isolation_20261107-120926.log`, plus one console log and one QEMU log per boot (U1, U2, L) and the bm-app log |

A Japanese version of this document is available as `G05a_isolation_demo.ja.md`.

## 1. Goal

G04 listed "run-time enforcement of the PMP isolation" as not demonstrated. G05a shows, on the reproduced M1 images, that code running in the untrusted domain cannot read the memory of OP-TEE or of OpenSBI. It also runs the bare-metal SBI application, the remaining step of the official M1 instructions.

## 2. Steps

```bash
cd ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction
bash scripts/gate05a_isolation.sh --prepare-only    # safety checks only, QEMU is not started
bash scripts/gate05a_isolation.sh                   # three boots + bm-app
```

**Method.** Only read accesses are used; nothing is ever written to guest memory.

| Boot | How | Control (must be readable) | Probe (must be denied) |
|---|---|---|---|
| U1 | Stop U-Boot's autoboot and run `md.l <addr> 4` | `0x80200000` (normal RAM) | `0xF1000000` (OP-TEE) |
| U2 | Same as U1 | `0x80200000` | `0x80100000` (OpenSBI) |
| L | Log in to Linux and run `devmem <addr> 32` | `0x0C000004` (PLIC register) | `0xF1000000`, `0x80100000` |
| BM | `start-qemu-bm.sh`, stopped after the documented last line | — | — |

Why these two paths:

- **U-Boot** runs in S-mode inside the untrusted domain, exactly like Linux, but it has no `/dev/mem` filter. A denied read therefore shows the hardware check directly.
- **Linux** is checked from user space. `devmem` maps the physical page with `mmap`, so a denied access only kills `devmem`, and the kernel keeps running. In this kernel `CONFIG_STRICT_DEVMEM` is not set, so Linux itself does not block the attempt.

**Safety measures**, inherited from G03:

- The script refuses to run as root.
- Only the Buildroot-built QEMU is used.
- QEMU is started from a loopback-only copy of the upstream `start-qemu.sh`, and the ports must be bound to `127.0.0.1`.
- QEMU is always stopped on exit or `Ctrl-C`.
- The script checks that `-snapshot` is present in the QEMU command line, and that the `sdcard.img` hash is the same before and after the run.

`start-qemu.sh` parses its own options first. QEMU arguments must therefore follow `--`, as in `start-qemu.sh -- -snapshot`.

### Run history

| Time | Script | Outcome |
|---|---|---|
| 12:01:16 | v1, `--prepare-only` | READY |
| 12:01:36 | v1 | `-snapshot` was passed without `--`, so `start-qemu.sh` rejected it and QEMU never started (safe: `sdcard.img` unchanged). bm-app ran and matched the documentation. |
| 12:09:26 | v2 | U1: boot hang. U2: done. L: done. BM: matched the documentation. `sdcard.img` unchanged. |

## 3. Results

### 3.1 Reads

| Target | From U-Boot (S-mode, untrusted domain) | From Linux user space (`devmem`) |
|---|---|---|
| Control | `0x80200000`: **readable** (`edfe0dd0…`, the FDT magic of the FIT image placed there by QEMU) | `0x0C000004`: **readable** (`0x00000001`) |
| OP-TEE `0xF1000000` | **not obtained** (U1 boot hang, §4.1) | **denied**: `Segmentation fault`; kernel reports `cause: 0x5` |
| OpenSBI `0x80100000` | **denied**: `Unhandled exception: Load access fault`, `TVAL: 0x80100000` | **denied**: `Segmentation fault`; kernel reports `cause: 0x5` |

### 3.2 Key evidence

U-Boot (U2), reading the OpenSBI region:

```
=> md.l 0x80100000 4
Unhandled exception: Load access fault
EPC: 000000017f7b17aa RA: 000000017f7b1706 TVAL: 0000000080100000
```

Linux (L), reading the OP-TEE region (the same appears for the OpenSBI region):

```
devmem[135]: unhandled signal 11 code 0x2 at 0x0000555557315ca4 in busybox[...]
status: 0000000200004020 badaddr: 00007fff7fce9000 cause: 0000000000000005
```

How Linux sees the two regions (`/proc/iomem`):

```
80100000-8015ffff : Reserved
f1000000-f1ffffff : Reserved
```

### 3.3 Interpretation

- **`cause 5` means a load access fault, not a page fault (`cause 13`).** The `devmem` mapping was valid in the Linux page tables, yet the physical access was refused. In this system, the only mechanism that refuses a read of valid RAM in this way is PMP, which OpenSBI programs from the domain configuration (G04, A2 and A5).
- **U-Boot shows the same refusal at S-mode**: it reports `Load access fault` with the faulting physical address in `TVAL`.
- **The control reads exclude a broken access path.** On both paths, reading a permitted address succeeded.

**Verdict: the PMP isolation of the OP-TEE and OpenSBI regions from the untrusted domain is demonstrated at run time.**

- The OP-TEE region is shown denied through Linux.
- The OpenSBI region is shown denied through both U-Boot and Linux.

The script's automatic verdict was `INCONCLUSIVE`, because its rule required the U-Boot read of the OP-TEE region. That read is missing for an unrelated reason (§4.1). The verdict above is the reviewed verdict, based on the transcripts.

### 3.4 Bare-metal SBI application

The output ends with exactly the five lines that the RP016 build instructions document as the expected end:

```
Welcome to OpenSBI bare-metal app!
SBI Spec Version: 3.0
SBI Implementation: OpenSBI
OpenSBI Version: 1.6
Init timer successfully 10000000 ticks/s
```

The application does not power off QEMU, so the script stops QEMU after this line. This run uses `fw_jump`, a single root domain, and firmware at `0x80000000`; this layout differs from the OP-TEE configuration.

## 4. Observations

### 4.1 Boot hang when hart 1 is the cold-boot hart (U1)

In U1, OpenSBI reported `Boot HART ID : 1`. OP-TEE printed `Primary CPU0 (hart0) initialized` and then stopped: it never brought up the secondary hart, and U-Boot never started. The driver timed out after 600 s.

In the other boots of this project (G03, U2 and L), the cold-boot hart was hart 0, and the system booted normally. Which hart wins the cold boot varies from run to run in QEMU.

| Item | Status |
|---|---|
| The hang occurred once in four boots, and only in the boot where hart 1 was the cold-boot hart | Observed |
| OP-TEE reports `hart0` as primary although the cold-boot hart was 1 | Observed |
| The cause, for example hart-ID handling at boot | Not investigated |

### 4.2 Reset after the fault (U2)

After the access fault, U-Boot resets the system. On the second boot, OP-TEE panicked with `Page is already mapped` (`core/mm/core_mmu.c:2008`), likely because RAM still held the state of the first boot. This is outside the scope of the isolation test; QEMU was stopped by the script.

### 4.3 What this does not show

- Only reads were tested. Writes and instruction fetches were not.
- Accesses by DMA masters were not tested. PMP covers hart accesses only, and there is no IOPMP in M1.
- Only this one build was tested; later milestones are covered in G05b and G05c.

## 5. Summary

On the reproduced M1 images, reads from the untrusted domain into the OP-TEE region and into the OpenSBI region fail with access faults:

- from Linux user space (`cause 5`) for both regions;
- from U-Boot in S-mode (`Load access fault`) for the OpenSBI region.

Permitted control addresses remain readable. This turns "PMP enforcement at run time" from *not demonstrated* (G04) into *demonstrated*, with one exception: the U-Boot read of the OP-TEE region was not obtained because of a sporadic boot hang, observed when hart 1 was the cold-boot hart.

The bare-metal SBI application reproduces the documented output exactly.
