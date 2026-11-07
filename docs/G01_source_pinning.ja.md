# G01 — ソースの取得とバージョンの固定

| 項目 | 内容 |
|---|---|
| プロジェクト | RISC-V-OP-TEE-On-QEMU-Reproduction |
| 基準 | RISE RP016 Milestone 1（`rp016_m1`） |
| 実施日 | 2026-11-06 |
| 結果 | **PASS**（失敗したコマンド 0件） |
| スクリプト | `scripts/gate01_fetch_sources.sh`（sha256 `ad843b3352e00e5786b125dce7aa95441092ac34508658b04342e84c24cee7ae`） |
| ログ | `logs/gate01/gate01_fetch_sources_20261106-192647.log` |
| 改訂 | 2026-11-07、公開（G06）に向けて：ブートチェーンの説明、再現性の表現、後続の Gate への申し送りのその後 |

英語版は `G01_source_pinning.md`。

## 1. 目的

Buildroot の統括プロジェクトを取得し、すべてのコンポーネントについて、ソースの取得元、使うブランチやバージョン、それが指す commit を特定する。この Gate では何もビルドしない。

## 2. 手順

### Step 1. 調査用のスクリプトを実行する

```bash
cd ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction
bash scripts/gate01_fetch_sources.sh
```

スクリプトの動作：

- RISE の `riscv-optee` グループにある7つのリポジトリについて、リモートのブランチを記録する。
- Buildroot（`rp016_m1`）を `work/buildroot` に clone する。2回目以降は、既存の clone を再利用する。
- defconfig が参照するすべてのブランチ名を、commit の SHA に解決する。
- `make qemu_riscv64_virt_optee_defconfig` と `make printvars` を実行する。どちらも設定の段階だけで、パッケージのダウンロードやビルドはしない。
- ソースの上書きの仕組み（`local.mk`）と、QEMU の起動スクリプトの元になるファイルを表示する。

ログの扱い：

- すべてのコマンドについて終了コードを記録する（`[rc=N]`）。最後に失敗の件数と判定を出し、失敗があれば 0 以外の終了ステータスで終わる。
- `pipefail` を有効にしているので、ログのパイプラインの途中の失敗も隠れない。
- 公開用のログはマスク済み（ホームディレクトリのパス、ユーザー名、ホスト名、IPv4 / MAC のアドレス、メールアドレス）。
- マスクしていない原本のログは、ローカルの `logs/gate01/raw/` に保全し、公開しない。その横の sha256 のマニフェストが、原本のログ、マスク済みのログ、ブランチの一覧、スクリプト自体を対象にしている。

### Step 2. 結果を確認する

```bash
LOG="$(ls -t logs/gate01/gate01_fetch_sources_*.log | head -n 1)"
grep -nE '^\[rc=[1-9]|\[NG\]' "$LOG"        # 何も出なければ失敗なし
sed -n '/===== 9. Summary/,$p' "$LOG"
```

ログとスクリプトの完全性の確認（ローカルのみ）：

```bash
sha256sum -c logs/gate01/raw/gate01_fetch_sources_<timestamp>.sha256
```

### 実行履歴

| 実行 | スクリプトの変更 | 結果 |
|---|---|---|
| 2026-11-05 21:48 | 最初の版 | 起動スクリプトの検索範囲が広すぎた。QEMU と OP-TEE のユーザー空間のバージョンが解決できなかった |
| 2026-11-05 21:58 | 6節と7節を書き直し | `custom/` によるソースの上書きが判明した。`.config` のパスはまだ誤っていた |
| 2026-11-06 19:26 | 6b 節を追加、`.config` のパスを修正、終了コードの記録、原本ログと sha256 のマニフェスト | **最終：完了条件をすべて満たした** |

正式なのは最後の実行だけである。最初の2回は出力をその場でマスクしていたため、原本の出力は残っていない。

## 3. 結果

### 3.1 Buildroot のフォーク

| 項目 | 内容 |
|---|---|
| リポジトリ | https://gitlab.com/riseproject/riscv-optee/buildroot.git |
| ブランチ | `rp016_m1` |
| commit | `d7204671a32ca2edc521c35de758ce650ebf1cb6`（2025-12-15、"make: point all repos to RISE Gitlab"） |
| 土台 | 上流の Buildroot 2025.05 のリリースの commit（`fcde5363aa`、2025-06-09）と見られる。`git describe` が `2024.08-3681-…` と表示するのは、フォークにそれ以降の上流のタグが無いためにすぎない |

`rp016_m1` の系譜：

- **Andes の作業（2025-06-22/23）**：`riscv64-virt-optee` のボードと defconfig を追加。その後、BSP のバージョンを v6 まで上げ、commit `21c6de2d77` に至る。この commit は `dev-optee-mpxy-v6` ブランチの先端である。
- **RISCstar の commit（2025-12-01〜2025-12-15）**：その上に6つの commit。各コンポーネントを git のリポジトリから取得するように変え、`local.mk`（ローカルでのソースの上書き）を追加し、ベアメタルアプリのビルドを加え、最後にすべての URL を RISE の GitLab に切り替えている。

### 3.2 コンポーネントの取得元と固定の方法

| コンポーネント | 取得の経路 | 参照 | commit（2026-11-06） | 固定の方法（G02 で適用） |
|---|---|---|---|---|
| Buildroot | `git clone` | `rp016_m1` | `d7204671a32ca2edc521c35de758ce650ebf1cb6` | clone で固定済み。HEAD を確認する |
| Linux | Buildroot の custom git（`BR2_LINUX_KERNEL_CUSTOM_REPO_*`） | `rp016_m1` | `2912ca616fc806dbeeba2e1ac7a157e0843d6987` | defconfig を適用した後、`.config` でバージョンを SHA にする |
| U-Boot | Buildroot の custom git（`BR2_TARGET_UBOOT_CUSTOM_REPO_*`） | `rp016_m1` | `32bdb252fab83028768a269fb304b9356547ccbd` | Linux と同じ |
| OpenSBI | `local.mk` による上書き → `custom/opensbi` | `rp016_m1` | `cdd401f1517b4599b7d08ce13cd83859acc4cbb2` | `custom/opensbi` に、SHA の位置でローカルブランチ `rp016_m1` を事前に作る |
| OP-TEE OS | `local.mk` による上書き → `custom/optee-os` | `rp016_m1` | `814978eb15b92c3b97255a8c000f44cd84aac008` | OpenSBI と同じ |
| QEMU（ホスト用） | `local.mk` による上書き → `custom/qemu` | `rp016_m1` | `9c23f2a7b0b45277693a14074b1aaa827eecdb92` | OpenSBI と同じ |
| bm-app | `local.mk` の finalize フック → `custom/bm-app` | `rp016_m1` | `97545c35a74ad387f7790b02a35b0f2b4d29bb6e` | OpenSBI と同じ |
| optee_client / optee_test / optee_examples | 上流の GitHub の tarball | `4.6.0` | — | バージョンで固定され、Buildroot のハッシュファイルで検証される |
| ツールチェーン | Bootlin のビルド済み tarball | `riscv64-lp64d--glibc--bleeding-edge-2024.05-1` | — | バージョンで固定され、Buildroot のハッシュファイルで検証される |

そのほかに解決した設定：カーネルのヘッダは 5.15 以上。ターゲット上では、`tee-supplicant` は `/data/tee` を使い、RPMB のエミュレーションが有効になっている。

### 3.3 `local.mk` による上書きの仕組み

Buildroot は、ツリーの最上位にある `local.mk` を読み込む（既定の `BR2_PACKAGE_OVERRIDE_FILE`）。QEMU、OpenSBI、OP-TEE OS について、このファイルは次の2つを行う。

- `<PKG>_OVERRIDE_SRCDIR` を `custom/<name>` に設定する。
- rsync の前に実行されるフック `PREPARE_GIT_TREE` を登録する。このフックは次の処理を行う。
  1. ディレクトリに `.git` が無ければ `git clone --recursive <url>`、あれば `git fetch --all --tags`。
  2. `git checkout <branch>`
  3. `git submodule update --init --recursive`

bm-app も同じ方法で準備されるが、こちらは `TARGET_FINALIZE_HOOKS` から呼ばれる。同じフックが続けて bm-app をビルドし、`start-qemu-bm.sh` を生成する。

再現性への影響：

1. **OpenSBI と OP-TEE OS については、defconfig のバージョンは使われない。** `BR2_TARGET_OPENSBI_CUSTOM_REPO_VERSION` と `BR2_TARGET_OPTEE_OS_CUSTOM_REPO_VERSION` は迂回される。上書きがあると、Buildroot はそのパッケージをダウンロードも展開もパッチ適用もしない。意味を持つのは `local.mk` のブランチだけである。
2. **フックは rsync のたびに実行され、ブランチの「名前」で checkout し直す。** そのため、手作業で checkout した commit（detached HEAD）は、次のビルドで黙って置き換えられる。一方、`git fetch` は既存のローカルブランチを動かさない。だから、固定する SHA の位置にローカルブランチ `rp016_m1` を事前に作っておけば、`local.mk` を編集しなくても安定して固定できる。
3. **フックは、ビルド時にネットワークへのアクセスを必要とする。** gitlab.com に対して `git clone` / `git fetch` を実行する。
4. **`custom/` のディレクトリは、最初のビルドの前には存在しない。** これは設計どおりで、フックが作る。
5. **host-qemu の configure 用のラッパーは、ビルド用のコピーだけを変更する。** `GIT_DIR` を解除するのは `output/build/host-qemu-custom` の中だけで、`custom/qemu` ではない。`local.mk` に破壊的なコマンド（`rm -rf` など）は含まれていない。

### 3.4 QEMU の起動スクリプト

ビルド時に、2つの起動スクリプトが生成される。

- **`output/images/start-qemu.sh`**：`board/qemu/post-image.sh` が生成する。`board/qemu/riscv64-virt-optee/readme.txt` の中の、`# qemu_riscv64_virt_optee_defconfig` という印が付いたコマンドラインと、テンプレート `board/qemu/start-qemu.sh.in` から作られる。
- **`output/images/start-qemu-bm.sh`**：ベアメタルアプリ用に `local.mk` が生成する。`fw_jump.bin` と `bm-app.elf` を起動し、シリアルポートと QEMU のモニタを手元の端末に割り当てる（`-serial mon:stdio`）。

どちらのスクリプトも、Buildroot の `output/host/bin` を `PATH` の先頭に加える。`start-qemu.sh` では、`--use-system-qemu` でこれを無効にできる。その結果、ディストリビューションの QEMU ではなく、Buildroot がビルドした QEMU が使われる。ただし Buildroot の QEMU が無いと、スクリプトは黙ってシステムの QEMU を使ってしまうので、ビルド後にその存在を確認する。

主なコマンドライン：

```
qemu-system-riscv64 -M virt -cpu rv64,zkr=on -dtb qemu_rv64_virt_domain.dtb -m 4096 -smp 2
  -semihosting-config enable=on,target=native -serial tcp:127.0.0.1:64320,server
  -bios u-boot-spl -device loader,file=u-boot.itb,addr=0x80200000
  -device virtio-blk-device,drive=hd0 -drive format=raw,file=sdcard.img,id=hd0,if=none
  -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp::2200-:22 -nographic
```

主なオプションの意味：

- **ブートチェーン**：QEMU の汎用ローダー（`-device loader`）が、ハートが動き出す前に、FIT イメージ `u-boot.itb`（OpenSBI、OP-TEE の `tee.bin`、U-Boot 本体をまとめたもの）を `0x80200000` に置く。`-bios` のファームウェアとして起動した U-Boot SPL は、RAM 上のそのイメージを読み（`CONFIG_SPL_RAM_DEVICE`）、各部分をそれぞれの読み込み先のアドレスへコピーする。*（改訂で訂正：最初の版では「SPL がイメージを読み込む」と書いていたが、SPL は QEMU がすでに RAM に置いたものを読むだけである。FIT の構成と U-Boot の設定は G04 で確認した。）*
- **ドメイン**：DTB `qemu_rv64_virt_domain.dtb` は Linux のツリーから来ており、OpenSBI のドメインの定義を含む（3つのドメイン。G04 で確認）。
- **コンソール**：OP-TEE はセミホスティング（`CFG_SEMIHOSTING_CONSOLE=y`）を通じて、QEMU を起動した端末に出力する。OpenSBI、U-Boot、Linux は UART を使い、UART はループバックの TCP ポート 64320 に出ている。
- **defconfig による OP-TEE の設定**：`0xF1000000` に 16 MiB、2コア、2スレッド。PLIC と 16550 UART は無効。

### 3.5 ブランチの調査からの所見

- `optee_os`、`opensbi`、`linux` では、`rp016_m1` は Andes の `dev-optee-mpxy-v6` と同じ commit を指している。`u-boot` では `dev-optee-mpxy-v5` と一致する。つまり、RP016 M1 の基準は、Andes の MPXY ベースの OP-TEE スタック（v6）である。
- `buildroot` では、`rp016_m1` と `rp016_m2` が同じ commit を指している。M2 の実際の作業は `rp016_m2_aplic*` のブランチにある。
- `qemu` では、`rp016_m1` は `master` と同一。異なるのは `rp016_m5` だけである。
- Andes の系列は `dev-optee-mpxy-v9` まで続いている。

## 4. 決定事項

1. すべてのコンポーネントを、3.2 節の表のとおり、取得の経路に応じた方法で固定する。`local.mk` と上流の defconfig は編集しない。
2. 固定する SHA は、2026-11-06 時点の `rp016_m1` ブランチの先端と同じである。したがって、**ソース**はその日に公式手順が使ったものと同じであり、後でブランチが動いても変わらない。ただし固定するのはソースであって、バイナリではない。ホストのツール、ダウンロードする tarball（Buildroot のハッシュファイルで検証される）、ビルド環境は異なりうるので、この再現はソースのレベルのものであり、バイナリの完全一致ではない。*（改訂：最初の版では、ビルドが同一になると主張していた。）*
3. G02 のビルドの後、すべての `custom/*` のチェックアウトが固定した SHA にあること、Linux と U-Boot がそれぞれの SHA で取得されたことを確認する。

## 5. 後続の Gate への申し送り

| Gate | 項目 | その後 |
|---|---|---|
| G02 | 3.2 節の方法で固定し、実際に使われた commit を確認する。Linux の履歴を含む大きなダウンロードと、`local.mk` のフックによるビルド時のネットワークアクセスを見込む。 | 完了：ビルドの後、7つのコンポーネントすべてが固定した SHA にあることを確認した。 |
| G03 | 起動の前に、`output/host/bin/qemu-system-riscv64` があることを確認する（システムの QEMU に黙って切り替わるのを防ぐため）。 | 完了：毎回の起動の前に確認した。 |
| G03 | `hostfwd=tcp::2200-:22` は、ホストのすべてのインターフェースで待ち受ける。`127.0.0.1` に限定し、記録した逸脱として扱う。 | 完了：毎回の起動で、`hostfwd=tcp:127.0.0.1:2200-:22` にした起動スクリプトのローカルのコピーを使う。上流のスクリプトは変更していない。 |
| G03 | OP-TEE のコンソールが依存しているため、セミホスティングは外せない。QEMU は一般ユーザーで、固定したソースからビルドしたゲストだけで実行する。 | 完了：スクリプトは root での実行を拒否する。 |
| G04 | `qemu_rv64_virt_domain.dts` の OpenSBI のドメインの定義を確認する。 | 完了：3つのドメイン。OP-TEE の領域は untrusted ドメインから拒否される（実行時の強制は G05a で実証）。 |

## 6. まとめ

7つのリポジトリすべてに `rp016_m1` ブランチがある。すべてのコンポーネントについて、ソースと commit を特定した。

QEMU、OpenSBI、OP-TEE OS、bm-app は、defconfig からは取得されない。`local.mk` がビルド時に作る `custom/` のチェックアウトから取得され、ブランチの名前で checkout し直される。そのため、記録した SHA の位置にローカルブランチを事前に作ることで固定する。Linux と U-Boot は `.config` で固定する。

起動スクリプトは、Buildroot がビルドした QEMU を使う。ホストの安全に関わる2つの項目（SSH のポート転送とセミホスティング）は、G03 に申し送った（いずれも対応済み。5章）。
