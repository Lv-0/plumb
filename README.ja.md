<div align="center">

<img src="assets/AppIcon-base.png" width="140" height="140" alt="Plumb">

# Plumb

一条の糸が垂れ下り、真ん中に落ち着く。

> Mac をもっと上質に使えるように。

macOS アプリを自動で中央寄せ・タイル配置 —— 整理好きにとっての救い！

[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg?style=flat-square)](#動作環境)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138.svg?style=flat-square)](https://swift.org)
[![Release](https://img.shields.io/badge/release-v2.0.52-success.svg?style=flat-square)](#ダウンロードとインストール)

[English](./README.md) · [简体中文](./README.zh.md) · [Español](./README.es.md) · [Français](./README.fr.md) · **日本語**

</div>

---

## 📖 目次

- [概要](#概要)
- [✨ 機能](#-機能)
- [📐 自動タイル](#-自動タイル)
- [📸 スクリーンショット](#-スクリーンショット)
- [ダウンロードとインストール](#ダウンロードとインストール)
- [使い方](#使い方)
- [権限](#権限)
- [動作環境](#動作環境)
- [ローカルビルド](#ローカルビルド)
- [パッケージとリリース](#パッケージとリリース)
- [よくある質問](#よくある質問)
- [ライセンス](#ライセンス)

## 概要

`Plumb` は、自動中央寄せとアプリごとの自動タイル配置の両方をサポートする **macOS メニューバー型ウィンドウマネージャ** です。

名前は **鉛直糸**（plumb line）—— 大工が真の垂直・真の中心を見つけるために垂らす重りに由来します。Plumb がするのもまさにそれです。ウィンドウを画面の真ん中、あるいは指定位置へ優しく置きます。

- 🪧 メニューバーに常駐 —— Dock アイコンなし、邪魔にならない
- 🎯 起動時に1回中央寄せ。以降はウィンドウを開き直した / 新しいウィンドウに切り替えた時のみ
- 🖥️ 利用可能な画面領域で計算（Dock とメニューバーを自動で除外）、マルチディスプレイで安定
- 📐 アプリごとの自動タイル（ホワイトリスト）、統一の四辺マージンを設定可能
- 🪟 Liquid Glass 設定 UI（macOS 26）—— すりガラス、アプリ検索、ピル型スイッチ

## ✨ 機能

| 機能 | 説明 |
| --- | --- |
| 🎯 1回だけ中央寄せ | 起動時に1回中央寄せ。以降はウィンドウを開き直した / 新しいウィンドウに切り替えた時のみ |
| ✋ 手動配置を妨げない | ウィンドウをドラッグしても中央寄せは再トリガーされない |
| 🖥️ Dock/メニューバーを正確に回避 | `screen.frame - screen.visibleFrame` に基づき、マルチディスプレイで安定 |
| 📐 アプリごとの自動タイル | ホワイトリスト方式、統一の四辺マージン（px）を設定可能 |
| 🎚️ アプリごとのタイル余白 | タイルリストでアプリをタップしてそのアプリだけのカスタム余白を設定可能。設定のないアプリはグローバルのデフォルト余白を使用 |
| 🔄 アプリリストをリアルタイム更新 | 新しくインストールしたアプリが設定ピッカーに即座に表示、再起動不要 |
| 🪟 Liquid Glass 設定 UI | macOS 26 のすりガラス、検索、ピル型スイッチ |
| 🧠 スマートな座標系検出 | 各アプリのウィンドウ座標系を自動検出し、安定のためキャッシュ |
| 🪧 非侵襲的なメニューバー常駐 | メニューバーのアイコンのみ、Dock を占有しない |

## 📐 自動タイル

メニューバーの `タイル設定…` を開いて、機能のオン/オフやワークフローの管理を行えます。

- 統一の四辺マージン（px）を設定可能
- **アプリごとのタイル余白**：タイルリストでアプリをタップするとインラインの余白ドロワーが展開し、そのアプリだけのカスタム余白を設定できます。カスタム設定のないアプリは引き続きグローバルのデフォルト余白を使います。「デフォルトを使用」ボタンでアプリをグローバル値にリセットできます。
- インストール済みアプリからホワイトリストを選択（システムアプリは既定で非表示、切替可能）
- ホワイトリストのアプリでは **タイルが優先**、自動中央寄せは行わない
- トリガ範囲はプロセス起動ごとに1回（PID）。同一プロセス内での繰り返しタイルなし
- ウィンドウがリサイズ不可の場合はスキップ
- 書類アプリ（Pages、Numbers、Word、Excel）はテンプレートやファイル選択画面を自動的にスキップし、開いた書類のみタイル化

> 挙動は Amethyst の設定概念を参考にしています：
> - `window-margin-size`：本プロジェクトのタイルマージンに相当
> - `floating + floating-is-blacklist=false`：本プロジェクトのホワイトリスト自動タイルに相当

## 📸 スクリーンショット

<table>
  <tr>
    <td width="50%" align="center"><b>中央寄せ — アプリ許可リスト</b></td>
    <td width="50%" align="center"><b>タイル — アプリごとの余白ドロワー</b></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="assets/Centering.png" alt="中央寄せタブ"></td>
    <td width="50%" align="center"><img src="assets/Tiling.png" alt="タイルタブとアプリごとの余白ドロワー"></td>
  </tr>
  <tr>
    <td width="100%" colspan="2" align="center"><b>権限 — アクセシビリティ、画面収録、ログイン時に起動</b></td>
  </tr>
  <tr>
    <td width="100%" colspan="2" align="center"><img src="assets/Permissions.png" alt="権限タブ"></td>
  </tr>
</table>

## ダウンロードとインストール

### 方法 1：DMG をダウンロード（推奨）

1. [Releases](../../releases) から最新の `Plumb.dmg` をダウンロード。
2. DMG を開き、`Plumb.app` を `Applications` にドラッグ。
3. `Applications` で `Plumb.app` を右クリック → `開く` → もう一度 `開く` をクリック。
4. ブロックされた場合は `システム設定 → プライバシーとセキュリティ` へ行き、「このまま開く」をクリック。

### 方法 2：ソースからビルド

```bash
swift build -c release
./.build/release/Plumb
```

[ローカルビルド](#ローカルビルド) を参照。

## 使い方

1. 起動すると、メニューバーに水滴アイコンが現れます。
2. [アクセシビリティ](#アクセシビリティ) 権限を付与 —— 中央寄せはこれに依存します。
3.（任意）[画面収録](#画面収録) 権限を付与すると、マルチディスプレイでの座標検出の安定性が向上します。
4. メニューバーアイコンをクリック：
   - 手動で中央寄せをトリガ
   - `タイル設定…` を開いてホワイトリストとマージンを設定

> 💡 **設計原則**：各ウィンドウは1回だけ中央寄せ/タイルされます（`pid:windowNumber` をキーに記録）。手動でドラッグしたウィンドウが「修正」されることはありません —— Plumb は手動配置を妨げません。

## 権限

### アクセシビリティ

- **パス**：`システム設定 → プライバシーとセキュリティ → アクセシビリティ`
- **必要な理由**：アプリは macOS アクセシビリティ API を使い、最前面のウィンドウの枠を読み取り、中央寄せのために新しい位置を書き込みます。
- **ない場合**：ウィンドウの位置やサイズを読み取れず、移動もできません。中央寄せは機能しません。

### 画面収録

- **パス**：`システム設定 → プライバシーとセキュリティ → 画面収録`
- **必要な理由**：利用可能なディスプレイ領域を正確に計算し、中央寄せ時に Dock やメニューバーを確実に回避するため、画面全体のコンテキストが必要です。
- **ない場合**：画面コンテキストに依存する中央寄せがマルチディスプレイや複雑なレイアウトで不安定になることがあります。

### 権限の範囲

- ❌ 画面の内容をアップロードせず、テレメトリ収集も行いません。
- ✅ 権限はローカルのウィンドウ位置・サイズの計算と移動にのみ使用します。

## 動作環境

- **macOS 26+**（macOS 26 SDK と Liquid Glass UI でビルド。それ以前のバージョンは非対応）
- Xcode Command Line Tools（`xcode-select --install`）

## ローカルビルド

```bash
# テストを実行
swift test

# Release バイナリをビルド
swift build -c release

# 直接実行
./.build/release/Plumb
```

## パッケージとリリース

### ワンコマンドリリース（推奨）

`scripts/release.sh` がフロー全体をエンドツーエンドで実行します — バージョン上げ、ビルド、署名、パッケージ、タグ付け、プッシュ、GitHub Release の公開、OTA appcast の更新まで：

```bash
# まず 5 言語の OTA notes を書く（en/zh/es/fr/ja、各 1 行）
scripts/release.sh --print-notes-template > /tmp/notes.txt
$EDITOR /tmp/notes.txt

# そしてリリース（デフォルトはローカル署名）
bash scripts/release.sh 2.0.50 --notes-file /tmp/notes.txt
```

実行順序：事前チェック（クリーンなツリー、テスト、リリースビルド、シークレットスキャン）→ 5 つの README バッジを更新 → 署名済み `.app` + DMG + OTA zip をビルド → codesign を検証（指定要件が証明書リーフハッシュであることを確認し、TCC 権限がアップデート後も保持されるようにする）→ タグ付け + プッシュ → assets 付きで GitHub Release を作成 → `appcast.json` を更新（version/url/sha + 5 言語の notes）。詳細と安全上の注意は [RELEASING.md](./RELEASING.md) を参照。

### 個別にアーティファクトをビルド

```bash
scripts/build_app.sh      # dist/Plumb.app を生成（Plumb Local Signer で署名）
scripts/create_dmg.sh     # dist/Plumb.dmg を生成
scripts/create_zip.sh     # dist/Plumb-<version>.zip を生成（OTA 用）
```

DMG には `Plumb.app` と `Applications` ショートカットが含まれます — ドラッグしてインストール。

### 署名モード

| モード | 目的 | 方法 |
| --- | --- | --- |
| **ローカル署名**（デフォルト） | 日常ビルド、テスト | `scripts/build_app.sh` が自動的に `Plumb Local Signer` を使用（事前に `scripts/make_signing_cert.sh` を 1 回実行） |
| **Developer ID + 公証済み** | Gatekeeper 警告なしの公開配布 | `scripts/release.sh --sign developer-id`（環境変数 `DEVELOPER_ID_APP` + `NOTARY_PROFILE` が必要）、または単体の `scripts/sign_and_notarize.sh` |

> ⚠️ ローカル署名/未公証の DMG は新しい Mac で Gatekeeper にブロックされ、「破損している」と表示されることがあります — `xattr -dr com.apple.quarantine /Applications/Plumb.app` を実行してください（[よくある質問](#よくある質問)を参照）。

## よくある質問

<details>
<summary><b>Plumb.app を開くと「破損している」「開発元が未確認」と表示される？</b></summary>

これは未公証配布における Gatekeeper の通常のフローであり、**アプリのコードが破損しているわけではありません**。以下を実行：

```bash
xattr -dr com.apple.quarantine /Applications/Plumb.app
```

または `システム設定 → プライバシーとセキュリティ` で、下部の「このまま開く」をクリック。

</details>

<details>
<summary><b>中央寄せが効かない？</b></summary>

**アクセシビリティ** 権限が付与されているか確認してください：`システム設定 → プライバシーとセキュリティ → アクセシビリティ`。Plumb がオンになっていることも。付与後に Plumb の再起動が必要な場合があります。

</details>

<details>
<summary><b>マルチディスプレイで中央寄せの位置がずれる？</b></summary>

**画面収録** 権限を付与してください。Plumb は `CGWindowList` API を補助信号として使い、ウィンドウの所属画面と座標系をより正確に特定します。

</details>

<details>
<summary><b>ウィンドウをドラッグしたら中央に戻された？</b></summary>

いいえ。Plumb は各ウィンドウを1回だけ中央寄せ/タイルします —— 手動ドラッグが「修正」されることはありません。

</details>

## ライセンス

本プロジェクトは [MIT License](./LICENSE) で公開されています。

---

<div align="center">

[English](./README.md) · [简体中文](./README.zh.md) · [Español](./README.es.md) · [Français](./README.fr.md) · **日本語**

Plumb がお役に立ちましたら、⭐ Star をいただけると嬉しいです。

</div>
