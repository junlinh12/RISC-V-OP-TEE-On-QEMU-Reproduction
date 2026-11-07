# Source lock / 固定したソースの一覧

All commits used in this reproduction. Branch tips were resolved on **2026-11-05/06**. Repositories are under `https://gitlab.com/riseproject/riscv-optee/` unless noted.
この再現で使ったすべての commit です。ブランチの先端は **2026-11-05/06** に解決しました。特に記載がなければ、リポジトリは `https://gitlab.com/riseproject/riscv-optee/` にあります。

How a component is pinned / 固定の方法:

- **clone**: Buildroot itself, checked out at the SHA / Buildroot 自体を、その SHA で checkout する。
- **.config**: a defconfig custom-git version set to the SHA in `.config` / defconfig の custom git のバージョンを、`.config` で SHA にする。
- **local branch**: a `local.mk` override; `custom/<dir>` gets the local branch name that `local.mk` expects, at the SHA / `local.mk` による上書き。`custom/<dir>` に、`local.mk` が期待する名前のローカルブランチを、その SHA の位置に作る。
- **tarball**: the defconfig fetches an archive whose URL contains the commit SHA / defconfig が、URL に commit の SHA を含むアーカイブを取得する。
- **version**: a Buildroot package version checked by Buildroot's hash file / Buildroot のハッシュファイルで検証されるパッケージのバージョン。

## RP016 M1 — `rp016_m1` (G01–G05a)

| Component | Ref | Commit | Pinned by |
|---|---|---|---|
| Buildroot | `rp016_m1` | `d7204671a32ca2edc521c35de758ce650ebf1cb6` | clone |
| Linux | `rp016_m1` | `2912ca616fc806dbeeba2e1ac7a157e0843d6987` | .config |
| U-Boot | `rp016_m1` | `32bdb252fab83028768a269fb304b9356547ccbd` | .config |
| OpenSBI | `rp016_m1` | `cdd401f1517b4599b7d08ce13cd83859acc4cbb2` | local branch |
| OP-TEE OS | `rp016_m1` | `814978eb15b92c3b97255a8c000f44cd84aac008` | local branch |
| QEMU | `rp016_m1` | `9c23f2a7b0b45277693a14074b1aaa827eecdb92` | local branch |
| bm-app | `rp016_m1` | `97545c35a74ad387f7790b02a35b0f2b4d29bb6e` | local branch |
| optee_client / optee_test / optee_examples | `4.6.0` | — | version |
| Toolchain | Bootlin `riscv64-lp64d--glibc--bleeding-edge-2024.05-1` | — | version |

## RP016 M2 — `rp016_m2_aplic_up_v2` (G05b)

| Component | Ref | Commit | Pinned by |
|---|---|---|---|
| Buildroot | `rp016_m2_aplic_up_v2` | `8fba3ebe3c5b15b9fff51c310da1ee4195d2af4d` | clone |
| **OpenSBI** | `rp016_m2_aplic_up_v2` | `4533a2a938928d89d41f6ad144272567915a8435` | local branch |
| Linux, U-Boot, OP-TEE OS, QEMU, bm-app | `rp016_m1` | same as M1 / M1 と同じ | as M1 |

## RP016 M3 — `rp016_m3_virq_up_v1` (G05b)

| Component | Ref | Commit | Pinned by |
|---|---|---|---|
| Buildroot | `rp016_m3_virq_up_v1` | `f2e760efebf60feb95b39a780506d5b1b12e308a` | clone |
| **OpenSBI** | `rp016_m3_virq_up_v1` | `7ca03a0f3259af7e8d23fd04f378cf5d8a6cc98d` | local branch |
| **bm-app** | `rp016_m3_virq_v2` | `cad8639a1489bbff36ce04302aa2d726a77dba12` | local branch |
| Linux, U-Boot, OP-TEE OS, QEMU | `rp016_m1` | same as M1 / M1 と同じ | as M1 |

## Andes v9 — `dev-optee-mpxy-v9` (G05c)

| Component | Ref | Commit | Pinned by |
|---|---|---|---|
| Buildroot | `dev-optee-mpxy-v9` | `b5e20ca925d0784473c854fae92c3fc5931802ee` | clone |
| Linux | — | `9007f552b318522b0b36c78b838f70d9dd604d80` | tarball |
| OP-TEE OS | — | `f1d355401a3213d076f0332fd5d98c1cae05993b` | tarball |
| OpenSBI | — | `a1cdb6f4c7f511e3d0d41fc89495aefbd559e0b7` | tarball |
| U-Boot | (`dev-optee-mpxy-v5` in the file name) | `32bdb252fab83028768a269fb304b9356547ccbd` | tarball |
| QEMU | Buildroot package `10.0.0` | — | version |
| optee_test | `4.9.0-rc1` | — | version |

## RISE RP022 M8 — `rp022-m8-pmp-data-perms` (G05c)

| Component | Ref | Commit | Pinned by |
|---|---|---|---|
| Buildroot | `rp022-m8-pmp-data-perms` | `6d7db0ab2bf7b8bf7e134948822aa6f0b7b43808` | clone |
| **OP-TEE OS** | `rp022-m8-pmp-data-perms-v2` | `c0214654e16ad0813e58659082e44ae3e85ba530` | local branch |
| OpenSBI | `rp022-m2` | `a1cdb6f4c7f511e3d0d41fc89495aefbd559e0b7` (same as v9 / v9 と同じ) | local branch |
| Linux | `dev-optee-mpxy-v9` | `9007f552b318522b0b36c78b838f70d9dd604d80` (same as v9 / v9 と同じ) | .config |
| U-Boot | `dev-optee-mpxy-v5` | `32bdb252fab83028768a269fb304b9356547ccbd` | .config |
| QEMU | `rp016_m1` | `9c23f2a7b0b45277693a14074b1aaa827eecdb92` | local branch |
| bm-app | `rp016_m3_virq_v2` | `cad8639a1489bbff36ce04302aa2d726a77dba12` | local branch |
| **optee_test** | official: `rp022-m8-pmp-data-perms` in the RISE `optee_test` repository — **not publicly accessible** / 公式：RISE の `optee_test` リポジトリの `rp022-m8-pmp-data-perms` — **公開されていない** | **substitute / 代替**: `https://github.com/OP-TEE/optee_test.git`, tag `4.6.0` → `a9e9495f4d57b97022008ad11198195e7e044c5d` | local branch (approved substitution / 承認済みの差し替え) |

The first approved substitute for M8's optee_test, upstream pull request #852 (`33e086a0bb6f33299806185229fb993fb3eb5e6d`), did not compile against the M8 OP-TEE OS (see G05c, §4).
M8 の optee_test の最初の承認済みの代替、本家のプルリクエスト #852（`33e086a0bb6f33299806185229fb993fb3eb5e6d`）は、M8 の OP-TEE OS に対してコンパイルできなかった（G05c の4章）。
