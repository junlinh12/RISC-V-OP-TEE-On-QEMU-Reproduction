# 証拠の索引 — 主張 → 証拠

各行は、主張を裏付ける公開ログと、それを論じている作業記録を示します。ログは `logs/gateNN/` にあります。`.gz` で終わるファイルは gzip で圧縮されています（`zcat`、`zgrep` で読めます）。

English: [evidence-index.md](evidence-index.md)

| # | 主張 | 証拠（ログ） | 作業記録 |
|---|---|---|---|
| 1 | RP016 M1 のすべてのコンポーネントを、固定した commit からビルドした | `gate02/gate02_build_20261106-205938.log`（8節の検証）、`gate01/gate01_fetch_sources_20261106-192647.log` | G01 3.2 節、G02 3.1 節 |
| 2 | M1 が起動する：SPL → OpenSBI v1.6 → OP-TEE（2ハート）→ U-Boot → Linux 6.16.0-rc2 | `gate03/gate03_console_20261107-084006.log`、`gate03/gate03_qemu_stdio_20261107-084006.log.gz` | G03 4.1 節 |
| 3 | M1 で optee_examples が 5/5、xtest が 110/111 | `gate03/gate03_boot_xtest_20261107-084006.log`（STEP / SUMMARY の行）、`gate03/gate03_console_20261107-084006.log` | G03 4.2〜4.3 節 |
| 4 | regression_1039 は鍵の版の不一致（1039.1 は実証済み、1039.2 は強く裏付けあり） | `gate03/gate03_diag_subkey_20261107-091114.log`、`gate03/gate03_closure_check_20261107-102857.log`、`gate03/gate03_closure_check_20261107-103434.log` | G03 5章 |
| 5 | OpenSBI のドメインは3つ。OP-TEE の領域は、untrusted ドメインからアクセスできない設定 | `gate03/gate03_console_20261107-084006.log`（ドメインの表示）、`gate04/gate04_qemu_rv64_virt_domain.decompiled_20261107-104416.dts` | G03 4.4 節、G04 A1〜A3 |
| 6 | Linux は SBI の MPXY で OP-TEE に到達する。OpenSBI に OP-TEE 専用のコードは無い | `gate04/gate04_inspect_arch_20261107-104416.log`（B の各節） | G04 B1〜B8 |
| 7 | U-Boot の `api uid mismatch` と OP-TEE の `'reg' property` のメッセージの原因 | `gate04/gate04_inspect_arch_20261107-104416.log`（E 節） | G04 E1〜E2 |
| 8 | PMP による隔離が実行時に強制され（`cause 5`）、対照のアドレスは読める | `gate05/gate05a_isolation_20261107-120926.log`、`gate05/gate05a_L_console_20261107-120926.log`（dmesg）、`gate05/gate05a_U2_console_20261107-120926.log` | G05a 3章 |
| 9 | ベアメタルアプリが、公式手順に記載された出力を再現する | `gate05/gate05a_bm_app_20261107-120926.log` | G05a 3.4 節 |
| 10 | M2 と M3 を固定した commit からビルドした。M1 と違うのは OpenSBI（M3 では bm-app も）だけ | `gate05/gate05b_m2_build_20261107-143028.log`、`gate05/gate05b_m3_build_20261107-145829.log` | G05b 3章 |
| 11 | M2 は、UART の割り込みを APLIC を通じて M モードで処理する | `gate05/gate05b_m2_test_20261107-154518.log`、`gate05/gate05b_m2_test_opensbi_console_20261107-154518.log` | G05b 4.1 節 |
| 12 | M3 は、割り込みを持ち主のドメインに届け、ハートを `domain1 → domain2 → domain1` と切り替える | `gate05/gate05b_m3_test_20261107-154510.log`、`gate05/gate05b_m3_test_opensbi_console_20261107-154510.log` | G05b 4.2 節 |
| 13 | Andes v9 は、regression_1039 を含めて xtest が 112/112 | `gate05/gate05c_v9_xtest_20261107-175945.log`、`gate05/gate05c_v9_console_20261107-175945.log` | G05c 5.1 節 |
| 14 | M8 の公式手順は、公開されていないリポジトリに依存している | `gate05/gate05c_m8_build_20261107-162726.log`（`[NG] … NOT accessible`） | G05c 4章 |
| 15 | M8 の最初の代替（PR #852）は、M8 の OP-TEE OS に対してコンパイルできない | `gate05/gate05c_m8_build_20261107-171201.log`、`gate05/gate05c_m8_make_20261107-171201.log.gz` | G05c 4章 |
| 16 | M8 は、OP-TEE のコアを R-X / R / RW の PMP 領域に分割する | `gate05/gate05c_m8_xtest_20261107-181012.log`（OpenSBI の表示、OP-TEE の領域の報告） | G05c 5.2 節 |
| 17 | M8 では、ユーザーモードの TA が1つも起動しない：ldelf が最初の命令で `cause 1` のフォールトを起こす（222回） | `gate05/gate05c_m8_qemu_stdio_20261107-181012.log.gz`、`gate05/gate05c_m8_console_20261107-181012.log` | G05c 5.3 節 |
| 18 | M8 のコアのデータ領域だけに S/U の実行権限を与えると、TA が再び動く | `gate05/gate05c_m8exp_20261107-182900.log`、`gate05/gate05c_m8exp_domain_20261107-182900.dts`、`gate05/gate05c_m8exp_qemu_stdio_20261107-182900.log.gz` | G05c 5.4 節 |
| 19 | 公開するファイルを、公開の前に漏えいについて検査した | `gate06/gate06_inventory_*.log`（と、G06-3 で組み立てたツリーの検査） | README「マスク処理」 |
