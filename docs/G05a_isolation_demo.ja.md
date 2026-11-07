# G05a — 隔離の実証とベアメタルアプリ（RP016 M1 のイメージ）

| 項目 | 内容 |
|---|---|
| プロジェクト | RISC-V-OP-TEE-On-QEMU-Reproduction |
| 使用したイメージ | G02 でビルドした M1 のイメージ（再ビルドなし）。すべての起動で QEMU の `-snapshot` を使い、`sdcard.img` は書き換えていない |
| 実施日 | 2026-11-07 |
| 結果 | **例外付きの完了**。PMP による隔離を実行時に実証した。U-Boot からの OP-TEE 領域の読み出しは取得できなかった（4章） |
| スクリプト | `scripts/gate05a_isolation.sh`（sha256 `4dcbde9b…`）、`scripts/gate05a_console.py`（sha256 `3ec32a25…`） |
| ログ | `logs/gate05/gate05a_isolation_20261107-120926.log`。ほかに、起動ごと（U1、U2、L）のコンソールログと QEMU ログ、bm-app のログ |

英語版は `G05a_isolation_demo.md`。

## 1. 目的

G04 では、「PMP による隔離が実行時に強制されること」を「実証していない」とした。G05a では、再現した M1 のイメージを使い、untrusted ドメインで動くコードが OP-TEE と OpenSBI のメモリを読めないことを示す。あわせて、M1 の公式手順で残っていたベアメタル SBI アプリの実行を行う。

## 2. 手順

```bash
cd ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction
bash scripts/gate05a_isolation.sh --prepare-only    # 安全確認のみ（QEMU は起動しない）
bash scripts/gate05a_isolation.sh                   # 3回の起動 + bm-app
```

**方法**：読み出しだけを使い、ゲストのメモリには一切書き込まない。

| 起動 | 方法 | 対照（読めるべき） | 試験（拒否されるべき） |
|---|---|---|---|
| U1 | U-Boot の自動起動を止め、`md.l <addr> 4` を実行 | `0x80200000`（通常の RAM） | `0xF1000000`（OP-TEE） |
| U2 | U1 と同じ | `0x80200000` | `0x80100000`（OpenSBI） |
| L | Linux にログインし、`devmem <addr> 32` を実行 | `0x0C000004`（PLIC のレジスタ） | `0xF1000000`、`0x80100000` |
| BM | `start-qemu-bm.sh` を実行し、公式手順の最終行が出たら停止 | — | — |

2つの経路を使う理由：

- **U-Boot** は Linux と同じく、untrusted ドメインの S モードで動く。しかも `/dev/mem` のような制限を持たないため、読み出しが拒否されれば、ハードウェアの検査がそのまま現れる。
- **Linux** では、ユーザー空間から確かめる。`devmem` は物理ページを `mmap` で割り当てるので、アクセスが拒否されても `devmem` が終了するだけで、カーネルは止まらない。このカーネルは `CONFIG_STRICT_DEVMEM` が無効なので、Linux 自身がアクセスを止めることもない。

**安全対策**（G03 から引き継いだもの）：

- root での実行は拒否する。
- Buildroot でビルドした QEMU だけを使う。
- 上流の `start-qemu.sh` を、待受を `127.0.0.1` に限定したコピーから起動し、ポートが `127.0.0.1` に結び付いていることを確認する。
- 終了時や `Ctrl-C` のときは、必ず QEMU を止める。
- QEMU のコマンドラインに `-snapshot` があることと、`sdcard.img` のハッシュが実行の前後で同じであることを確認する。

`start-qemu.sh` は、自身のオプションを先に解釈する。そのため、QEMU に渡す引数は `start-qemu.sh -- -snapshot` のように `--` の後ろに置く必要がある。

### 実行履歴

| 時刻 | スクリプト | 結果 |
|---|---|---|
| 12:01:16 | v1、`--prepare-only` | READY |
| 12:01:36 | v1 | `-snapshot` を `--` なしで渡したため、`start-qemu.sh` がこれを拒否し、QEMU は起動しなかった（`sdcard.img` は変化なしで安全）。bm-app は実行され、公式手順と一致した |
| 12:09:26 | v2 | U1：起動が停止。U2：完了。L：完了。BM：公式手順と一致。`sdcard.img` は変化なし |

## 3. 結果

### 3.1 読み出しの結果

| 対象 | U-Boot から（S モード、untrusted ドメイン） | Linux のユーザー空間から（`devmem`） |
|---|---|---|
| 対照 | `0x80200000`：**読めた**（`edfe0dd0…`。QEMU が置いた FIT イメージの FDT マジック） | `0x0C000004`：**読めた**（`0x00000001`） |
| OP-TEE `0xF1000000` | **未取得**（U1 の起動が停止。4.1 節） | **拒否**：`Segmentation fault`。カーネルの報告は `cause: 0x5` |
| OpenSBI `0x80100000` | **拒否**：`Unhandled exception: Load access fault`、`TVAL: 0x80100000` | **拒否**：`Segmentation fault`。カーネルの報告は `cause: 0x5` |

### 3.2 主な証拠

U-Boot（U2）で、OpenSBI の領域を読んだときの出力：

```
=> md.l 0x80100000 4
Unhandled exception: Load access fault
EPC: 000000017f7b17aa RA: 000000017f7b1706 TVAL: 0000000080100000
```

Linux（L）で、OP-TEE の領域を読んだときの出力（OpenSBI の領域でも同じ内容が出た）：

```
devmem[135]: unhandled signal 11 code 0x2 at 0x0000555557315ca4 in busybox[...]
status: 0000000200004020 badaddr: 00007fff7fce9000 cause: 0000000000000005
```

Linux から見た2つの領域（`/proc/iomem`）：

```
80100000-8015ffff : Reserved
f1000000-f1ffffff : Reserved
```

### 3.3 解釈

- **`cause 5` はロードアクセスフォルトであり、ページフォルト（`cause 13`）ではない。** `devmem` の割り当ては Linux のページテーブル上では有効だったが、物理アドレスへのアクセスが拒否された。この構成で、正常な RAM の読み出しをこのように拒否する仕組みは、OpenSBI がドメインの設定に基づいて設定する PMP だけである（G04 の A2、A5）。
- **U-Boot でも、S モードで同じ拒否が起きた。** `Load access fault` が報告され、`TVAL` には違反した物理アドレスが入っている。
- **対照の読み出しにより、アクセス経路そのものの故障ではないことを確認した。** どちらの経路でも、許可されたアドレスは読めた。

**判定：untrusted ドメインから OP-TEE と OpenSBI の領域への PMP による隔離を、実行時に実証した。**

- OP-TEE の領域：Linux 経由で拒否を確認した。
- OpenSBI の領域：U-Boot 経由と Linux 経由の両方で拒否を確認した。

スクリプトの自動判定は `INCONCLUSIVE` だった。判定の条件に「U-Boot からの OP-TEE 領域の読み出し」が含まれていたが、それが別の理由（4.1 節）で取得できなかったためである。上の判定は、ログを検討したうえでの判定である。

### 3.4 ベアメタル SBI アプリ

出力の最後は、RP016 のビルド手順に「期待される出力の最後」として記載されている5行と完全に一致した。

```
Welcome to OpenSBI bare-metal app!
SBI Spec Version: 3.0
SBI Implementation: OpenSBI
OpenSBI Version: 1.6
Init timer successfully 10000000 ticks/s
```

このアプリは QEMU の電源を切らないため、この行が出た後にスクリプトが QEMU を停止する。この実行は `fw_jump` を使い、ドメインは root だけ、ファームウェアは `0x80000000` に置かれる。OP-TEE 用の構成とは配置が異なる。

## 4. 観察事項

### 4.1 hart 1 が最初に起動したときの停止（U1）

U1 では、OpenSBI が `Boot HART ID : 1` と報告した。OP-TEE は `Primary CPU0 (hart0) initialized` を出力した後に止まり、2つ目のハートの起動にも、U-Boot の起動にも進まなかった。コンソール操作のスクリプトは600秒でタイムアウトした。

本プロジェクトのそれ以外の起動（G03、U2、L）では、最初に起動したハートは hart 0 で、正常に起動した。QEMU では、どちらのハートが最初に起動するかは毎回変わる。

| 項目 | 状態 |
|---|---|
| 4回の起動のうち1回で停止し、それは hart 1 が最初に起動した回だけだった | 観察した |
| 最初に起動したのは hart 1 なのに、OP-TEE は `hart0` を primary として報告した | 観察した |
| 原因（例：起動時のハート ID の扱い） | 調査していない |

### 4.2 アクセス違反の後のリセット（U2）

アクセス違反の後、U-Boot はシステムをリセットする。その2回目の起動で、OP-TEE が `Page is already mapped`（`core/mm/core_mmu.c:2008`）で panic した。1回目の起動の状態が RAM に残っていたためと考えられる。これは隔離の試験の範囲外で、QEMU はスクリプトが停止した。

### 4.3 この試験で示せないこと

- 試したのは読み出しだけで、書き込みや命令の取り出しは試していない。
- DMA を行うデバイスからのアクセスは試していない。PMP はハートからのアクセスだけを対象とし、M1 には IOPMP がない。
- 試したのはこのビルドだけである。後続のマイルストーンは G05b と G05c で扱う。

## 5. まとめ

再現した M1 のイメージで、untrusted ドメインから OP-TEE の領域と OpenSBI の領域への読み出しが、アクセス違反で失敗することを確認した。

- Linux のユーザー空間からは、両方の領域で拒否された（`cause 5`）。
- U-Boot の S モードからは、OpenSBI の領域で拒否された（`Load access fault`）。

許可された対照のアドレスは読めた。これにより、G04 で「実証していない」とした「PMP の実行時の強制」を「実証済み」に改めた。ただし例外が1件あり、U-Boot からの OP-TEE 領域の読み出しは、hart 1 が最初に起動したときに観察された不定期な起動停止のため、取得できなかった。

ベアメタル SBI アプリは、公式手順に記載された出力をそのまま再現した。
