# GLua bootstrap / core modules analysis

解析日: 2026-08-19
対象: ローカルにインストールされた Garry's Mod の実ファイル（読み取り専用）
対象範囲: `lua/includes/init.lua` と `lua/includes/modules/{hook,gamemode,baseclass,concommand,list}.lua`

## 結論

この6ファイルに限れば、GModLuaのGLua構文パーサーはすでに最初の関門を越えている。指定された5モジュールは、現行のWindows版 `GModLuaConformance` でそれぞれ実ファイルを単独ロードし、すべて終了コード0になった。

ただし、`init.lua` 全体はまだ起動できない。現時点の最初の停止点は6行目の `include( "util.lua" )` であり、Garry's PAD側にグローバル `include` がないため `attempt to call a nil value` になる。

GLua起動層で先に実装すべきものは、個別モジュールのSwift移植ではない。以下を用意して、本家Luaをそのままロードする構造が最短かつ互換性が高い。

1. realm値をLuaグローバルへ反映する。
2. GModの `lua/` をルートとするVFSと、呼び出し元ディレクトリを保持するネスト対応 `include` を作る。
3. `lua/includes/modules/<name>.lua` を探索できるGMod用 `require` searcherを追加する。
4. モジュール評価前に、GLua型判定、ログ、validity、console、`gmod` などのエンジン組込みを登録する。
5. `hook.lua` などの本家ファイルを無改変でロードする。
6. `extensions/table.lua` などを本家順でロードし、モジュールの遅延依存を満たす。

特に重要なのは、5モジュールがファイル先頭で多数のグローバル関数をlocalへキャッシュする点である。未実装関数を `nil` のまま一度ロードしてからグローバルへ追加しても、そのモジュール内のlocalは修復されない。必要な関数を先に登録するか、登録後にモジュールを完全に再ロードする必要がある。

## 解析元の識別

`garrysmod/steam.inf` の `PatchVersion` は `2026.04.29`。

| ファイル | 行数 | SHA-256 |
|---|---:|---|
| `lua/includes/init.lua` | 124 | `04A0D82FA01F39C7470AE266AABFD1B38FCE6EE9ABBE01E93D2B70BF561ED276` |
| `lua/includes/modules/hook.lua` | 143 | `8343FB394834437C634C23A6E79594CD93E0CF3C94C160C25966A2C589255A2A` |
| `lua/includes/modules/gamemode.lua` | 86 | `7E78FFA9E34045D542A118D7807298EEB58E20CF340064DB97EF7B9017B959F1` |
| `lua/includes/modules/baseclass.lua` | 58 | `921206E5C4289B76498F72B8EAF7BAAA717287359C077855034BB58612867E96` |
| `lua/includes/modules/concommand.lua` | 81 | `601FC0205516B7BD30EA2364E8FDA8F6F6AED57EEDD0DCFB0E9ED6E2A01F9F34` |
| `lua/includes/modules/list.lua` | 86 | `42CCC85AECD7FD63CC4532440E2ACCFDB32EDBC2D96602F03279C8E8291AE15E` |

以降の「確認済み」は上記ローカル実ファイルを根拠とする。GMod Wiki上の一般論ではなく、このスナップショットの挙動を記述している。

## `lua/includes/init.lua` の正確なロード順

### 1. realm共通の先行include

1. `include( "util.lua" )`
2. `include( "util/sql.lua" )`
3. `include( "extensions/net.lua" )`

`extensions/net.lua` だけは他のextensionsより先にロードされる。後段へまとめて移動してはいけない。

### 2. realm共通のmodule require

4. `require( "baseclass" )`
5. `require( "concommand" )`
6. `require( "saverestore" )`
7. `require( "hook" )`
8. `require( "gamemode" )`
9. `require( "weapons" )`
10. `require( "scripted_ents" )`
11. `require( "player_manager" )`
12. `require( "numpad" )`
13. `require( "team" )`
14. `require( "undo" )`
15. `require( "cleanup" )`
16. `require( "duplicator" )`
17. `require( "constraint" )`
18. `require( "construct" )`
19. `require( "usermessage" )`
20. `require( "list" )`
21. `require( "cvars" )`
22. `require( "http" )`
23. `require( "properties" )`
24. `require( "widget" )`
25. `require( "cookie" )`
26. `require( "utf8" )`

### 3. drive

27. `require( "drive" )`
28. `include( "drive/drive_base.lua" )`
29. `include( "drive/drive_noclip.lua" )`

module本体を先に登録し、その後で2つのdrive classをincludeする。

### 4. `SERVER` のときだけ

1. `require( "ai_task" )`
2. `require( "ai_schedule" )`

### 5. `CLIENT` のときだけ

1. `require( "draw" )`
2. `require( "markup" )`
3. `require( "effects" )`
4. `require( "halo" )`
5. `require( "killicon" )`
6. `require( "spawnmenu" )`
7. `require( "controlpanel" )`
8. `require( "presets" )`
9. `require( "menubar" )`
10. `require( "matproxy" )`
11. `include( "util/model_database.lua" )`
12. `include( "util/vgui_showlayout.lua" )`
13. `include( "util/tooltips.lua" )`
14. `include( "util/client.lua" )`
15. `include( "util/javascript_util.lua" )`
16. `include( "util/workshop_files.lua" )`
17. `include( "gui/icon_progress.lua" )`

### 6. realm共通のsaveとextensions

1. `include( "gmsave.lua" )`
2. `include( "extensions/entity_iter.lua" )`
3. `include( "extensions/file.lua" )`
4. `include( "extensions/angle.lua" )`
5. `include( "extensions/debug.lua" )`
6. `include( "extensions/entity.lua" )`
7. `include( "extensions/ents.lua" )`
8. `include( "extensions/math.lua" )`
9. `include( "extensions/player.lua" )`
10. `include( "extensions/player_auth.lua" )`
11. `include( "extensions/string.lua" )`
12. `include( "extensions/table.lua" )`
13. `include( "extensions/util.lua" )`
14. `include( "extensions/vector.lua" )`
15. `include( "extensions/game.lua" )`
16. `include( "extensions/motionsensor.lua" )`
17. `include( "extensions/weapon.lua" )`
18. `include( "extensions/coroutine.lua" )`

### 7. `CLIENT` の最後

1. `include( "extensions/client/entity.lua" )`
2. `include( "extensions/client/globals.lua" )`
3. `include( "extensions/client/panel.lua" )`
4. `include( "extensions/client/player.lua" )`
5. `include( "extensions/client/render.lua" )`
6. `require( "search" )`

### realmに関する確定事項

- `init.lua` が直接参照するrealmフラグは `SERVER` と `CLIENT` だけである。
- この6ファイルには `MENU` 判定がない。MENU stateで `CLIENT` もtrueになるかどうかは、この範囲のソースだけでは確定できない。
- 指定5モジュール自身にはrealm分岐がなく、`init.lua` から無条件にrequireされる。各realmは別Lua state内に同名のmodule tableを持つ想定である。
- `SERVER` / `CLIENT` を未定義のままにすると例外ではなく両方false相当になり、realm固有ロードが静かに全スキップされる。これは成功ではない。
- この `init.lua` 自身には `AddCSLuaFile` 呼び出しがない。

## module loaderとして必要な意味論

### `include`

最低限、次の契約が必要になる。

- VFS上の `lua/` を基準名前空間にし、`@includes/init.lua` のような正規化済みsource nameを持つ。
- 相対パスは現在実行中のchunkのディレクトリから解決する。`includes/init.lua` 内の `include( "util.lua" )` は `includes/util.lua` になる。
- include呼び出しごとにsource directoryをstackへpushし、return/errorのどちらでもpopする。これがネストした `include()` の必須条件である。
- `.`、`..`、`\` を正規化し、VFS root外へ出さない。
- 同じLua stateで同期実行し、source nameと行番号を保持する。
- 完全互換を目指すならchunkの戻り値を `include` の戻り値として伝播できる実行APIが必要である。現行 `LuaState.execute` は戻り値を捨てるため、戻り値付きの公開実行経路を追加する必要がある。
- caller environmentを引き継ぐ必要があるinclude箇所に備え、単に常に新しい `_G` chunkとして実行する設計にはしない。正確なenvironment規則は実コーパスで追加検証する。

既存の `LuaVirtualFileSystem` はbyte単位のread/write境界とpath正規化を持っており、土台として利用できる。ただし、現在のinterfaceだけには「呼び出し元chunkのディレクトリ」「mount優先順位」「ディレクトリ列挙」がない。

### `require`

現行Lua 5.1互換 `require` の `package.loaded`、`package.preload`、loader反復、循環用sentinelは利用できる。一方、既定 `package.path` は `?.lua;?/init.lua` なので、`require( "baseclass" )` から `includes/modules/baseclass.lua` へは到達しない。

GMod用searcherでは少なくとも次の順を明示する。

1. `package.loaded[name]`
2. GMod組込み/native module registry
3. VFSの `includes/modules/<name>.lua`
4. 将来のaddon/module mount

本家の5ファイルは明示的な `return` を持たず、Lua 5.1の `module( "name" )` がグローバルtableと `package.loaded[name]` を設定する。loaderは、その更新済みtableを `require` の最終値として返さなければならない。

## 評価前に用意する組込みGLua surface

| 名前 | 種別 | 使用箇所 | bootstrap上の注意 |
|---|---|---|---|
| `SERVER`, `CLIENT` | boolean | `init.lua` | `GMLuaRealm`を保持するだけでなく、実行前にLuaグローバルへ設定する。 |
| `include` | native function | `init.lua` | 現在の最初の実停止点。ネスト対応のsource contextが必要。 |
| `require`, `module`, `package.seeall` | Lua 5.1 runtime | 全module | 基本実装は既存。GMod searcherを追加する。 |
| `isfunction`, `isstring`, `isnumber`, `isbool`, `istable` | GLua type predicates | hook/concommand/list | ファイル先頭で関数値をlocalへ固定するため、module評価前に実関数が必要。 |
| `gmod` table | engine-owned table | hook/gamemode | module評価前に同一identityのtableを作る。最低限 `GetGamemode()` が必要。後からtable自体を差し替えない。 |
| `Msg` | native function | gamemode/concommand | 複数引数を連結してconsoleへ出力する。改行は呼び出し側が渡す。事前登録必須。 |
| `ErrorNoHaltWithStack` | native function | hook/concommand | errorをthrowして停止する関数ではなく、stack付きで記録して処理を継続するsurface。任意のstack-level引数も受ける。事前登録必須。 |
| `IsValid` | native function | hook | Entity/Panel等のengine object validityを判定。無効object hookを自動除去するため、identityとlifetimeが必要。事前登録必須。 |
| `AddConsoleCommand` | native function | concommand | engine console dispatcherへcommand名、help、flagsを登録する。事前登録必須。 |
| `ENT`, `SWEP` | contextual tables or nil | baseclass | class chunk評価中だけ対象tableを公開し、通常はnilでよい。`baseclass.Get` が `.Base` を書く。 |
| `pairs`, `type`, `setmetatable`, `getmetatable` | Lua 5.1 base | modules | 既存標準ライブラリで満たせる。table iterationとidentity keyの意味論は維持する。 |
| `string.lower`, `table.insert` | Lua 5.1 libs | concommand/list | 既存標準ライブラリで満たせる。 |
| `table.Merge`, `table.Inherit`, `table.Copy`, `table.GetKeys` | GMod table extensions | gamemode/baseclass/list | 実体は後段の本家 `extensions/table.lua` にある。moduleが保持するのはtable objectへの参照なので、同じtableへ後から本家関数を追加すれば見える。table objectを差し替えてはいけない。 |

必要なengine object型は、この範囲では少なくとも「identityをtable keyにできる」「metatable経由で `.IsValid` を参照できる」「`IsValid(value)` がlifetimeを返せる」objectである。hook identifierはEntityだけに限定されず、Panelその他も許容する設計になっている。

## `hook.lua`

### 公開API

| API | 意味 |
|---|---|
| `hook.GetTable()` | 内部hook tableそのものを返す。copyではない。 |
| `hook.Add(event_name, identifier, func)` | event別tableへ上書き登録する。 |
| `hook.Remove(event_name, identifier)` | 対応entryをnilにする。 |
| `hook.Run(name, ...)` | `gmod.GetGamemode()` を初回にcacheし、`hook.Call` へ渡す。 |
| `hook.Call(name, gm, ...)` | 登録hookを先に実行し、全てnilならgamemode methodへfallbackする。 |

### 正確な挙動

- `event_name` はstring必須、callbackはfunction必須。
- identifierはstring、または `.IsValid` memberを持つobjectを許す。number、boolean、function、nilは拒否対象である。
- string identifierのcallbackは `func(...)`、object identifierはobjectがvalidなら `func(object, ...)` として呼ぶ。
- objectがinvalidならdispatch中にentryを削除する。
- 各callbackの戻り値を最大6個まで受け、1個目がnon-nilなら即座に残りのhookとgamemode fallbackを打ち切る。`false` もnon-nilなのでoverrideになる。
- 全hookがnilを返した場合だけ `gm[name](gm, ...)` を呼ぶ。
- hook列挙は `pairs` であり、同一event内の順序を保証してはいけない。

### 実装上の阻害点

`gmod`、型predicate、`IsValid`、`ErrorNoHaltWithStack` はすべてmodule評価時にlocalへcaptureされる。後付けglobalでは直らない。また、engine objectをLua tableで一時代用するとvalidity/lifetimeとidentity semanticsを後で壊しやすいので、最初から共通object wrapper契約を決めるべきである。

## `gamemode.lua`

### 公開API

| API | 意味 |
|---|---|
| `gamemode.Register(t, name, derived)` | gamemode登録、継承、reload merge、baseclass登録を行う。 |
| `gamemode.Get(name)` | module内 `GameList[name]` を返す。 |
| `gamemode.Call(name, ...)` | current gamemodeをcacheし、`hook.Call` を通して呼ぶ。 |

### 正確な挙動

- 現current GMの `FolderName == name` なら新tableをcurrent GMへmergeし、`OnReloaded` を呼ぶ。
- current GMの `BaseClass.FolderName == name` の場合もbase tableへmergeして `OnReloaded` を呼ぶ。
- `name != "base"` なら `gamemode.Get(derived)` を探し、見つかれば `table.Inherit(t, basetable)`、なければ `Msg` でwarningを出す。
- 最後に `GameList[name] = t` とし、`baseclass.Set("gamemode_" .. name, t)` も行う。
- `gamemode.Call` はcurrent GMに対象methodがなければ `false` を返す。それ以外は必ず `hook.Call` を通す。

### 実装上の阻害点

`gamemode.lua` は先行ロード済みのグローバル `hook` と `baseclass` tableをmodule評価時にlocalへcaptureする。そのため `init.lua` の `baseclass -> ... -> hook -> gamemode` 順は意味があり、並列ロードしてはいけない。

`table.Merge` と `table.Inherit` は本家 `extensions/table.lua` の後付けでよい。local `table` が同一table objectを保持しているためである。ただし、gamemode登録をextensions完了前に開始してはいけない。

## `baseclass.lua`

### 公開API

| API | 意味 |
|---|---|
| `baseclass.Get(name)` | forward-reference可能なclass tableを返す。 |
| `baseclass.Set(name, tab)` | classを登録し、既存placeholderがあればidentityを維持してmergeする。 |

### 正確な挙動

- `Get(name)` は現在 `ENT` があれば `ENT.Base = name`、`SWEP` があれば `SWEP.Base = name` を副作用として設定する。
- 未登録nameでも空tableを作って返す。このplaceholderによりclass定義順へ依存しない。
- `Set` で未登録なら渡された `tab` 自体を登録する。
- 既存placeholder/classがある場合は、その既存tableへ `table.Merge` し、渡された `tab` のmetatableも移す。既に返された参照のidentityを壊さない。
- 最後に登録tableへ `ThisClass = name` を設定する。
- このmoduleだけ `module( "baseclass", package.seeall )` を使い、module environmentから `_G` を参照できる。

### `DEFINE_BASECLASS` は別の必須構文機能

コメントに明記されている通り、engineは利用側ソースの

```lua
DEFINE_BASECLASS( "base_class_name" )
```

を、概念的には次へ置換する。

```lua
local BaseClass = baseclass.Get( "base_class_name" )
```

これは通常のグローバル関数では代替できない。関数呼び出しからcaller chunkへ新しいlexical localを注入できないためである。token/AST変換として実装し、行番号を維持する必要がある。5モジュール自身のロードにはまだ不要だが、Base Gamemodeへ進む前のhard blockerになる。

## `concommand.lua`

### 公開API

| API | 意味 |
|---|---|
| `concommand.GetTable()` | command callback tableとautocomplete tableの2値を返す。 |
| `concommand.Add(name, func, completefunc, help, flags)` | 小文字keyでLua callbackを保存し、engine commandも登録する。 |
| `concommand.Remove(name)` | Lua側callback/completion entryを削除する。 |
| `concommand.Run(player, command, arguments, argumentsStr)` | engineから未知commandをLuaへdispatchする。 |
| `concommand.AutoComplete(command, argumentsStr, arguments)` | 登録済みcompletion callbackを呼ぶ。 |

### 正確な挙動

- lookup keyは常に `string.lower(name/command)` だが、callbackへ渡すcommandはengineから来た元の文字列である。
- `Add` はcallbackとcompletion callbackの型を検査し、問題時は `ErrorNoHaltWithStack(..., 2)` を呼ぶ。
- 登録時に `AddConsoleCommand(name, help, flags)` を必ず呼び、engine console側へ入口を作る。
- `Run` のcallback引数は `(player, command, arguments, argumentsStr)`。
- 登録commandがなければ `Msg("Unknown command: " .. command .. "\n")` を出して `false`、見つかれば実行して `true`。
- `Remove` はこのソース上ではLua tableだけを消し、engine登録解除関数は呼ばない。

### 実装上の阻害点

command registryを単なるLua dictionaryにせず、console入力、`lua_run`、将来のplayer-issued commandから同じdispatcherへ到達させる必要がある。`Player` はこの段階では完全なEntity APIでなくても、callbackへidentityを保って渡せるwrapperまたはserver console用NULL表現が必要になる。

## `list.lua`

### 公開API

| API | 意味 |
|---|---|
| `list.Get(listid)` | 対象listのcopyを返す。存在しなければ作成してからcopyする。 |
| `list.GetForEdit(listid, nocreate)` | 内部tableそのものを返す。`nocreate` がtruthyなら未登録時に作らない。 |
| `list.GetTable()` | 登録済みlist idの配列を返す。registryそのものではない。 |
| `list.Add(listid, value)` | array部末尾へ追加し、`table.insert` の戻り値を返す。 |
| `list.Contains(listid, value)` | 全key/valueを `pairs` で走査し、Lua equalityで検索する。 |
| `list.Set(listid, key, value)` | key指定entryを設定する。 |
| `list.RemoveEntry(listid, key)` | key指定entryをnilにする。 |
| `list.HasEntry(listid, key)` | listとentryの双方がnon-nilかを返す。 |
| `list.GetEntry(listid, key)` | entryがtableならcopy、その他の型ならそのまま返す。 |

### 実装上の阻害点

`table.Copy` と `table.GetKeys` は後段の本家 `extensions/table.lua` で追加される。深いcopy、循環参照、engine userdataの扱いをSwiftで別実装してずらすより、本家extensionを動かす方を優先する。`istable` だけは関数値を先頭でlocal captureするので事前登録が必要である。

## 現行Garry's PADとの差分

| 項目 | 現状 | 判定 |
|---|---|---|
| 5モジュールのGLua構文parse/evaluate | 実ファイル単独ロードは全てexit 0 | 通過 |
| Lua 5.1 `module`, `package.seeall`, `package.loaded` | 実装済み | 土台として利用可能 |
| GLua演算子 `!`, `!=`, `&&`, `||` | parser対応済み。対象モジュールもロード成功 | 通過 |
| byte-oriented VFS | protocolとmemory実装あり | 土台あり |
| `include` | グローバル未実装 | 最初のhard blocker |
| nested include source context | 未実装 | hard blocker |
| GMod module search path | 既定pathは `?.lua;?/init.lua` | hard blocker |
| realm globals | `GMLuaRuntime.realm` はあるがLuaへ `SERVER/CLIENT` を設定していない | silent wrong-path blocker |
| GLua type predicates | 登録なし | module API利用時のhard blocker |
| `gmod.GetGamemode`, `Msg`, `IsValid`, `ErrorNoHaltWithStack` | 登録なし | hook/gamemode利用時のhard blocker |
| `AddConsoleCommand` とengine dispatch | 登録なし | concommand利用時のhard blocker |
| GMod table extensions | 標準Lua tableのみ。本家extensionはまだ未起動 | functional blocker |
| `DEFINE_BASECLASS` lexical rewrite | 未実装 | Base Gamemode前のhard blocker |

確認コマンド相当の結果:

- `GModLuaConformance.exe --file <各module実ファイル>`: 5件すべてexit 0。
- `GModLuaConformance.exe --file .../lua/includes/init.lua`: exit 1、`attempt to call a nil value`。最初の実行文から6行目の未定義 `include` と確定できる。

単独moduleロードが成功しても、その時点でnilだったグローバル関数はlocalへnilのままcaptureされている。この結果を「module実装完了」と解釈してはいけない。

## Garry's PADでの実装順

### Milestone A: source loader contract

1. `LuaState` に、chunk戻り値を返せる公開実行APIと、必要なら指定environmentでchunkを実行するAPIを追加する。
2. 実行中chunkの正規化source path/current directoryを取得できるcontextを追加する。
3. VFSを `lua/` rootへmountし、read-only game layerとwritable layerを分離する。
4. path stackを使う同期 `include(path)` を登録する。
5. nested include、error unwind、同名ファイルを別directoryからincludeするfixtureをWindowsで自動試験する。

### Milestone B: realm/bootstrap globals

1. state生成直後に `SERVER` / `CLIENT` とGarry's PAD側のrealm表現を設定する。
2. `isfunction/isstring/isnumber/isbool/istable` を登録する。
3. `Msg`、`ErrorNoHaltWithStack` をconsole/loggerへ接続する。
4. identityとlifetimeを持つ共通engine object wrapperを定義し、`IsValid` を登録する。
5. 同一identityの `gmod` tableとcurrent gamemode slotを作り、`gmod.GetGamemode()` を登録する。
6. `AddConsoleCommand` とconsole dispatcher registryを作る。

### Milestone C: GMod module loader

1. native/preloadを先に、`includes/modules/<name>.lua` を次に探すsearcherを追加する。
2. `baseclass -> concommand -> saverestore -> hook -> gamemode` の直列順を守る。
3. 同一moduleの2回目requireが同じtable identityを返すことを検証する。
4. module評価失敗時の `package.loaded` sentinel挙動をPUC Lua 5.1/GModに合わせ、少なくとも失敗したmoduleを通常のloaded値として静かに返さない。診断にはvirtual pathとLua lineを含める。

### Milestone D: 本家module behavior tests

1. `hook`: string/object identifier、invalid object自動除去、false override、6戻り値、GM fallback。
2. `baseclass`: forward placeholder identity、late `Set` merge、metatable移送、`ENT/SWEP.Base`。
3. `gamemode`: derived inherit、reload merge、`OnReloaded`、hook優先、存在しないmethodのfalse。
4. `concommand`: case-insensitive lookup、4 callback引数、autocomplete、unknown message。
5. `list`: edit/copy分離、nocreate、table entry copy、object identity保持。
6. この時点で本家 `extensions/table.lua` を使い、Swift独自版との意味差を作らない。

### Milestone E: Base Gamemodeへ渡す前

1. `DEFINE_BASECLASS` をtoken/AST rewriteとして実装する。
2. source lineを維持し、debug hook/tracebackの行番号が変わらないことを試験する。
3. `ENT` / `SWEP` などclass-registration contextをchunk単位でpush/popする。

## 最小acceptance criteria

この解析範囲を完了扱いにできる条件は次の通り。

- server stateで `SERVER == true`、`CLIENT == false`、client stateではその逆になる。
- `@includes/init.lua` からの相対includeが `includes/util.lua` へ解決され、さらにその中のnested includeも正しいcaller directoryを使う。
- `require("baseclass")` が `includes/modules/baseclass.lua` をロードし、`baseclass == package.loaded.baseclass` になる。
- 指定5モジュールがnil stubなしでロードされ、公開API tableが揃う。
- moduleロード後にグローバルを後付けして誤魔化すtestが存在しない。必要built-inは評価前に登録される。
- 上記Milestone Dのbehavior testsがWindows Runnerで自動実行できる。
- 未実装のrealm branchやmoduleをPASS扱いせず、full `init.lua` の次の停止file/path/lineを報告する。

## この文書の境界

`util.lua`、`util/sql.lua`、`extensions/net.lua`、残りのmodule、extensionsの内部依存はこの文書では解析していない。したがって、`include` 実装後に `init.lua` が直ちにmodule sectionまで到達するとは断定しない。ここで確定したのは、現在の最初の停止点、正確なトップレベル順序、指定5モジュールの契約、およびそれらを壊さずに起動するためのbootstrap要件である。
