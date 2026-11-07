# G02 — 固定したソースによる Buildroot のビルド

| 項目 | 内容 |
|---|---|
| プロジェクト | RISC-V-OP-TEE-On-QEMU-Reproduction |
| 基準 | RISE RP016 Milestone 1（`rp016_m1`）、commit の SHA で固定 |
| 実施日 | 2026-11-06 |
| 結果 | **PASS**：ビルドが完了し、検証済み（失敗したコマンド 0件） |
| ビルド時間 | 19分52秒（`make -j20`、CPU 20 スレッド） |
| スクリプト | `scripts/gate02_build.sh`（sha256 `609db2e9747802d8b0e691d8918c932b8807d9702cb19dac585453921c1bada8`） |
| ログ | `logs/gate02/gate02_build_20261106-205938.log`（make の全出力は `gate02_make_20261106-205938.log.gz`。3.5 節） |
| 改訂 | 2026-11-07、公開（G06）に向けて：ビルドのログの致命的でないメッセージ、検証の範囲、`sdcard.img` の注記、再現性の表現、G03 への申し送りのその後 |

英語版は `G02_buildroot_build.md`。

## 1. 目的

G01 で記録した commit から、Buildroot ですべてのイメージをビルドする。実際に使われたソースが、それらの commit と一致することの証拠を記録する。

## 2. 手順

### Step 1（任意）. ホストのメモリを確認する

```bash
cd ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction
bash scripts/gate02_memory_check.sh
```

このスクリプトは読み取り専用である。プロセスを止めず、`sudo` を使わず、キャッシュも破棄しない。次の内容を報告する。

- `/proc/meminfo` の内訳
- 常駐メモリとスワップの使用量が多いプロセス（プログラム名ごとに集計）
- cgroup ごとのメモリ（自分のセッション、ほかのユーザー、システムのサービス）
- tmpfs の使用量

プロセスの所有者は `me` / `root` / `system` / `other-user` としてだけ表示し、コマンドラインは表示しない。

### Step 2. 準備する（コンパイルはしない）

```bash
bash scripts/gate02_build.sh --prepare-only
```

事前の確認、`custom/` のチェックアウトの固定、設定の書き出しを行い、ビルドの前で止まる。

### Step 3. ビルドして検証する

```bash
bash scripts/gate02_build.sh
```

SSH の接続が切れてもビルドが止まらないよう、`tmux`（または `screen`）の中で実行する。下の 1〜3 は、ビルドの開始前にもう一度手早く実行される。

スクリプトの動作：

1. **事前の確認**：利用可能なメモリ（4 GiB 未満なら停止）とディスクの空き（30 GiB 未満なら停止）を確認する。あわせて、`.gitignore` の内容、Buildroot の `HEAD` が固定した SHA であること、Buildroot のツリーで追跡ファイルが変更されていないこと、`local.mk` の記述を確認する。
2. **`custom/` のチェックアウトを固定する**：QEMU、OpenSBI、OP-TEE OS、bm-app を clone し、`git checkout -B rp016_m1 <固定する SHA>` を実行する。後で `local.mk` のフックが `git fetch` と `git checkout rp016_m1` を実行するが、`git fetch` はローカルブランチを動かさないので、`local.mk` を編集しなくても固定が保たれる。
3. **設定する**：上流の `qemu_riscv64_virt_optee_defconfig` を適用する。その後、`utils/config` で `BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION` と `BR2_TARGET_UBOOT_CUSTOM_REPO_VERSION` をそれぞれの SHA にし、`make olddefconfig` を実行する。この順序が重要で、defconfig をもう一度適用すると、この2つのバージョンが元に戻ってしまう。
4. **ビルドする**：公式手順と同じく `make -j$(nproc)` を実行する。全出力はログファイルに書き、画面には Buildroot の `>>>` の段階と、`local.mk` の `[BR]` のメッセージだけを時刻付きで表示する。
5. **検証する**：実際に使われた commit、必要な成果物とその sha256、Buildroot がビルドしたホスト用の QEMU を確認する。

### Step 4. 結果を確認する

```bash
LOG="$(ls -t logs/gate02/gate02_build_*.log | head -n 1)"
grep -nE '^\[rc=[1-9]|\[NG\]' "$LOG"        # 何も出なければ失敗なし
sed -n '/===== 9. Summary/,$p' "$LOG"
```

### 実行履歴

| 時刻 | 実行 | 結果 |
|---|---|---|
| 20:20、20:34 | `gate02_memory_check.sh` | 利用可能なメモリは 12.8〜13.1 GiB。最も多く使っていたのはデスクトップの Web ブラウザ。システムのサービスやほかのユーザーは関係していなかった |
| 20:43 | `gate02_build.sh --prepare-only` | PREPARED。実際の Buildroot で固定を確認した（`LINUX_VERSION` / `UBOOT_VERSION` = SHA、OpenSBI / OP-TEE OS / QEMU = `custom`） |
| 20:59 | `gate02_build.sh` | **BUILD COMPLETED AND VERIFIED**。開始時に利用可能なメモリは 16 GiB |

## 3. 結果

### 3.1 実際に使われた commit

| コンポーネント | 証拠 | commit |
|---|---|---|
| Buildroot | `git rev-parse HEAD`（事前の確認） | `d7204671a32ca2edc521c35de758ce650ebf1cb6` |
| Linux | ビルドディレクトリ `output/build/linux-<SHA>`、ダウンロード `dl/linux/linux-<SHA>-git4.tar.gz` | `2912ca616fc806dbeeba2e1ac7a157e0843d6987` |
| U-Boot | ビルドディレクトリ `output/build/uboot-<SHA>`、ダウンロード `dl/uboot/uboot-<SHA>-git4.tar.gz` | `32bdb252fab83028768a269fb304b9356547ccbd` |
| QEMU（ホスト用） | `custom/qemu`：ビルド後の HEAD = ローカルの `rp016_m1` | `9c23f2a7b0b45277693a14074b1aaa827eecdb92` |
| OpenSBI | `custom/opensbi`：ビルド後の HEAD = ローカルの `rp016_m1` | `cdd401f1517b4599b7d08ce13cd83859acc4cbb2` |
| OP-TEE OS | `custom/optee-os`：ビルド後の HEAD = ローカルの `rp016_m1` | `814978eb15b92c3b97255a8c000f44cd84aac008` |
| bm-app | `custom/bm-app`：ビルド後の HEAD = ローカルの `rp016_m1` | `97545c35a74ad387f7790b02a35b0f2b4d29bb6e` |

ビルド中、`local.mk` のフックはいずれも「dev tree exists. Fetching updates... Checking out rp016_m1」と表示した。ビルドの後も、4つのチェックアウトはすべて固定した SHA にあり、追跡ファイルの変更も無かった。これにより、事前に作ったローカルブランチが、フックを通過しても固定を保つことが確認できた。

**この検証の範囲**：各チェックアウトについて、`HEAD` と*追跡ファイル*の変更を確認した。サブモジュールの commit と未追跡ファイルは記録していない。*（外部レビューを受けて、改訂で追記。）*

上書きしたパッケージは、`output/build/host-qemu-custom`、`output/build/opensbi-custom`、`output/build/optee-os-custom` でビルドされた。OP-TEE のユーザー空間のパッケージ（optee_client、optee_test、optee_examples）はバージョン 4.6.0 で、Buildroot のハッシュファイルで検証された上流の tarball から取得している。

### 3.2 成果物（`output/images`）

| ファイル | サイズ（バイト） | sha256 |
|---|---:|---|
| `u-boot-spl` | 1,268,440 | `8758196e225812389df1eafe83875c0d6f988d0359ec71b25c0db1105bb06d9d` |
| `u-boot.itb` | 1,601,867 | `a5fde1f241b7308ecb189c699187c8c150ac0b1b27d98d7b55e1d977afb741a9` |
| `u-boot.bin` | 635,260 | `7068bd390cb098067a275f8975d938e3418e0a8000b93206a7bd5ead3594edfd` |
| `fw_dynamic.bin` | 273,120 | `10705fa71fd848c6c4c887f747ffeeead03614235933c0ba4fbecb489c3001f6` |
| `fw_dynamic.elf` | 1,747,648 | `9833f9b16b8fa0469722a84a01e6b5b81e9727e36cdd3ba3c7e24ca4d018ae06` |
| `fw_jump.bin` | 273,080 | `de9eabd5c9a89a5e92d696234555d2dae1fff8a925836d7cf66714f349eb2fef` |
| `fw_jump.elf` | 1,747,224 | `1d824dbeac50d71fcbc8265f0b158238112e601983ab9175c9c31d1b6da41715` |
| `tee.bin` | 696,880 | `2fe97c472ac8c05c07e6a959af501c0260fd76d5b6f27749a188844b69b4c360` |
| `Image` | 27,386,880 | `66e13d43d5071e1cc44245683c192d5f74534c9fa55f9b7c6fd463dbcaa3e8ef` |
| `qemu_rv64_virt_domain.dtb` | 6,907 | `6e1e8c35e2d2b610ceb69b783e7f96ab6bdf92778855fe4f541b02ebd3697294` |
| `rootfs.ext2` | 272,629,760 | `2f1d2e1e33876fc22e047564a0abf42142f30e9a8abd38ecf3e716391aa1d49c` |
| `rootfs.tar` | 134,717,440 | `7a9480377aa0075fc625c72a7c7b856e509884acfc5e0c638b4ca9620793a9cf` |
| `sdcard.img` | 272,630,272 | `cebd9fe83b05be19dfc1064a5736120067dc15501bbf64005f3b37bfdfc4f23b`（ビルド直後の値。後で G03 の起動により変化。下の注記） |
| `bm-app.elf` | 17,592 | `99fac1d9a5f458e7baff9120638458ed5e8b5a8a379dbb93c73f3ba5eb583225` |
| `start-qemu.sh`、`start-qemu-bm.sh` | — | ハッシュは取らない（`output/host` のホスト上の絶対パスを含むため） |

成果物には時刻やパスが含まれるため、ホストやビルドの日時が違えばバイト単位では一致しないと考えられる。ここでのハッシュは、このビルドを識別するためのものであって、再現性の目標値を定めるものではない。

**`sdcard.img` についての注記**：G03 の起動は `-snapshot` を使わず、ゲストのルートファイルシステムを読み書き可能でマウントしたため、その後 `sdcard.img` が変化した（`dec31312…`）。ほかの13個の成果物は改めて確認し、変化していなかった。それ以降の起動（G05a〜G05c）はすべて QEMU の `-snapshot` を使い、イメージのハッシュが変わらないことを確認している。

### 3.3 ホスト用の QEMU

`output/host/bin/qemu-system-riscv64 --version` は **QEMU emulator version 10.1.93** を報告した。`custom/qemu` の `9c23f2a7…` からビルドされたものである。起動スクリプトは `output/host/bin` を `PATH` の先頭に置くので、ディストリビューションの QEMU（8.2.2）ではなく、この QEMU が使われる。G03 で、実行時にそのことを確認した。

### 3.4 資源の使用量

| 項目 | 値 |
|---|---|
| `output/` | 19 GB |
| `dl/`（ダウンロード） | 7.2 GB |
| `custom/`（git のチェックアウト） | 4.4 GB |
| ビルド開始時に利用可能なメモリ | 16 GiB |

### 3.5 ビルドの出力にある致命的でないメッセージ

`make` は終了ステータス 0 で終わった。ただし全出力には、エラーのように見えるが、ビルドを止めなかったメッセージが含まれている。

- zlib の主たるダウンロード先が HTTP 404 を返し、Buildroot は予備のミラーから tarball を取得した（tarball は Buildroot のハッシュファイルで検証される）。
- `make` が「無視した」と報告しているエラーが2件ある。

make の全出力は、整理して gzip で圧縮したコピー（`gate02_make_20261106-205938.log.gz`）として公開する。ダウンロードの URL のクエリ文字列（期限付きの署名を含む）、ANSI の色付けのシーケンス、タイムゾーンは除去してある。*（改訂で追記。）*

## 4. 公式手順からの逸脱

公式手順は、ブランチの名前（`rp016_m1`）からビルドする。この再現では、2026-11-06 にそれらのブランチが指していた commit からビルドする。

- 上流の `local.mk` と defconfig は変更しない。
- SHA にするのは、`.config`（Linux、U-Boot）と、各 `custom/` のチェックアウトのローカルブランチだけである。

したがって、ソースはその日に公式手順が使ったものと同じであり、ブランチが動いた後も変わらない。これはソースのレベルの再現であり、バイナリの完全一致ではない（G01 の4章）。*（改訂：最初の版では、内容が同一になると主張していた。）*

## 5. G03 への申し送り

| 項目 | 計画 | その後 |
|---|---|---|
| SSH のポート転送 | 生成された `start-qemu.sh` には `hostfwd=tcp::2200-:22` があり、ホストのすべてのインターフェースで待ち受ける。代わりに `127.0.0.1` に限定したローカルのコピーから起動し、その変更を記録する。 | G03 と、それ以降のすべての起動で対応した。 |
| ゲストの SSH サーバー | ルートファイルシステムに SSH サーバーが含まれているかを確認する。 | 確認済み：インストールされていないので、ポート 2200 はどこにもつながらない。 |
| セミホスティング | OP-TEE のコンソールが依存しているので残す。QEMU は一般ユーザーで、このゲストだけで実行する。 | 対応済み。 |
| コンソール | OP-TEE は、QEMU を実行している端末にセミホスティングで出力する。OpenSBI、U-Boot、Linux は TCP ポート 64320 を使い、QEMU は起動の前にその接続を待つ。両方のコンソールを記録する必要がある。 | 対応済み：両方を別々に記録している。 |

## 6. まとめ

一式のイメージ（U-Boot SPL / U-Boot の FIT イメージ、OpenSBI、OP-TEE OS、Linux、ルートファイルシステム、SD カードのイメージ、ベアメタルの試験用アプリ）を、固定した commit から約20分でビルドした。すべてのコンポーネントが、固定した commit からビルドされたことを確認した。Buildroot がビルドした QEMU 10.1.93 は、G03 の起動と `xtest` の実行に使える状態になっている。
