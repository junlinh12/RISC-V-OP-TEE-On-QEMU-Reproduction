# Evidence index — claim → evidence

Each row points to the published log that supports a claim, and to the record that discusses it. Logs are under `logs/gateNN/`; files ending in `.gz` are gzip-compressed (`zcat`, `zgrep`).

日本語版: [evidence-index.ja.md](evidence-index.ja.md)

| # | Claim | Evidence (logs) | Record |
|---|---|---|---|
| 1 | Every RP016 M1 component was built from its pinned commit | `gate02/gate02_build_20261106-205938.log` (§8 verify), `gate01/gate01_fetch_sources_20261106-192647.log` | G01 §3.2, G02 §3.1 |
| 2 | M1 boots: SPL → OpenSBI v1.6 → OP-TEE (2 harts) → U-Boot → Linux 6.16.0-rc2 | `gate03/gate03_console_20261107-084006.log`, `gate03/gate03_qemu_stdio_20261107-084006.log.gz` | G03 §4.1 |
| 3 | optee_examples 5/5 and xtest 110/111 on M1 | `gate03/gate03_boot_xtest_20261107-084006.log` (STEP / SUMMARY lines), `gate03/gate03_console_20261107-084006.log` | G03 §4.2–4.3 |
| 4 | regression_1039 is a key-version mismatch (1039.1 proven, 1039.2 strongly supported) | `gate03/gate03_diag_subkey_20261107-091114.log`, `gate03/gate03_closure_check_20261107-102857.log`, `gate03/gate03_closure_check_20261107-103434.log` | G03 §5 |
| 5 | Three OpenSBI domains; the OP-TEE region is configured as inaccessible to the untrusted domain | `gate03/gate03_console_20261107-084006.log` (domain report), `gate04/gate04_qemu_rv64_virt_domain.decompiled_20261107-104416.dts` | G03 §4.4, G04 A1–A3 |
| 6 | Linux reaches OP-TEE through SBI MPXY; OpenSBI has no OP-TEE-specific code | `gate04/gate04_inspect_arch_20261107-104416.log` (sections B) | G04 B1–B8 |
| 7 | U-Boot `api uid mismatch` and OP-TEE `'reg' property` messages explained | `gate04/gate04_inspect_arch_20261107-104416.log` (section E) | G04 E1–E2 |
| 8 | PMP isolation is enforced at run time (`cause 5`), and a control address is readable | `gate05/gate05a_isolation_20261107-120926.log`, `gate05/gate05a_L_console_20261107-120926.log` (dmesg), `gate05/gate05a_U2_console_20261107-120926.log` | G05a §3 |
| 9 | The bare-metal app reproduces the documented output | `gate05/gate05a_bm_app_20261107-120926.log` | G05a §3.4 |
| 10 | M2 and M3 were built from pinned commits; only OpenSBI (and bm-app in M3) differ from M1 | `gate05/gate05b_m2_build_20261107-143028.log`, `gate05/gate05b_m3_build_20261107-145829.log` | G05b §3 |
| 11 | M2 handles a UART interrupt in M-mode through the APLIC | `gate05/gate05b_m2_test_20261107-154518.log`, `gate05/gate05b_m2_test_opensbi_console_20261107-154518.log` | G05b §4.1 |
| 12 | M3 routes the interrupt to its owning domain and switches the hart `domain1 → domain2 → domain1` | `gate05/gate05b_m3_test_20261107-154510.log`, `gate05/gate05b_m3_test_opensbi_console_20261107-154510.log` | G05b §4.2 |
| 13 | Andes v9 passes xtest 112/112, including regression_1039 | `gate05/gate05c_v9_xtest_20261107-175945.log`, `gate05/gate05c_v9_console_20261107-175945.log` | G05c §5.1 |
| 14 | The official M8 procedure depends on a repository that is not publicly accessible | `gate05/gate05c_m8_build_20261107-162726.log` (`[NG] … NOT accessible`) | G05c §4 |
| 15 | The first M8 substitute (PR #852) does not compile against the M8 OP-TEE OS | `gate05/gate05c_m8_build_20261107-171201.log`, `gate05/gate05c_m8_make_20261107-171201.log.gz` | G05c §4 |
| 16 | M8 splits the OP-TEE core into R-X / R / RW PMP regions | `gate05/gate05c_m8_xtest_20261107-181012.log` (OpenSBI report, OP-TEE region report) | G05c §5.2 |
| 17 | On M8 no user-mode TA starts: ldelf faults on its first instruction with `cause 1` (222 times) | `gate05/gate05c_m8_qemu_stdio_20261107-181012.log.gz`, `gate05/gate05c_m8_console_20261107-181012.log` | G05c §5.3 |
| 18 | Granting S/U-execute to the M8 core data region alone makes TAs work again | `gate05/gate05c_m8exp_20261107-182900.log`, `gate05/gate05c_m8exp_domain_20261107-182900.dts`, `gate05/gate05c_m8exp_qemu_stdio_20261107-182900.log.gz` | G05c §5.4 |
| 19 | Published files were scanned for leaks before publication | `gate06/gate06_inventory_*.log` (and the scan of the assembled tree in G06-3) | README "Sanitization" |
