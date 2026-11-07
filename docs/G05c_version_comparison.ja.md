# G05c — 新しい構成と M1 の比較：Andes v9 と RISE RP022 M8

| 項目 | 内容 |
|---|---|
| プロジェクト | RISC-V-OP-TEE-On-QEMU-Reproduction |
| 実施日 | 2026-11-07 |
| 結果 | **v9：PASS**（optee_examples と xtest の112ケースがすべて成功。regression_1039 は解消）。**M8：承認済みの差し替えのうえで再現し、重要な発見があった。** OP-TEE のコアの PMP の分割は実現しているが、Trusted Application が1つも起動できない。**その原因は実験で確定した（5.4 節）** |
| スクリプト | `scripts/gate05b_build.sh` v6（sha256 `c32bf023…`。v1〜v5 は `logs/gate05/as-run/` に保全）、`scripts/gate05c_xtest.sh`（`61542b2c…`）、`scripts/gate03_console.py`（`df46eb9f…`、**G03 の M1 の実行から変更なし**）。確定実験：`scripts/gate05c_m8_exp.sh`（実行した v1 は `2f1636c9…` で `as-run/` に保全。判定条件を訂正した v2 は `07f5cb83…`。5.4 節）、`scripts/gate05c_dt_grant_exec.py`（`b152e3cd…`） |
| ログ | `logs/gate05/gate05c_v9_build_20261107-162748.log`、`gate05c_m8_build_20261107-172559.log`（失敗した `…-171201` も保全）、`gate05c_v9_xtest_20261107-175945.log`、`gate05c_m8_xtest_20261107-181012.log`、`gate05c_m8exp_20261107-182900.log`（と `gate05c_m8exp_domain_20261107-182900.dts`）。ほかに、各実行のコンソールログと QEMU の標準出力のログ |

英語版は `G05c_version_comparison.md`。

## 1. 目的

再現した M1 の構成（G03）を、2つの新しい構成と比較する。どちらも、固定した commit から専用の作業ツリーでビルドし、M1 とまったく同じ方法で試験する。

- **Andes v9**（`dev-optee-mpxy-v9`）：M1 と同一である v6 の系列の最新版。
- **RISE RP022 M8**（`rp022-m8-pmp-data-perms`）：OP-TEE のコアのコードとデータに、PMP で別々の権限を与える。

確かめたいことは次の3つ。

- xtest の結果は変わるか。
- regression_1039（G03 で見つかった、サブキーと既定の鍵の不一致）は解消されているか。
- M8 の PMP の分割は現れ、動作するか。

## 2. 手順

```bash
cd ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction
bash scripts/gate05b_build.sh v9 --prepare-only && bash scripts/gate05b_build.sh v9
bash scripts/gate05b_build.sh m8 --prepare-only && bash scripts/gate05b_build.sh m8
bash scripts/gate05c_xtest.sh v9 --prepare-only && bash scripts/gate05c_xtest.sh v9
bash scripts/gate05c_xtest.sh m8 --prepare-only && bash scripts/gate05c_xtest.sh m8
```

**ビルド**：手順は G05b と同じ。

- 構成ごとに専用の作業ツリーを使い、M1 の作業ツリーには触れない。
- すべてのコンポーネントを準備の段階で commit に解決して記録する。
- 固定していないソースディレクトリを Buildroot が使おうとした場合は失敗にする。
- 2 並列でビルドする。

**試験**：`gate05c_xtest.sh` は M1 の試験スクリプト（`gate03_boot_xtest.sh`）から作り、コンソール操作は変更していない `gate03_console.py` を使う。そのため、確認項目、optee_examples、xtest の実行方法は M1 と同一である。追加した対策は次のとおり。

- QEMU は `-snapshot` 付きで起動し、そのコマンドラインで有効になっていることを確認する。
- `sdcard.img` のハッシュを、実行の前後で比べる。
- ポートは `127.0.0.1` だけで待ち受ける。

M8 では、公式手順のとおり、QEMU の CPU 指定にベクトル拡張を加える（`-cpu rv64,zkr=on,v=true,vlen=128,zvkned=on,zvkb=on`）。この変更は、ローカルの起動用コピーにだけ適用する。

## 3. ビルドしたもの

| コンポーネント | M1（G03） | Andes v9 | RP022 M8 |
|---|---|---|---|
| コンポーネントの固定方法 | `local.mk` のブランチと defconfig の git（こちらで固定） | **URL に commit の SHA を含む tarball**（`local.mk` なし） | `local.mk` のブランチと defconfig の git（こちらで固定） |
| Linux | `2912ca61`（6.16.0-rc2） | `9007f552`（6.19.0-rc2） | `9007f552`（v9 と同じ） |
| OpenSBI | `cdd401f1`（v1.6） | `a1cdb6f4`（v1.8） | `a1cdb6f4`（v9 と同じ。ブランチ `rp022-m2`） |
| OP-TEE OS | `814978eb`（4.6） | `f1d35540`（4.8 と報告） | `c0214654`（`rp022-m8-pmp-data-perms-v2`、4.8 と報告） |
| U-Boot | `32bdb252` | `32bdb252`（M1 と同じ） | `32bdb252`（M1 と同じ） |
| QEMU | RISE `9c23f2a7`（10.1.93） | Buildroot 標準の **10.0.0** | RISE `9c23f2a7`（10.1.93） |
| optee_test | 4.6.0 | **4.9.0-rc1** | **4.6.0（差し替え。4章）** |
| `tee.bin` の大きさ | 696,880 バイト | 705,072 バイト | **1,616,856 バイト**（各セクションを NAPOT の領域に合わせて詰め物をしている） |

M8 と v9 の主な違いは、OP-TEE OS（PMP の分割）と QEMU である。Linux、OpenSBI、U-Boot は同じ commit を使っている。

## 4. M8 の再現性に関する発見（承認済みの差し替え）

1. **公式手順は第三者には実行できない。** RP022 M8 の `local.mk` は、optee_test を `https://gitlab.com/riseproject/riscv-optee/optee_test.git`（ブランチ `rp022-m8-pmp-data-perms`）から取得する。しかし、匿名でのアクセスは拒否され、GitLab はユーザー名を求めてくる。
2. **1回目の差し替え：本家 optee_test のプルリクエスト #852**（regression_1049 を追加するもの）。これは**コンパイルに失敗した**。土台である本家の最新版には、すでに regression_1047（RP022 M3 の ASLR）が含まれており、このテストは `PTA_INVOKE_TESTS_CMD_ASLR` を必要とする。ところが M8 の OP-TEE OS のブランチには、それが無い。つまり、RISE のマイルストーンのブランチは積み上げ式ではなく、M8 に M3 は含まれていない。
3. **2回目の差し替え：本家 optee_test の正式リリース `4.6.0`**（M1 と同じ版）。これはビルドできた。
   - そのため、この実行には regression_1049 は含まれない。
   - それによって失う証拠は少ない。M8 のドキュメント自身が、regression_1049 は PMP を観測しておらず、PMP のエントリが無くても成功すると明記しているからである。PMP の証拠は、OpenSBI のドメインの報告と、OP-TEE 自身の領域の報告で得られる（5.2 節）。

2つの差し替えは、どちらもプロジェクトの責任者が承認したものである。差し替えは公式のリポジトリにアクセスできない場合に限って行い、`[SUBST]` の行、pins ファイル、ビルドの要約に記録している。

## 5. 結果

### 5.1 概要

| | M1（G03） | Andes v9 | RP022 M8 |
|---|---|---|---|
| Linux のログインまで起動し、MPXY 経由で OP-TEE ドライバが動く | はい | はい | はい |
| optee_examples（5種） | 5 / 5 | **5 / 5** | **0 / 5**（`TEEC_OpenSession` が `0xffff0000`、origin 3 = TEE で失敗） |
| xtest のテストケース | 111件中1件失敗 | **112件中0件失敗** | 完了せず：ユーザーモードの TA を必要とするケースはすべて失敗し、regression_1037 で xtest 自体が `Segmentation fault` で停止 |
| xtest のサブテスト | 33,601件中2件失敗 | **35,526件中0件失敗** | — |
| regression_1039 | 失敗（鍵の不一致） | **OK** | 到達せず |
| trusted ドメインの PMP の領域（OpenSBI の報告） | 1つ（全メモリ R/W/X） | 1つ（全メモリ R/W/X） | **コアの3領域 + 全メモリ**（5.2 節） |
| 実行後も `sdcard.img` が変わらない | 対象外（G03 は `-snapshot` なし） | はい | はい |

v9 では、regression_1036、1037、1038、1041 も OK と報告された。ただし G03 で M1 について指摘したとおり、これらは内部でスキップされている可能性がある（ARM 専用の機能、または PTA や TA が無い）。今回は改めて調べていない。

### 5.2 M8：PMP の分割は実現している

OpenSBI による trusted ドメインの報告：

```
Domain1 Region03 : 0x00000000f1100000-0x00000000f117ffff M: (R)     S/U: (R)
Domain1 Region04 : 0x00000000f1180000-0x00000000f11fffff M: (R,W)   S/U: (R,W)
Domain1 Region05 : 0x00000000f1000000-0x00000000f10fffff M: (R,X)   S/U: (R,X)
Domain1 Region06 : 0x0000000000000000-0xffffffffffffffff M: (R,W,X) S/U: (R,W,X)
```

OP-TEE が、自身のリンク時の配置として報告した領域：

```
I/TC: Core PMP regions for the OpenSBI domain device tree:
I/TC:   text base = <0x0 0xf1000000>; order = <20>; r-x
I/TC:   rodata base = <0x0 0xf1100000>; order = <19>; r--
I/TC:   data base = <0x0 0xf1180000>; order = <19>; rw-
```

どちらも、RP022 M8 のドキュメントと完全に一致している。OP-TEE は両方のハートで起動し、Linux もドライバを登録している。

### 5.3 M8：Trusted Application が起動できない

TA のセッションは、すべて同じ箇所で失敗している。OP-TEE が **ldelf**（ユーザーモードの TA ローダー）を起動すると、その最初の命令で例外が起きる。

```
D/TC:? 0 ldelf_load_ldelf:110 ldelf load address 0x40003000
E/TC:? 0 User mode prefetch-abort at address 0x40003000
E/TC:? 0 cause  0000000000000001 epc  0000000040003000
E/TC:? 0 tval   0000000040003000
```

`cause 1` は**命令アクセスフォールト**で、命令のページフォルト（`cause 12`）ではない。命令の取り出しが物理アクセスのレベルで拒否されたことを意味し、この構成ではそれを行うのは PMP である。

| 項目 | 状態 |
|---|---|
| 例外は、ldelf の最初の命令での命令アクセスフォールトである | 確認済み（ログ） |
| セキュア RAM のプール（`SEC_RAM_OVERALL`）は `0xF1180000` から始まり、PMP が読み書き可・**実行不可**にしたコアのデータ領域を含んでいる | 確認済み（ログにある OP-TEE のメモリマップ） |
| 起動時の割り当て器の使わなかった末尾（257,888 バイト）が、この領域の内側で返却されている | 確認済み（ログ） |
| **ユーザーモードの TA のコード（少なくとも ldelf）が、この実行不可の領域から実行されるため、PMP が命令の取り出しを拒否した** | **実験で確認済み**（5.4 節） |
| 原因は M8 の OP-TEE OS とドメインの配置にあり、差し替えた optee_test ではない | 裏付けあり：ldelf は OP-TEE OS の一部である。optee_test に含まれない optee_examples も同じように失敗している。Linux と OpenSBI が同じ v9 では、すべて成功している |

M8 のドキュメントが検証として示しているのは、regression_1049 だけである。このテストは疑似 TA を使い、ユーザーモードの TA を必要としないため、この問題は検出されない。ただし、RISE の環境でも同じ失敗が起きると主張するものではない（LLVM 用の defconfig や、わずかに異なるツリーを使っている可能性がある）。ここで主張するのは、より限られたことである。公開された手順にできるだけ忠実に従った結果、PMP の分割は実現したが、ユーザーモードの TA は1つも動かなかった。

### 5.4 確定実験：コアのデータ領域だけに実行権限を与える

**方法**：QEMU に渡すドメインの DTB を逆コンパイルし、その**コピー**で値を1つだけ変えた。コアのデータ領域 `0xF1180000`〜`0xF11FFFFF` に対する trusted ドメインの権限を、`0x1b`（M: R,W / S/U: R,W）から `0x3b`（S/U の実行を追加）にした。

- ビットの値は推測せず、M8 のツリーにある OpenSBI の `sbi_domain.h` から読み取った。
- 元の DTB と実験用の DTB を逆コンパイルして比べ、変わったのが1行だけであることを確認した。
- 元の DTB、生成された `start-qemu.sh`、ビルドの成果物はいずれも変更しておらず、再ビルドもしていない。
- 起動、optee_examples、xtest、コンソール操作スクリプトは 5.1 節と同じ。
- この構成は隔離を意図的に弱めたものであり、実験であって、推奨する設定**ではない**。

**結果**：OpenSBI は `Domain1 Region04 : 0x00000000f1180000-0x00000000f11fffff M: (R,W) S/U: (R,W,X)` と報告した。

| | ビルドしたままの M8 | M8 のデータ領域に S/U の実行を追加 | v9（参考） |
|---|---|---|---|
| optee_examples | 0 / 5 | **5 / 5** | 5 / 5 |
| xtest | 完了せず | **111ケース中1件失敗**（regression_1039。M1 と同じ）。サブテストは 33,633件中2件失敗 | 112ケース中0件失敗 |
| ユーザーモードの命令フェッチ例外（全体） | 222件 | 6件 | 6件 |
| そのうち cause 1（命令アクセスフォールト。ldelf の `0x40003000`） | **222件** | **0件** | 0件 |
| そのうち cause 12（`0x0` / `0x80018638` での命令ページフォルト。xtest がわざと起こすもの） | 0件 | 6件 | 6件 |

**判定：確定（CONFIRMED）。** コアのデータ領域だけに S/U の実行権限を足すと、ldelf のアクセスフォールトはすべて消え、TA は M1 と同じように動いた。この M8 のビルドでは、ユーザーモードの TA のコード（少なくとも ldelf）が、M8 の分割で実行不可になるコアのデータ領域に置かれ、そこから実行されている。

その帰結として、コアのデータ領域の分割を TA と両立させるには、ユーザーモードの TA のメモリをその領域の外に置くか、TA のコードが置かれる場所に実行権限を与える必要がある。どちらも、今回は試していない。

**スクリプトの判定についての注記**：実行したスクリプト（v1）は `REFUTED` と出力した。これは、ユーザーモードの命令フェッチ例外を*すべて*数えていたためである。その中には、xtest がわざと起こす命令ページフォルト6件が含まれており、全項目が成功する v9 でもまったく同じ6件が出ている。これは私の判定条件の誤りだった。v2 は cause 1 のアクセスフォールトだけを数える。同じログに v2 の判定を当てはめると CONFIRMED になり、3つの実行すべてで期待どおりの件数（0 / 0 / 222）になる。v1 とそのログは保全している。v2 を実機で再実行はしていない。

この実行で regression_1039 が再び失敗したのは、M1 と同じ理由による。optee_test 4.6.0 のサブキーは RSA-2048 で署名されているが、この OP-TEE は RSA-4096 の既定の鍵を埋め込んでいる。

## 6. まとめ

- **Andes v9** は、M1 で実行するものに1ケースを加えたすべてに成功した。112ケース、35,526のサブテストで失敗は無い。G03 で見つかった regression_1039 の失敗は、optee_test 4.9.0-rc1 で解消している。v9 はコンポーネントを、commit の SHA を含む tarball の URL で固定しているため、こちらで固定しなくても再現できる。
- **RISE RP022 M8** は、ドキュメントどおり、OP-TEE のコアを読み取り・実行、読み取り専用、読み書きの3つの PMP 領域に分割している。しかし今回の再現では、ユーザーモードの Trusted Application が1つも起動できなかった（ldelf が最初の命令で命令アクセスフォールトを起こす）。値を1つだけ変える実験で、原因を確定した。コアのデータ領域だけに S/U の実行権限を与えると、すべての TA が再び動く（optee_examples 5/5、xtest は M1 と同じ傾向）。つまり、TA のコードは、分割によって実行不可になる領域に置かれている。
- **再現性**：M8 の公式手順は、公開されていないリポジトリに依存している。1回目の差し替えは、マイルストーンのブランチが積み上げ式でないために失敗した。そのため M8 の結果は、承認され、記録された差し替え（optee_test 4.6.0）に基づいている。
