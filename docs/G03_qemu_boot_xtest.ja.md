# G03 — QEMU での起動、optee_examples、xtest

| 項目 | 内容 |
|---|---|
| プロジェクト | RISC-V-OP-TEE-On-QEMU-Reproduction |
| 基準 | RISE RP016 Milestone 1（`rp016_m1`）、G01 / G02 で固定した commit |
| 実施日 | 2026-11-07 |
| 結果 | **例外付きの完了。** 起動と TEE の機能を再現した。xtest は111ケース中110件が成功。失敗した1件（regression_1039）は原因を説明できている（5章） |
| xtest | 111ケース中1件失敗、スキップと報告されたもの0件。サブテストは33,601件中2件失敗。646秒 |
| スクリプト | `scripts/gate03_boot_xtest.sh`（sha256 `7339bb17…`）、`scripts/gate03_console.py`（`df46eb9f…`）、`scripts/gate03_diag_subkey.sh`（`b17108e2…`）、`scripts/gate03_closure_check.sh`（`12146082…`。最初の版 `5120d843…` は `logs/gate03/as-run/` に保全） |
| ログ | `logs/gate03/gate03_boot_xtest_20261107-084006.log`、`gate03_console_20261107-084006.log`、`gate03_qemu_stdio_20261107-084006.log.gz`、`gate03_diag_subkey_20261107-091114.log`、`gate03_closure_check_20261107-102857.log`、`gate03_closure_check_20261107-103434.log` |
| 改訂 | 2026-11-07、公開（G06）に向けて。この作業記録は、結果を過大に書いていたために外部レビューの後で撤回した最初の版を置き換えるものである |

英語版は `G03_qemu_boot_xtest.md`。

## 1. 目的

G02 でビルドしたイメージを QEMU で起動し、`optee_examples` と OP-TEE のテストスイート `xtest` を実行して、OP-TEE が動作することを確かめる。両方のコンソールを証拠として記録する。

## 2. 手順

```bash
cd ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction
bash scripts/gate03_boot_xtest.sh --prepare-only   # 安全確認と起動用コピーの作成のみ（QEMU は起動しない）
bash scripts/gate03_boot_xtest.sh                  # 起動、optee_examples、xtest
bash scripts/gate03_diag_subkey.sh                 # regression_1039 の診断（読み取り専用）
bash scripts/gate03_closure_check.sh               # 読み取り専用：証拠の保全と、1039 の対照試験
```

起動は `tmux`（または `screen`）の中で行う。いつ `Ctrl-C` を押しても QEMU は停止し、ログは欠けずに残る。

## 3. 安全のための対策

| 対策 | 実装 |
|---|---|
| root で実行しない | スクリプトは root での実行を拒否する。QEMU は現在のユーザーで動く。OP-TEE のコンソールが必要とするので、セミホスティングは有効のままにする。 |
| 正しい QEMU を使う | Buildroot がビルドした `output/host/bin/qemu-system-riscv64`（10.1.93）があることを必須とし、`start-qemu.sh` がそのディレクトリを `PATH` の先頭に置いていることを確認する。これで、ディストリビューションの QEMU に黙って切り替わることはない。 |
| ループバックのみ | 上流の `start-qemu.sh` は変更しない。`hostfwd=tcp::2200-:22` **だけ**を `hostfwd=tcp:127.0.0.1:2200-:22` に変えたローカルのコピーを作り、差分がその変更だけであることを確認する。 |
| 待受の確認 | QEMU の実行中、ポート 64320 と 2200 は `127.0.0.1` だけで待ち受けていなければならない。そうでなければ、直ちに QEMU を停止する。 |
| 確実な停止 | 終了時、エラー時、`Ctrl-C` のときは、trap が QEMU を停止する。ログのパイプラインは行単位でバッファし、`Ctrl-C` を無視する。 |
| コンソールの自動操作 | `scripts/gate03_console.py`（Python の標準ライブラリのみ）が、公式手順の手作業の `telnet localhost 64320` の代わりに、同じコマンドを入力する。各コマンドの後に `echo __G03_RC<n>=$?__` を付け、すべての終了コードを記録する。 |

ゲストのルートファイルシステムには **SSH サーバーが無い**ので、ポート 2200 はどこにもつながらない。それでもループバックに限定している。ゲストの `root` アカウントにはパスワードが無い（Buildroot の既定）。

**この実行で守れていなかったこと**：QEMU を `-snapshot` **なし**で起動したため、ゲストが `sdcard.img` に書き込んだ（4.5 節）。それ以降の起動（G05a〜G05c）はすべて `-snapshot` を使い、イメージのハッシュが変わらないことを確認している。

QEMU のコマンドラインは、`hostfwd` のアドレスを除いて公式のものと同じである。

## 4. 結果

### 4.1 起動

コンソールに接続してから4秒で、ログインのプロンプトが出た。

| 段階 | 観測 |
|---|---|
| U-Boot SPL | `U-Boot SPL 2025.01` |
| OpenSBI | `OpenSBI v1.6`、プラットフォーム `riscv-virtio,qemu`、ファームウェアのベース `0x80100000`、3つのドメイン（4.4 節） |
| OP-TEE OS（セミホスティングのコンソール） | `OP-TEE version: Unknown_4.6`（タグの無い git のツリーからビルド）。primary の hart 0 と secondary の hart 1 が初期化された |
| U-Boot 本体 | `U-Boot 2025.01` |
| Linux | `Linux version 6.16.0-rc2`。`optee: revision 4.6`、動的共有メモリが有効、ドライバが初期化された |

### 4.2 ゲストでの確認と optee_examples

すべて終了コード 0 だった：`uname -a`、`cat /proc/cmdline`、`ls -l /dev/tee*`、`pidof tee-supplicant`、`dmesg | grep -i optee`、そして5つの例 `optee_example_hello_world`、`_random`、`_aes`、`_hotp`、`_secure_storage`。

`optee_example_acipher`（引数が必要）と `optee_example_plugins`（supplicant のプラグインの設定に依存）は実行していない。

### 4.3 xtest

| 指標 | 値 |
|---|---|
| テストケース | 111件、うち **1件が失敗**（`regression_1039`） |
| サブテスト | 33,601件、うち **2件が失敗**（`regression_1039.1`、`regression_1039.2`） |
| スキップと報告されたもの | 0件 |
| 所要時間 | 646秒 |

**ここでの「OK」が意味しないこと**：次の4つのケースは、このプラットフォームの機能を試さないまま OK と報告している。

- `regression_1036`（Pointer Authentication）と `regression_1038`（Memory Tagging）は、Arm 専用の機能を試すもので、RISC-V には**該当しない**。
- `regression_1037`（リモートアテステーション）と `regression_1041`（fTPM）は、このビルドにアテステーションの PTA も fTPM の TA も無いため、**試験されていない**。

したがって、この作業記録は、アテステーションや fTPM が動作するとは主張しない。

### 4.4 OpenSBI のドメイン（起動ログから）

| ドメイン | HART | 次のアドレス / モード | 主な領域 |
|---|---|---|---|
| Domain0 `root` | 0,1 | `0x81200000`、S モード | OpenSBI のコードとデータ（`0x80100000–0x8015ffff`）は M モード専用 |
| Domain1 `trusted-domain` | 0\*,1\* | **`0xf1000000`**（OP-TEE）、S モード | OpenSBI の領域は保護。それ以外は S/U: R,W,X |
| Domain2 `untrusted-domain` | 0,1 | `0x81200000`（U-Boot 本体 → Linux）、S モード | **`0xf1000000–0xf1ffffff` M: () S/U: ()**：16 MiB の OP-TEE の領域にはアクセスできない |

これは設定上の隔離である。実行時にそれが強制されることは、後に G05a で実証した。

### 4.5 シャットダウンとディスクイメージ

`poweroff` の後、QEMU は自ら終了ステータス 0 で終わり、何も残らなかった。ただし、ゲストのシャットダウンの途中で次のメッセージが出た。

- `Stopping tee-supplicant: FAIL`
- `can't remount /dev/root read-only`

ゲストがルートファイルシステムを読み書き可能でマウントしており、QEMU を `-snapshot` なしで実行したため、`sdcard.img` が変化した（G02 のビルド後は `cebd9fe8…`、この実行の後は `dec31312…`）。閉幕チェック（6章）で、変化したイメージを証拠として保全し、ほかの13個の成果物が変化していないことを改めて確認した。

## 5. regression_1039

`regression_1039`（「サブキーの検証の試験」）は、署名が**サブキー**の連鎖を経由する2つの TA を読み込む。どちらの読み込みも拒否され（`TEEC_ERROR_SECURITY`）、ほかの TA はすべて普通に読み込まれた。

**事実**（`gate03_diag_subkey`、`gate03_closure_check`）：

- OP-TEE は `keys/default.pem` を埋め込んでおり、これは **RSA-4096** の鍵である。optee_os では、既定の鍵が commit `5d5d7d0b1c03`（2025-05-09）で 2048 ビットから 4096 ビットに拡大された。
- **optee_test 4.6.0** に同梱された署名済みのテスト用サブキーには、**RSA-2048** の署名が付いている。
- 連鎖は次のとおり。
  - `subkey1_ta`（1039.1）：ROOT の鍵が `top_level_subkey` に署名し、それが `mid_level_subkey` に、それが TA に署名する。
  - `subkey2_ta`（1039.2）：ROOT の鍵が identity サブキー `identity_subkey2` に署名し、それが TA に署名する。

  *（この作業記録の最初の版は、すべてのサブキーが ROOT の鍵で署名されていると誤って書いていた。）*

| ケース | 証拠 | 状態 |
|---|---|---|
| 1039.1 | `sign_encrypt.py verify` で、連鎖は現在の鍵では失敗し、**以前の RSA-2048 の既定の鍵では検証に成功する**。通常の署名の TA は、現在の鍵で検証に成功する（対照） | **実証済み** |
| 1039.2 | 現在の鍵では失敗する（`Verification failed`）。以前の鍵では署名のエラーは出ず、ツールはその後の UUID の比較で止まる。この比較は、型が異なるだけの同一の UUID を不一致とする（ツールの不具合）。上流の資料には、`identity_subkey2` は `default_ta.pem` で直接署名されると書かれている | **強く裏付けられている** |

**結論**：この失敗は、optee_test 4.6.0 のリリースを、既定の鍵が拡大された後の optee_os のスナップショットと組み合わせたことによる。テストスイートと OP-TEE OS の版の不一致であり、拒否は、検証できない署名の連鎖に対する正しい動作である。G05c では別の側から確認できた。optee_test 4.9.0-rc1 を使う Andes v9 の構成では、`regression_1039` は成功する。テストスイートは変更していない。

## 6. 閉幕チェック：証拠の保全

`gate03_closure_check.sh` は、ソースとイメージに対しては読み取り専用である。次のことを行った。

- 原本ログのディレクトリを 700、ファイルを 600 にした。
- 実行したスクリプトのうち、実行時に記録したハッシュと一致するものを、`logs/gateNN/as-run/` にコピーした。
- G02 の成果物を改めて確認し、変化した `sdcard.img` を保全した。
- 1039 の対照試験を行った（5章）。

## 7. そのほかの観察

| 観察 | 説明（G04） |
|---|---|
| U-Boot が `optee optee: OP-TEE api uid mismatch` を表示する | U-Boot の OP-TEE ドライバには SMC 方式の呼び出し経路しかないが、この設計では OP-TEE には MPXY 経由でしか到達できない。U-Boot 自身は OP-TEE を使えないが、Linux には影響しない。 |
| OP-TEE が `CPU node does not have 'reg' property` を表示する | CPU ではない `/cpus/cpu-map` のノードについて表示されている。2つのハートの ID はどちらも集められるので、無害である。 |
| コンソール操作スクリプトが、失敗した1ケースを3回数えた（`failed_checks=3`） | 表示上の問題：終了コード、失敗したサブテスト、失敗したケースを別々に数えている。判定には影響しない。 |

## 8. 公式手順からの逸脱

1. SSH のポート転送は、すべてのインターフェースではなく `127.0.0.1` で待ち受ける。これは生成したローカルのコピーで行い、上流の `start-qemu.sh` は変更していない。
2. コンソールの操作を、手作業の入力ではなく自動化した。ゲストで実行するコマンドは同じである。

## 9. まとめ

固定した RP016 M1 の commit からビルドした RISC-V の OP-TEE のスタックは、QEMU 10.1.93 で起動する。ブートチェーンは、U-Boot SPL → 3つのドメインを持つ OpenSBI v1.6 → trusted ドメインで両方のハート上に OP-TEE OS → U-Boot → untrusted ドメインの Linux 6.16.0-rc2 である。

引数の要らない5つの `optee_examples` はすべて成功し、`xtest` は111ケース中110件（33,601のサブテスト中33,599件）が成功した。失敗したケース regression_1039 は、テストスイートの署名済みサブキー（RSA-2048）と OP-TEE OS の既定の鍵（RSA-4096）の版の不一致で説明できる。

- 1039.1 は実証済み。
- 1039.2 は強く裏付けられている。
- 新しい構成では解消している（G05c）。

4つの「OK」は、このプラットフォームの機能を試していない（2つは Arm 専用、2つは未試験）。この実行では `sdcard.img` が書き換わったが、以降の実行では `-snapshot` で防いでいる。
