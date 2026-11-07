# G05b — RP016 M2（APLIC）と M3（VIRQ）：ビルドと割り込みの試験

| 項目 | 内容 |
|---|---|
| プロジェクト | RISC-V-OP-TEE-On-QEMU-Reproduction |
| 実施日 | 2026-11-07 |
| 結果 | **PASS**：2つのビルドが完了して検証済み。M2 と M3 の割り込みの試験は全項目が成功 |
| スクリプト | `scripts/gate05b_build.sh`（sha256 `6536d20a…`。前の版 `0e948eec…` は `logs/gate05/as-run/` に保全）、`scripts/gate05b_test.sh`（`4ad18fe8…`）、`scripts/gate05b_console.py`（`6f6e8bbc…`） |
| ログ | `logs/gate05/gate05b_m2_build_20261107-143028.log`、`gate05b_m3_build_20261107-145829.log`、`gate05b_m2_test_20261107-154518.log`、`gate05b_m3_test_20261107-154510.log`。ほかに、各試験の OpenSBI と Linux のコンソールログ |

英語版は `G05b_interrupts_m2_m3.md`。

## 1. 目的

M1 にはセキュア割り込みがない。OP-TEE は割り込みコントローラを持たず、foreign 割り込みが来ると通常側へ抜ける（G04 の D1〜D2）。RP016 は、後続の2つのマイルストーンで割り込みに取り組んでいる。

- **M2**：APLIC を使い、有線割り込みを M モードで処理できるようにする。
- **M3**：VIRQ を追加する。割り込みを、その持ち主である OpenSBI のドメインへ届け、必要ならハートをそのドメインへ切り替える。

G05b では、この2つをビルドし、それぞれの公式手順に書かれた試験を行う。

## 2. 手順

```bash
cd ~/projects/RISC-V-OP-TEE-On-QEMU-Reproduction
# G05b-1：ビルド（マイルストーンごとに別の作業ツリー）
bash scripts/gate05b_build.sh m2 --prepare-only
bash scripts/gate05b_build.sh m3 --prepare-only
bash scripts/gate05b_build.sh m2 && bash scripts/gate05b_build.sh m3
# G05b-2：割り込みの試験
bash scripts/gate05b_test.sh m3 --prepare-only
bash scripts/gate05b_test.sh m2 --prepare-only
bash scripts/gate05b_test.sh m3; bash scripts/gate05b_test.sh m2
```

### 2.1 ビルド

- **作業ツリーを分ける**：マイルストーンごとに専用の作業ツリーを使う（`work/buildroot-m2`、`work/buildroot-m3`）。基準となる M1 の作業ツリーは変更しない。
- **ダウンロードを共有する**：ダウンロード先は `work/dl-g05`。M1 の tarball をハードリンクで写して使う（git のキャッシュは除く）ので、M1 のダウンロード用ディレクトリは変わらない。Buildroot はダウンロードしたファイルを名前の変更で置き換え、その場で書き換えることはしない。
- **コンポーネントを読み取って固定する**：コンポーネントは `local.mk` と defconfig から読み取る。準備段階で各ブランチを commit SHA に解決し、pins ファイルに記録する。想定外のコンポーネントがあればスクリプトは停止する。固定の方法は G02 と同じ：
  - `custom/` の各チェックアウトには、固定した SHA でローカルブランチを作る。
  - Linux と U-Boot のバージョンは `.config` に設定する。
- **並列数を絞る**：ビルドは 2 並列で行う。トップレベルの `make -j2` と、`.config` のパッケージ内部の並列数 `BR2_JLEVEL=2` の両方を設定する。`-j` だけでは各パッケージの内部の並列コンパイルが絞られず、メモリ不足の恐れがあったため。ビルドはそれぞれ約28分だった。

### 2.2 試験

試験は、ビルドで実際に生成された起動スクリプト（ビルドのログに出力したもの）に基づいて設計した。

| 生成されたスクリプトの事実 | 試験への影響 |
|---|---|
| M2（`start-qemu-kernel.sh`）と M3（`start-qemu-bm-kernel.sh`）は、どちらも QEMU を2回起動する。1回目でデバイスツリーを書き出し、`dtc` と `fdtoverlay` でマイルストーンのオーバーレイを合成した後に、2回目で本起動する | ポートの確認は、2回目の QEMU が Linux のコンソールへの接続待ちを報告してから行う |
| オプションを解釈せず、QEMU の引数をそのまま渡す | `-snapshot` は `--` を付けずに渡す（M1 の `start-qemu.sh` とは逆） |
| QEMU を `exec` しない | プロセスグループ全体を管理し、終了時や `Ctrl-C` のときは必ず停止する |
| `hostfwd=tcp::2200-:22` が全インターフェースで待ち受ける（M2 は1か所、M3 は2か所） | `127.0.0.1` に限定したローカルのコピーから起動する（上流のスクリプトは変更しない） |
| OpenSBI とベアメタルアプリは QEMU の標準入出力のコンソール、Linux は TCP `127.0.0.1:64321` の virtio コンソールを使う | キーは QEMU の標準入力（FIFO）に書き込み、Linux は TCP のコンソール経由で操作する |

安全対策（G03 / G05a と同じ）：

- root での実行は拒否する。
- Buildroot でビルドした QEMU だけを使う。
- 待ち受けるポートはすべて `127.0.0.1` でなければならない。
- QEMU のコマンドラインに `-snapshot` があることを確認する。
- `sdcard.img` のハッシュを、実行の前後で比べる。

合格の判定には、公式手順に書かれた出力をそのまま使う。

準備段階で「オーバーレイの合成の工程があるか」を確認したのは M3 だけだった。M2 にも同じ工程があることは、ビルドのログで後から確認した。試験はプロセスグループ全体を管理しているため、この工程があっても正しく動いた。

## 3. M1 との違い（固定した commit）

| コンポーネント | M1 | M2 | M3 |
|---|---|---|---|
| Buildroot | `d7204671`（`rp016_m1`） | `8fba3ebe`（`rp016_m2_aplic_up_v2`） | `f2e760ef`（`rp016_m3_virq_up_v1`） |
| **OpenSBI** | `cdd401f1`（v1.6） | **`4533a2a9`**（`rp016_m2_aplic_up_v2`、v1.8） | **`7ca03a0f`**（`rp016_m3_virq_up_v1`、v1.8） |
| **bm-app** | `97545c35` | `97545c35`（M1 と同じ） | **`cad8639a`**（`rp016_m3_virq_v2`） |
| OP-TEE OS、QEMU、Linux、U-Boot | `814978eb`、`9c23f2a7`、`2912ca61`、`32bdb252` | M1 と同じ | M1 と同じ |

マイルストーンの成果は、すべて **OpenSBI** に入っている（M3 では、これに加えて試験用のベアメタルアプリも変わる）。QEMU は3つとも 10.1.93。

## 4. 結果

### 4.1 M2 — 有線割り込みを M モードで処理する（APLIC）

| 確認項目 | 結果 |
|---|---|
| OpenSBI のコンソールでのキー `a` が M モードで処理される | PASS：`[APLIC TEST] UART got 'a'(0x61)` |
| キー `b` | PASS：`[APLIC TEST] UART got 'b'(0x62)` |
| Linux が APLIC を登録する | PASS：`riscv-aplic d000000.interrupt-controller: 96 interrupts directly connected to 2 CPUs` |
| APLIC-DIRECT の割り込みカウンタが増え続ける | PASS：694 → 998 |
| 割り込みの CPU 割り当てを CPU1 にする（virtio0 = `vda`、irq 15） | PASS：CPU0 +0、CPU1 +66 |
| CPU0 に戻す | PASS：CPU0 +64、CPU1 +0 |

OpenSBI は、APLIC を2つ報告している。

- `0xC000000` の M モードの root APLIC（`targets_mmode=1`）。UART の割り込み線はここで受ける。
- `0xD000000` の S モードの APLIC。Linux が使う。

割り込みの経路は、ドキュメントに書かれたとおり、IRQ chip のハンドラ → APLIC の raw ハンドラ → UART のハンドラ → 完了処理、だった。

### 4.2 M3 — 割り込みをきっかけにしたドメインの切り替え（VIRQ）

ハートは4つ使う。Linux はハート0と1で root ドメインとして動く。ハート2では、bm-app1 が `domain1`、bm-app2 が `domain2` で動く。デバイスツリーのルーティング規則により、UART の受信（hwirq 10）は `domain2` に送られる。

| 確認項目 | 結果 |
|---|---|
| bm-app1（`domain1`、ハート2）がキーの受付準備を完了する | PASS |
| キー `a` で、ハート2が `domain1 → domain2` に切り替わる | PASS |
| bm-app2 がキーを処理する | PASS：`[UART] Got 'a'(0x61)` |
| ハート2が `domain2 → domain1` に戻る | PASS |
| キー `b` でも、同じ切り替え・処理・復帰が起きる | PASS |
| Linux が APLIC を登録する | PASS：`96 interrupts directly connected to 4 CPUs` |
| APLIC-DIRECT の割り込みカウンタが増え続ける | PASS：712 → 1111 |

1回目のキーでの OpenSBI のコンソールの抜粋：

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

この流れを言葉で説明すると、次のとおり。

1. 物理的な割り込みを M モードで受ける。
2. 仮想 IRQ に変換し、持ち主のドメインへの経路を決める。
3. ハート2をそのドメインに切り替え、S モードへ割り込みを知らせる（`scause` `0x8000000000000009`、S モードの外部割り込み）。
4. ペイロードが、VIRQ の ECALL 拡張（SBI の拡張一覧に `virq` として現れる）で仮想 IRQ を取り出し、完了を通知する。
5. OpenSBI が元のドメインへ戻す。

## 5. 範囲：この試験で示せること、示せないこと

- **M2 と M3 の試験には OP-TEE が加わっていない。** 公式手順どおり、OpenSBI（`fw_jump`）から Linux とベアメタルアプリを直接起動する構成である。示しているのは OpenSBI の割り込みの仕組み（M2 の M モードの有線割り込み、M3 の持ち主ドメインへの割り込みの配送とドメインの切り替え）であり、OP-TEE が割り込みを受けることではない。
- **OP-TEE 向けのインターフェースは次の段階。** RISE のドキュメントによると、RP022 M1 は次のことを行う。
  - VIRQ の ECALL を、MPXY 上の RPMI SYSTEM_IRQ サービスグループに置き換える。
  - OP-TEE 向けの yield ECALL を追加する。

  状態は「Delivered」で、パッチ（VIRQ のパッチ v2 と統合したもの）は 2026-10-29 に OpenSBI のメーリングリストへ投稿され、レビュー中である。今回の再現の対象には含めていない。（この記録の以前の版では「計画中」と書いていたが、古い情報だった。）
- **試していないこと**：RP016 の後続のマイルストーン（M4 のハードウェア隔離の枠組み、M5 の WorldGuard、M6 の浮動小数点・ベクトルのコンテキスト管理）と、実機。

## 6. 観察事項

| 観察 | 評価 |
|---|---|
| M2 では、キーを1回押すごとに APLIC のハンドラが2回呼ばれた。2回目は文字を受け取っていない | 調査していない。M2 のドキュメントには、QEMU の APLIC のレジスタの挙動に対して OpenSBI で回避策を入れた、という記述がある |
| M3 は `Boot HART ID : 1` で、問題なく起動した | G05a の起動停止（最初に起動したのが hart 1）は、OP-TEE を含む構成で起きたもの。構成が異なるため、結論は出さない |
| M3 の Linux が `riscv-aplic ... invalid cpuid for IDC2` を出した | `maxcpus=2` であること（ハート2はベアメタル側のドメインに属する）と矛盾しない。APLIC の登録自体は直後に成功している |
| M3 のオーバーレイのコンパイル時に、`dtc` が `interrupts-extended` について警告を出した | 公式のオーバーレイが、ドキュメントどおり phandle を数値で直接書いているため |
| M3 の2回目のサイクルで、新しい VIRQ の POP の前に COMPLETE の呼び出しが現れた | 調査していない |
| M2 と M3 の Linux の起動時に、`tee-supplicant` の起動が失敗した | これらの構成には OP-TEE が含まれないため、想定どおり（5章） |

## 7. まとめ

RP016 の2つのマイルストーンは、別々の作業ツリーで、固定した commit からビルドできた。M1 から変わったコンポーネントは OpenSBI（v1.8）だけで、M3 ではこれに試験用のベアメタルアプリが加わる。

- **M2** では、UART の有線割り込みを、APLIC を通じて最初から最後まで M モードで処理できた。Linux の割り込み処理や CPU 割り当てには影響しなかった。
- **M3** では、同じ割り込みを仮想 IRQ として持ち主のドメインへ届けた。ハート2が `domain1` から `domain2` へ切り替わり、ペイロードが割り込みを処理・完了し、ハートは `domain1` へ戻る。この動作は繰り返し再現でき、Linux の割り込み処理には影響しなかった。

これは、M1 に欠けている「割り込みをきっかけにしたワールドの切り替え」のための、OpenSBI 側の土台にあたる。これを OP-TEE につなぐのは RP022 M1 の範囲で、2026年10月にレビュー用に提出されたが、今回は再現していない。
