# Garry's PAD / GModCore

Garry's Mod の Lua とゲーム素材を、iPad の Swift / Metal 上で動かすための実験的な互換ランタイムです。原版の MENU / CLIENT / SERVER Lua、Derma / VGUI、Source 形式のアセットに対応する実装を進めています。

**開発途中です。通常の Garry's Mod と同等に遊べる完成版ではありません。** パッケージのビルド成功と、iPad 実機での表示・操作・性能の確認は分けて記録しています。

## はじめに

配布形態は **Swift Package** です。iPad の Swift Playgrounds で小さなアプリを作り、`GModApp` を読み込んで起動します。ゲーム本体の実装はパッケージ側に置いています。

この README の導入対象は **[0.1.67](https://github.com/Ikaring45/GModCore/releases/tag/0.1.67)** です。[同版のリリースノート](https://github.com/Ikaring45/GModCore/blob/0.1.67/RELEASE_NOTES_0.1.67.md)には、VGUI のレイアウト再入、画面からの視線方向計算、Lua GC 中の NULL 保持、起動・切断ログの修正を記載しています。Apple CI と物理 iPad での動作は、同版の検証済み範囲に含まれていません。

開発ブランチには配布版以降の変更も含まれます。各変更の検証範囲は[GameUI 対応状況](https://github.com/Ikaring45/GModCore/blob/66d3161cc4f3995fc0ca9f834f736c7dcaf5d32c/GAMEUI_PARITY_2026-10-16.md)と[VGUI 安定性の記録](https://github.com/Ikaring45/GModCore/blob/66d3161cc4f3995fc0ca9f834f736c7dcaf5d32c/VGUI_RUNTIME_STABILITY_20261017.md)を参照してください。

## iPad で起動する

必要なもの:

- iPadOS 16 以降の iPad と Swift Playgrounds
- 正規に所有する Garry's Mod の PC インストール
- コンテンツ ZIP を作成する Windows PC と、ZIP を保存できる空き容量

1. Swift Playgrounds で新しい「App」を作成します。
2. [GModCore パッケージ](https://github.com/Ikaring45/GModCore)を追加し、バージョン `0.1.67`、製品 `GModApp` を選択します。
3. 生成された `ContentView.swift` を[ホスト用の ContentView.swift](https://github.com/Ikaring45/GModCore/blob/0.1.67/Apps/GarrysPADPlayground/ContentView.swift)の内容に置き換えます。
4. 下記の手順で作成したコンテンツ ZIP を、iPad の「ファイル」または iCloud Drive に置きます。**解凍せず、App の Resources にも追加しません。**
5. アプリを実行し、**Choose ZIP from Files** から ZIP を選択します。保存されたファイルアクセス許可は次回起動にも使用します。

更新時は Playgrounds のパッケージ依存関係を更新してください。詳しいホスト設定は[Swift Playgrounds 用 README](https://github.com/Ikaring45/GModCore/blob/0.1.67/Apps/GarrysPADPlayground/README.md)、Xcode を使う場合は[アプリホスト用 README](https://github.com/Ikaring45/GModCore/blob/0.1.67/Apps/GarrysPAD/README.md)を参照してください。

### Windows でコンテンツ ZIP を作る

[0.1.67 のソース一式](https://github.com/Ikaring45/GModCore/archive/refs/tags/0.1.67.zip)を取得・展開し、そのルートで PowerShell 7 から実行します。インストール先と出力先は自分の環境に置き換えてください。

```powershell
pwsh -NoProfile -File .\Tools\ContentPack\New-GarrysPADContentPack.ps1 -GModInstallRoot 'D:\SteamLibrary\steamapps\common\GarrysMod' -OutputPath 'D:\GarrysPAD_Content_Playable.zip' -Profile Playable
```

作成前に対象を確認する場合は、同じコマンドに `-PlanOnly` を追加します。作成後は次のコマンドで検査できます。

```powershell
pwsh -NoProfile -File .\Tools\ContentPack\Test-GarrysPADContentPack.ps1 -Path 'D:\GarrysPAD_Content_Playable.zip'
```

通常の起動には **Playable** を使用します。小容量の `Playground` はメニュー・BSP・転送の診断用で、実際のテクスチャや UI 音に必要な VPK 群を含みません。

ZIP は複数 GB になります。ランタイムは ZIP64 と内部 VPK の必要範囲を直接読み込みます。iPad 上で全体を展開する方式ではありません。古いパックに `.res` や背景画像がない場合は、現在の作成ツールで作り直してください。

対象は指定されたベースゲーム素材と `gm_construct` / `gm_flatgrass` です。個人設定、セーブ、キャッシュ、Workshop / addon は自動で取り込みません。収録範囲とプロファイルの詳細は[コンテンツパックの説明](https://github.com/Ikaring45/GModCore/blob/0.1.67/Tools/ContentPack/README.md)にあります。

## 操作

| 操作 | 入力 |
| --- | --- |
| 移動 | 左スティック |
| 視点 | 右パッド |
| ジャンプ | JUMP |
| Spawnmenu | Q |
| Context Menu | C |
| Home / Resume / Disconnect | ポーズメニュー |

これらは現在の操作構成です。Q/C の遅延・再表示など、実機で解消を確認できていない問題があります。

## 現在の対応範囲

Home は原版 HTML を `WKWebView` で表示し、ゲーム内メニューは Lua / Derma → Surface → Metal の経路で描画します。SERVER / CLIENT のセッションと、描画から分離した 0.015 秒間隔の固定 tick を実装しています。

BSP、Studio モデル、VMT / VTF、Entity 複製、地形衝突、水・太陽・3D skybox の読み込みや描画には実装があります。ただし、すべてのマップ・素材・実機での正しい動作を確認したものではありません。

### 未解決の問題・制限

- **メニュー:** Q/C の起動・操作遅延、再表示できない状態、不安定さが報告されています。対策後の実機確認は未完了です。
- **文字:** VGUI 文字の上下反転・配置崩れを調査しています。Apple の画素検証と実機表示の確認が必要です。
- **設定:** ホスト設定用の限定的な Derma ウィンドウです。原版の Game / キーボード / マウス / オーディオ等のタブ付き Options は未完成で、設定が開けない報告も残っています。
- **ロード画面:** 原版 HTML と `.res` への対応途中です。分割バーの実装はありますが、scheme、比例サイズ、枠、翻訳を含む完全な再現には至っていません。
- **音・移動・背景:** Home 効果音の再生、足音、Source と異なる歩行感、3D skybox が見えないという報告が残っています。
- **ゲーム互換性:** 物理、武器、Toolgun / Physgun は部分実装です。一般的な VPhysics 互換、全ツール、ragdoll、車両、マルチプレイ予測、Steam / Workshop 互換は完成していません。

未対応 API や不足アセットは診断として残します。詳細な実装状況・既知の失敗は技術資料を参照してください。

## ログと不具合報告

Lua の `print` / `Msg`、Lua エラー、ホストで検出した失敗は Swift Playgrounds のコンソールに出力します。`[GarrysPAD]` と `MENU` / `CLIENT` / `SERVER` が目印です。

`[Session]` は起動条件・接続・切断・停止、`[Loading]` は読み込み段階、`[Startup]` は SERVER / CLIENT の初期化結果と直接読み込んだ Lua ファイル名を記録します。Lua セッションの準備完了と Metal 表示の準備完了は別に扱います。永続的なクラッシュログ保存機能はありません。

不具合報告には、使用したパッケージ版またはコミット、マップ名、操作の順序、発生前後のログ、画面写真を添えてください。公開するログに個人情報が含まれていないか確認してください。

## 開発と検証

| モジュール | 役割 |
| --- | --- |
| `GModApp` | SwiftUI ホスト、Home、入力、設定、診断 |
| `GModMetal` | ワールド・モデル・Surface 描画、文字の画像化 |
| `GModGameSession` | SERVER / CLIENT セッション、マップ、固定 tick |
| `GModGameAssets` | マニフェストで指定したベースコンテンツ |
| `GModEngine` | GLua / Source API、VFS、Entity、net、VGUI、衝突 query |
| `GModLua` | pure-Swift Lua 5.1 互換 VM |

Windows では Swift、Visual Studio Build Tools、Windows SDK を用意して、移植可能なランタイム部分を検証します。例えばメニューとリソースのテストは次のコマンドで実行できます。

```powershell
swift test --jobs 2 --filter 'GMLuaMenuSessionTests|GMLuaVGUIResourceInstanceTests'
swift build --product GModLuaConformance
swift run GModLuaConformance --eval 'print(table.getn({10, 20, 30}))'
swift run GModLuaConformance --trace-file .\path\to\test.lua
```

SwiftUI / Metal / CoreText は Apple 環境で検証します。[iPadOS CI](https://github.com/Ikaring45/GModCore/blob/0.1.67/.github/workflows/validate-ipados.yml)と[Xcode ホスト](https://github.com/Ikaring45/GModCore/blob/0.1.67/Apps/GarrysPAD/README.md)を使用してください。実機インストールには署名と開発チームの設定が必要です。

Lua 5.1 公式 basic corpus の完走記録は[Lua 検証状況](https://github.com/Ikaring45/GModCore/blob/0.1.67/LUA51_CONFORMANCE_STATUS.md)にあります。これは過去の対象版の結果で、GLua 全 API や GMod 全体の互換性を示しません。CLI/process、PUC 内部 C API、PUC バイナリチャンク互換も同じ結果には含めません。

検証結果は対象コミットと実行条件に限定します。Windows テスト、Apple ビルド、Simulator、物理 iPad の表示・操作・性能は、それぞれ独立した確認項目です。

## 技術資料

- [起動順序](https://github.com/Ikaring45/GModCore/blob/0.1.67/GMOD_BOOT_SEQUENCE.md)
- [GameUI / .res の対応状況](https://github.com/Ikaring45/GModCore/blob/66d3161cc4f3995fc0ca9f834f736c7dcaf5d32c/GAMEUI_PARITY_2026-10-16.md)
- [VGUI ランタイムの安定性](https://github.com/Ikaring45/GModCore/blob/66d3161cc4f3995fc0ca9f834f736c7dcaf5d32c/VGUI_RUNTIME_STABILITY_20261017.md)
- [Lua 5.1 検証状況](https://github.com/Ikaring45/GModCore/blob/0.1.67/LUA51_CONFORMANCE_STATUS.md)
- [GLua 調査資料](https://github.com/Ikaring45/GModCore/blob/0.1.67/Docs/GLuaAnalysis/01_BOOTSTRAP_MODULES.md)
- [ローカル corpus の扱い](https://github.com/Ikaring45/GModCore/blob/0.1.67/Tests/GModCorpus/README.md)
- [リリース一覧](https://github.com/Ikaring45/GModCore/releases)
- [CI の実行記録](https://github.com/Ikaring45/GModCore/actions)

## 権利と位置づけ

独立した互換性研究です。Facepunch Studios、Valve Corporation、Garry Newman の公式製品・公認移植ではありません。Garry's Mod / Source / Steam 等の名称と権利は各権利者に帰属します。

利用者の正規インストールから作るコンテンツ ZIP は GitHub に含めません。リポジトリに含むベースコンテンツは指定マニフェストの範囲に限定されます。独自コードのライセンスは、ゲーム素材全体の再配布を許可するものではありません。非公開エンジンバイナリや流出ソースは配布しません。
