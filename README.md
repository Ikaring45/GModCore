# Garry's PAD / GModCore

Garry's Mod の Lua・Sandbox・Source アセットを iPad 上の Swift と Metal で動かすための実験的な互換ランタイムです。Windows エミュレーターやリモートプレイではありません。

原版の Lua / Derma / VGUI を動かすことを目標にしています。**開発途中であり、通常の Garry's Mod と同等に遊べる完成版ではありません。**

## 最新版

正式パッケージ版: **[0.1.66](https://github.com/Ikaring45/GModCore/releases/tag/0.1.66)**

- Lua の通常ログとエラーを Swift Playgrounds のコンソールへ出力
- Q/C 操作中の描画要求をまとめ、処理中の描画が繰り返し破棄される経路を修正
- ウィンドウ再表示・遅延入力への対策、分割ロードバーを含む

正式版タグは配布の区切りであり、全機能の完成・実機検証済みという意味ではありません。[リリースノート](RELEASE_NOTES_0.1.66.md)と[CI](https://github.com/Ikaring45/GModCore/actions)に検証範囲を記載しています。署名済みアプリではなく Swift Package として配布します。

## iPad / Swift Playgrounds で起動する

必要なものは、iPadOS 16 以降に対応する環境、Swift Playgrounds、自分が正規に所有する Garry's Mod の PC インストール、コンテンツ ZIP を置く空き容量です。

1. Swift Playgrounds で新しい「App」を作成します。
2. パッケージ https://github.com/Ikaring45/GModCore を追加し、GModApp 製品を有効にします。バージョンは 0.1.66 を選択します。
3. 生成された ContentView.swift を[薄いホスト用の ContentView](Apps/GarrysPADPlayground/ContentView.swift)へ置き換えます。ゲームの実装はパッケージ側にあります。
4. 下記で作成した ZIP を「ファイル」または iCloud Drive に置きます。**解凍せず、App の Resources にも追加しません。**
5. 実行し「Choose ZIP from Files」から ZIP を選択します。保存されたアクセス許可は次回起動にも使用します。

詳細: [Swift Playgrounds ホスト](Apps/GarrysPADPlayground/README.md)

### コンテンツ ZIP の作成（Windows）

リポジトリのルートで PowerShell 7 から実行します。パスは自分の環境に置き換えてください。

~~~powershell
pwsh -NoProfile -File .\Tools\ContentPack\New-GarrysPADContentPack.ps1 -GModInstallRoot 'D:\SteamLibrary\steamapps\common\GarrysMod' -OutputPath 'D:\GarrysPAD_Content_Playable.zip' -Profile Playable
~~~

作成前の確認には同じコマンドに -PlanOnly を付けます。作成後の検査:

~~~powershell
pwsh -NoProfile -File .\Tools\ContentPack\Test-GarrysPADContentPack.ps1 -Path 'D:\GarrysPAD_Content_Playable.zip'
~~~

**通常の起動には Playable プロファイルを推奨します。** 小さい Playground プロファイルはメニュー・BSP・転送の診断用です。VPK 群を含まないため、実際のテクスチャや UI 音を揃えられません。

ZIP は複数 GB になります。ZIP64 と内部 VPK の必要範囲を直接読み、iPad に全体を展開する構成ではありません。古いパックに .res や背景画像が入っていない場合は、最新版の作成ツールで作り直してください。

指定したベースゲーム素材と gm_construct / gm_flatgrass が対象です。個人設定・セーブ・キャッシュ・Workshop/addon は自動で取り込みません。[パック仕様と詳細](Tools/ContentPack/README.md)

## 操作・ログの記録

左スティックで移動、右パッドで視点操作、Q が Spawnmenu、C が Context Menu、ポーズから Home / Resume / Disconnect を操作する構成です。ただし、下記の実機不具合が残っています。

0.1.66 以降では Lua の print / Msg とエラー、ゲーム側で検出した失敗が Playgrounds のコンソールへ出ます。ログの目印は [GarrysPAD] と MENU / CLIENT / SERVER です。永続的なクラッシュログ保存機能ではありません。

開発版では `[Session]` にローカルサーバー起動条件・接続・切断・停止、`[Loading]` に実際の読み込み段階、`[Startup]` に SERVER / CLIENT の初期化結果と直接読み込んだ Lua ファイル名も出力します。Lua セッション準備完了と Metal の表示準備完了は別扱いです。原版エンジンの全コンソール出力との完全一致を意味するものではありません。

不具合報告にはパッケージ版、マップ名、押したボタンと順序、直前からのログ、画面写真を添えてください。ログにはサーバー名や Lua が出力した文字列も含まれるため、公開前に個人情報を確認してください。

## 現在の制限・報告されている不具合

- Q/C の起動・操作遅延、再表示できない状態、不安定さが実機で報告されています。対策は追加していますが、解消確認は未完了です。
- VGUI 文字の上下反転・配置崩れを調査中です。Apple の画素検証と実機表示を別々に確認する必要があります。
- 設定は限定的なホスト設定用 Derma ウィンドウです。**原版の Game / キーボード / マウス / オーディオ等のタブ付き Options は未完成です。** 設定が開けない報告も残っています。
- ロード画面は原版 HTML と .res への対応途中です。分割バーは実装していますが、配色の上書き・比例サイズ・枠・翻訳を含む完全一致ではありません。
- Home の効果音が再度鳴らない、足音が鳴らない、歩行感が Source と異なるという報告があります。
- 3D skybox のコードはありますが、実機で境界外の拡大背景が見えないという報告は未解決です。
- 物理・武器・Toolgun / Physgun は部分的な実装です。一般的な VPhysics 互換、全ツール、ragdoll、車両、マルチプレイ予測、Steam / Workshop 互換は完成していません。

未対応 API・不足アセットを成功したダミーとして隠さず、診断として残す方針です。

## 実装の構成

| モジュール | 担当 |
| --- | --- |
| GModApp | SwiftUI ホスト、Home、入力、設定ストア、診断 |
| GModMetal | ワールド・モデル・Surface の描画、文字の画像化 |
| GModGameSession | SERVER / CLIENT セッション、マップ、固定 tick |
| GModGameAssets | マニフェストで指定したベースコンテンツ |
| GModEngine | GLua / Source API、VFS、Entity、net、VGUI、衝突 query |
| GModLua | pure-Swift Lua 5.1 互換 VM |

Home は原版 HTML を WKWebView でホストし、ゲーム内メニューやユーティリティは Lua / Derma → Surface → Metal の経路を使います。一部の設定・接続処理はホストが担当します。シミュレーションの固定間隔は 0.015 秒で、描画クロックとは分離しています。

BSP、Studio モデル、VMT / VTF、Entity 複製、地形衝突、水・太陽・3D skybox 等には実装があります。**コードの存在は、すべてのマップ・素材・実機で正しく動く証明ではありません。**

## 開発・検証

Windows の Swift では移植可能なランタイム部分を検証できます。Visual Studio Build Tools と Windows SDK が利用できる開発環境で実行してください。

~~~powershell
swift test --jobs 2 --filter 'GMLuaMenuSessionTests|GMLuaVGUIResourceInstanceTests'
swift build --product GModLuaConformance
swift run GModLuaConformance --eval 'print(table.getn({10, 20, 30}))'
swift run GModLuaConformance --trace-file .\path\to\test.lua
~~~

SwiftUI / Metal / CoreText は Windows の成功だけでは検証できません。[iPadOS CI](.github/workflows/validate-ipados.yml)と[Xcode アプリホスト](Apps/GarrysPAD/README.md)を使用します。実機インストールには開発チームと署名の設定が必要です。

Lua 5.1 の公式 basic corpus を完走した記録はありますが、GLua API や GMod 全体の互換性とは別です。CLI/process、PUC 内部 C API、PUC バイナリチャンク互換は同じ結果に含めません。[正確な Lua 検証範囲](LUA51_CONFORMANCE_STATUS.md)

テスト結果は対象コミットと実行条件に限定されます。構文解析、Windows テスト、Apple ビルド、Simulator、物理 iPad の操作・性能は別々に扱います。部分的な成功を全体の PASS とせず、過去の件数を最新版の成功件数として引き継ぎません。

## 技術資料

- [起動順序](GMOD_BOOT_SEQUENCE.md)
- [GameUI / .res の対応状況](GAMEUI_PARITY_2026-10-16.md)
- [Lua 5.1 検証状況](LUA51_CONFORMANCE_STATUS.md)
- [GLua 調査資料](Docs/GLuaAnalysis/01_BOOTSTRAP_MODULES.md)
- [ローカル corpus の扱い](Tests/GModCorpus/README.md)
- [リリース一覧](https://github.com/Ikaring45/GModCore/releases)

## 権利・位置づけ

独立した互換性研究であり、Facepunch Studios、Valve Corporation、Garry Newman の公式製品・公認移植ではありません。Garry's Mod / Source / Steam 等の名称と権利は各権利者に帰属します。

利用者の正規インストールから作るコンテンツ ZIP は GitHub に含めません。リポジトリに含むベースコンテンツは指定マニフェストの範囲に限定されます。独自コードと同じライセンスでゲーム素材まで再配布できることを意味しません。エンジンの非公開バイナリ・流出ソース・無制限なゲーム一式のコピーを配布するプロジェクトではありません。
