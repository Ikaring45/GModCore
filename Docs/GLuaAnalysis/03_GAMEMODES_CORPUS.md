# Base / autorun / Sandbox / Spawnmenu / TTT 互換コーパス解析

解析日: 2026-08-19
対象: ローカルにインストールされた Garry's Mod の実ファイル（読み取り専用）
Steam appid: `4000`
Steam buildid: `24721252`
`steam.inf` PatchVersion: `2026.04.29`
実行トレース: x86-64 build `2026.08.13 (10119)` / `gm_construct` / singleplayer

## 0. 結論

Base、34本のautorun、Sandbox、Spawnmenu、TTTを調べた結果、Garry's PADの次の進路は明確である。

1. Base/SandboxをSwiftで書き直す必要はない。本家Luaが要求するVFS、realm、registry、Entity、net、ConVar、VGUIのnative substrateを実装し、本家Luaを無改変で起動する。
2. Spawnmenuは単独のSwift UIではなく、本家Sandbox Luaを動かすVGUI互換層の上に成立させる。Spawnmenuだけで33 Luaファイル、20個のVGUI class登録、6個のcontent type、8個のcreation tabがある。
3. 最初の実行マイルストーンは、SERVER/CLIENTを別Lua stateとして起動し、`Base -> autorun/addons -> Sandbox -> PostGamemodeLoaded -> Initialize -> InitPostEntity` を正しい順序で完走することとする。
4. TTTはその次の大規模回帰コーパスに適している。TTT単体で142 Luaファイル、約41,816行あり、net、Entity/SWEP/SENT、hook、timer、ConVar、VGUI、描画を横断する。
5. 現在のGModLua parserは、本書の全246ファイルを構文解析できた。現在の主要な不足はGLua構文ではなく、`include` とrealm-aware VFS、その上のGMod API/runtimeである。

ここでいう「起動成功」は、未知のAPIをすべて無条件no-opにして例外を隠すことではない。登録table、ConVar値、net buffer、Entity identity、panel treeなど、後続の本家Luaが読む状態を保持して初めて互換と判定する。

## 1. 解析スナップショットとコーパス規模

行数はこのローカルスナップショットを改行で分割した値である。Sandboxの `drive/drive_sandbox.lua` はGamemodeディレクトリ内ではなく、グローバルLua mountの `lua/drive/drive_sandbox.lua` にあるため別計上した。

| 区分 | Luaファイル | 行数 | 主なrealm |
|---|---:|---:|---|
| Base Gamemode | 19 | 4,430 | SHARED / SERVER / CLIENT |
| `lua/autorun` | 34 | 4,593 | SHARED / SERVER / CLIENT |
| Sandbox Gamemode（Spawnmenu含む） | 50 | 9,382 | SHARED / SERVER / CLIENT |
| `lua/drive/drive_sandbox.lua` | 1 | 214 | SHARED |
| TTT Gamemode + entities | 142 | 41,816 | SHARED / SERVER / CLIENT |
| 合計 | **246** | **60,435** | 3 gameplay realms |

主要entry pointの識別値は次のとおり。

| ファイル | 行数 | SHA-256 |
|---|---:|---|
| `gamemodes/base/gamemode/shared.lua` | 273 | `F7D469452574E8B0FE6DEBB25042D072696CF0CC3AD41192C3444418B33084BC` |
| `gamemodes/base/gamemode/init.lua` | 181 | `246DA7494FA51173B85D1BF9A85FC2FC2BA1DDC142051E57FE2A25B8681894E3` |
| `gamemodes/base/gamemode/cl_init.lua` | 737 | `EB80CE9E1050537E9C00CB1C79F500663BFF3D06E9BF6919B68660B129B3CFB9` |
| `gamemodes/sandbox/gamemode/shared.lua` | 325 | `12A8FED7D29DD23D612EDB616B2CF54F21F021EC70CCE1B0F85D89889E642D33` |
| `gamemodes/sandbox/gamemode/init.lua` | 177 | `96C94F27D2069353C88485160270D9E1CF45090E7BCFF485B1B2D01F35EBE9B6` |
| `gamemodes/sandbox/gamemode/cl_init.lua` | 183 | `1FFBFF3A3666387BA30CC2AEBA51F231B8B08E4E0933902CB7FBC58D18501960` |
| `gamemodes/sandbox/gamemode/cl_spawnmenu.lua` | 137 | `5527E5C149A9909733ECCDB48FB12A126370C325B3414DAE5236D9934D17FA4D` |
| `gamemodes/sandbox/gamemode/spawnmenu/spawnmenu.lua` | 398 | `EED319F5E81F66BEE239FD6223D7A1B164853974B7C65C9D723B9D5537A446A0` |
| `gamemodes/terrortown/gamemode/shared.lua` | 252 | `30A490687BC6F3948CE1B7EE5C5EB90452187FFFC80E41EA58A89B3B1EEDAADA` |
| `gamemodes/terrortown/gamemode/init.lua` | 966 | `6B75F1EC5F53A4355CBD7811E63BE3C67BF3212F4358ECEB0AF44F9FCD526F40` |
| `gamemodes/terrortown/gamemode/cl_init.lua` | 408 | `929ED383AF1D37E7BABC9CA73AF9596DB3D90E6007FFF72C925C87FAD2FDAF7F` |

### 1.1 現在のWindows Runnerでのparser基準値

各ファイルを新しい `GMLuaRuntime` へ `--file` で渡した。GModLuaは実行前にchunk全体をparseするため、parser errorと実行時API不足を分離できる。

```text
FILES=246
PARSE_OK=246
PARSER_FAIL=0
EXEC_PASS=4
RUNTIME_FAIL=242
PROCESS_CRASH=0
```

単独実行まで通った4本は次のとおり。

- `sandbox/gamemode/prop_tools.lua`
- `terrortown/gamemode/corpse_shd.lua`
- `terrortown/gamemode/util.lua`
- `terrortown/gamemode/weaponry_shd.lua`

残り242本のruntime failureは、ファイルを本来のinclude context、realm、GMod APIなしで単独実行した結果なので、互換率を意味しない。重要なのは、この大規模な実コーパスで現時点のparser failureが0であること。このgateは今後も固定回帰にする。

## 2. 実機GModで確認したライフサイクル

実GModのログで、ネストした `include()` を含めて次の順序を確認した。

### 2.1 SERVER

```text
Base init.lua
  shared.lua
    obj_player_extend.lua
    gravitygun.lua
    player_shd.lua
    animations.lua
    player_class/player_default.lua
      taunt_camera.lua
  player.lua
  npc.lua
  variable_edit.lua

autorun / addons

Sandbox init.lua
  shared.lua
    player_extension.lua
    persistence.lua
    save_load.lua
    player_class/player_sandbox.lua
    drive/drive_sandbox.lua
    editor_player.lua
  commands.lua
    prop_tools.lua
  player.lua
  spawnmenu/init.lua

PostGamemodeLoaded
Initialize
InitPostEntity
```

`editor_player.lua` はshared graphから呼ばれるが、SERVERでは `AddCSLuaFile()` を行って即returnする。`spawnmenu/init.lua` もSERVERでクライアント配布対象を列挙するファイルであり、UIを生成しない。

### 2.2 CLIENT

```text
Base cl_init.lua
  shared.lua
    obj_player_extend.lua
    gravitygun.lua
    player_shd.lua
    animations.lua
    player_class/player_default.lua
      taunt_camera.lua
  cl_scoreboard.lua
  cl_targetid.lua
  cl_hudpickup.lua
  cl_spawnmenu.lua
  cl_deathnotice.lua
  cl_pickteam.lua
  cl_voice.lua

autorun / addons

Sandbox cl_init.lua
  shared.lua
    player_extension.lua
    persistence.lua                 # CLIENTでは即return
    save_load.lua                   # CLIENT branch
    player_class/player_sandbox.lua
    drive/drive_sandbox.lua
    editor_player.lua               # CLIENT body
  cl_spawnmenu.lua
    spawnmenu/spawnmenu.lua
      toolmenu.lua
        toolpanel.lua
          controlpanel.lua
            controls/manifest.lua
              control_presets.lua
                preset_editor.lua
              ropematerial.lua
              ctrlnumpad.lua
              ctrlcolor.lua
              ctrllistbox.lua
      contextmenu.lua
      creationmenu.lua
        creationmenu/manifest.lua
          content/content.lua
            contenticon.lua
            postprocessicon.lua
            contentcontainer.lua
            contentsidebar.lua
              contentsidebartoolbox.lua
                contentheader.lua
              contentsearch.lua      # vgui.RegisterFile経由
            contenttypes/custom.lua
            contenttypes/npcs.lua
            contenttypes/weapons.lua
            contenttypes/entities.lua
            contenttypes/postprocess.lua
            contenttypes/vehicles.lua
            contenttypes/saves.lua
            contenttypes/dupes.lua
            contenttypes/gameprops.lua
            contenttypes/addonprops.lua
  cl_notice.lua
  cl_hints.lua
  cl_worldtips.lua
  cl_search_models.lua
  gui/IconEditor.lua

PostGamemodeLoaded
Initialize
player connection / SERVER PlayerInitialSpawn / PlayerSpawn
InitPostEntity
```

ここで重要なのは、SpawnmenuのLua class、Content Browser、各Content Typeが `PostGamemodeLoaded` より前にすべて登録されること。`spawnmenu.lua` は `OnGamemodeLoaded` hookへ `CreateSpawnMenu` を登録するため、ロード完了後のevent dispatchで実panel treeが作られる。

### 2.3 ライフサイクル上の不変条件

- SERVERとCLIENTは同じglobal tableを共有しない。
- `SERVER` / `CLIENT` はstate生成時に決まり、途中で切り替えない。
- Baseを先に構築し、その後に対象Gamemodeの `BaseClass` を解決する。
- autorun/addonsはBaseの後、Sandbox本体の前に実行する。
- `PostGamemodeLoaded`、`Initialize`、`InitPostEntity` は単なるログではなく、登録済みhookとGamemode methodをGMod順でdispatchする。
- CLIENTのplayer entityが有効になる時点はSERVER/CLIENT起動完了より後。起動中の `LocalPlayer()` は無効entityを返し得る。

## 3. Base Gamemode

### 3.1 realm別include graph

| realm | entry | 順序 |
|---|---|---|
| SERVER | `base/gamemode/init.lua` | `shared`の5本+`taunt_camera` -> `player.lua` -> `npc.lua` -> `variable_edit.lua` |
| CLIENT | `base/gamemode/cl_init.lua` | `shared`の5本+`taunt_camera` -> scoreboard -> targetid -> hudpickup -> spawnmenu bindings -> deathnotice -> pickteam -> voice |
| SHARED | `base/gamemode/shared.lua` | Player meta拡張 -> gravitygun hooks -> shared player hooks -> animation hooks -> default player class |

### 3.2 ロード時に必要なprimitive

Baseは多くのengine callをcallback内へ遅延しているが、次はロード時点で必要になる。

| ファイル | ロード時副作用 | 先に必要な互換API |
|---|---|---|
| `obj_player_extend.lua` | Player metatableへmethod追加 | `FindMetaTable("Player")`、per-object Lua table、Entity/PhysicsObject identity |
| `player_default.lua` | `player_default` class登録 | `player_manager.RegisterClass`、`AddCSLuaFile`、base player class registry |
| `taunt_camera.lua` | mouse ConVarをlocalへcache | `GetConVar("m_pitch")`、`GetConVar("m_yaw")`、ConVar userdata |
| `npc.lua` | 6個のnetwork string登録 | `util.AddNetworkString`、後続用 `net.Start/Write*/Broadcast` |
| `init.lua` | hostname timer登録 | `timer.Create`、global string、clock scheduler |
| `cl_scoreboard.lua` | scoreboard panel table登録 | `vgui.RegisterTable`、`vgui.CreateFromTable`、Panel base class |
| `cl_deathnotice.lua` | ConVar取得、6 receiver登録 | `CreateConVar`、`GetConVar`、`net.Receive`、killicon/list |
| `cl_spawnmenu.lua` | `+menu/-menu/+menu_context/-menu_context` 登録 | `concommand.Add`、gui enable/disable bridge |
| `cl_voice.lua` | cleanup timerとhook登録 | `timer.Create`、`hook.Add`、voice/player validity |

特に `obj_player_extend.lua` は `FindMetaTable("Player")` がnilならreturnする。後からPlayer metatableを追加しても、失われたmethodは自動復旧しない。Player/Entity/Weapon/Panelなどのmetatableは本家Luaをロードする前に作る必要がある。

Base全体が遅延実行で要求する主なカテゴリは以下。

- gamemode dispatch: `gamemode.Call`、`hook.Call/Run/Add`
- player: `player.Iterator`、`player_manager.RunClass/SetPlayerClass/Translate*`
- entity/physics: Entity、Player、Weapon、Vehicle、MoveData、UserCmd、DamageInfo、PhysicsObject method
- net: UInt、String、Entityのencode/decodeとreceiver dispatch
- client rendering: `surface`、`draw`、`render`、`cam`、HUD、killicon、language
- team/drive: `team.*`、`drive.*`
- time/input: `CurTime`、`RealTime`、timer、input constants

## 4. `lua/autorun` 34本

34本は次の内訳で完全に説明できる。

| 区分 | 本数 | ファイル |
|---|---:|---|
| root/shared | 7 | `base_npcs.lua`, `base_vehicles.lua`, `developer_functions.lua`, `game_hl2.lua`, `menubar.lua`, `properties.lua`, `utilities_menu.lua` |
| client | 2 | `client/demo_recording.lua`, `client/gm_demo.lua` |
| property子ファイル | 14 | `bodygroups`, `bone_manipulate`, `collisions`, `drive`, `editentity`, `gravity`, `ignite`, `keep_upright`, `kinect_controller`, `npc_scale`, `persist`, `remove`, `skin`, `statue` |
| server | 1 | `server/admin_functions.lua` |
| server sensorbones | 10 | `css`, `eli`, `tf2_engineer`, `tf2_heavy`, `tf2_medic`, `tf2_pyro_demo`, `tf2_scout`, `tf2_sniper`, `tf2_spy_solider`, `valvebiped` |
| 合計 | **34** |  |

`properties.lua` は14子ファイルを次の固定順でincludeする。

```text
bone_manipulate -> remove -> statue -> keep_upright -> persist -> drive
-> ignite -> collisions -> gravity -> npc_scale -> editentity
-> kinect_controller -> bodygroups -> skin
```

### 4.1 機能・realm・要求API

| cluster | 実行realm | 主なロード時成果 | 要求カテゴリ |
|---|---|---|---|
| Base NPC/Vehicle catalog | SHARED | `list.Set("NPC"/"Vehicles", ...)` | list registry、Color、model path |
| `game_hl2.lua` | SHARED | SENT/SWEP duplicator factory登録 | `ents.Create`、`gamemode.Call`、list、duplicator、Entity lifecycle |
| developer functions | SHARED | debug console commands/hook検索 | concommand、hook、debug info、console output |
| menubar | CLIENT body | menu populate hook | `AddCSLuaFile()`、SERVER早期return、hook、ConVar、menu panel |
| properties 14本 | SHARED | property descriptor登録 | `properties.Add`、net request/receive、Entity methods、context menu |
| utilities menu | CLIENT body | Utilities tool panel登録 | SERVER配布+return、spawnmenu、ConVar、ControlPanel |
| demo recording | CLIENT | recording hooks/HUD | hook、render、util、demo engine bridge |
| admin functions | SERVER | admin concommands | concommand、Player permissions |
| sensorbones | SERVER | model別sensor bone table登録 | list registry、case-insensitive model names |

ここでは `AddCSLuaFile()` の引数省略が多い。引数なしは「現在評価中のsource file」を送信対象にするため、VFSはinclude stack上のcurrent sourceを保持しなければならない。

autorun回帰では、単に34本が例外なく終わるだけでなく、次をsnapshot比較する。

- NPC、Vehicle、SensorBone listのkeyと件数
- duplicator entity class/modifierの登録名
- property ID 14個とrealm別callback table
- concommand名、hook event/name pair
- SERVERがCLIENT-only bodyを実行していないこと
- CLIENTがSERVER-only admin/sensorbone bodyを実行していないこと

## 5. Sandbox本体

### 5.1 SERVER graphと責務

`init.lua` はclient用11ファイルを配布対象へ追加した後、次をロードする。

```text
shared.lua
  player_extension.lua
  persistence.lua
  save_load.lua
  player_class/player_sandbox.lua
  drive/drive_sandbox.lua
  editor_player.lua          # SERVER: AddCSLuaFileしてreturn
commands.lua
  prop_tools.lua
player.lua
spawnmenu/init.lua           # Spawnmenu 32ファイルを配布対象へ追加
```

主なload-time stateは以下。

- `DEFINE_BASECLASS("gamemode_base")`
- cleanup category 8個: props、ragdolls、effects、npcs、constraints、ropeconstraints、sents、vehicles
- `physgun_limited` ConVar
- Player metatable Sandbox拡張
- persistence hook群
- `GModSave` network string、save/load receiver、`gm_save` command
- `player_sandbox` class（parent=`player_default`）
- `drive_sandbox` class（parent=`drive_base`）
- spawn系server concommand群
- undo、cleanup、duplicator、constraintを使うentity spawn pipeline

### 5.2 CLIENT graphと責務

CLIENTではshared graphの後にSpawnmenu全体をロードし、その後でnotice、hint、world tip、model search、IconEditorを登録する。

| ファイル | realmの特徴 | 主な要求API |
|---|---|---|
| `player_extension.lua` | SHARED内にSERVER/CLIENT分岐 | Player metatable、NW/count、timer、hook |
| `persistence.lua` | CLIENTは即return | SERVER file DATA、Entity serialization、duplicator |
| `save_load.lua` | SERVER/CLIENT大分岐 | net byte payload、compress/JSON、game cleanup、console command |
| `player_sandbox.lua` | SHARED、CLIENTのみuser ConVar作成 | player class inheritance、ConVar flags、model/color |
| `drive_sandbox.lua` | SHARED | drive registry、camera/movement、Entity/PhysicsObject |
| `editor_player.lua` | SERVERは配布してreturn、CLIENT本体 | VGUI、model list、ConVar、render preview |
| `cl_init.lua` | CLIENT | baseclass、halo/render、effects、hook |
| `cl_search_models.lua` | CLIENT | async-like timer、`file.Find`、list、model validation |
| `gui/IconEditor.lua` | CLIENT | deep VGUI inheritance、material/model rendering |

Sandbox本体（Spawnmenuを除く）が使う主要native境界は次のとおり。

- VFS/DATA: `file.CreateDir/Find/Read/Write`
- net: Bool、UInt、raw Data、receiver、send/broadcast
- serialization: JSON、compress/decompress、duplicator copy/paste
- registries: hook、concommand、list、player_manager、drive、cleanup、undo
- world/entity: `ents.Create/GetAll`、world、trace、model validity、PhysicsObject
- ConVar/cvars: replicated/userinfo/archive flags、change callback
- time: named timerの作成、再作成、削除、存在確認

## 6. VFSで必ず再現する挙動

このコーパスから、iPad VFSに必要な挙動が具体的に判明した。

### 6.1 ネストinclude context

相対pathは常に現在のsource directoryを基準に解決する。`content.lua -> contentsidebar.lua -> contentsidebartoolbox.lua -> contentheader.lua` のように3段以上ネストするので、単一のcurrent directory変数ではなくstackが必要。

### 6.2 Gamemode localからglobal Lua mountへのfallback

Sandbox `shared.lua` の `include("drive/drive_sandbox.lua")` は物理的な `sandbox/gamemode/drive` ではなく、`garrysmod/lua/drive/drive_sandbox.lua` を解決する。探索は概念上、次を区別する必要がある。

1. current source directory
2. active gamemode Lua root
3. mounted global `garrysmod/lua`
4. addon/workshop Lua mounts（優先順位込み）

### 6.3 case-insensitive lookup

実ファイルは小文字でも、本家Luaは異なるcaseで参照する。

- Sandbox: `gui/IconEditor.lua` -> 物理ファイル `gui/iconeditor.lua`
- TTT: `vgui/ColoredBox.lua` -> `vgui/coloredbox.lua`
- TTT: `vgui/SimpleIcon.lua` -> `vgui/simpleicon.lua`
- TTT: `vgui/ProgressBar.lua` -> `vgui/progressbar.lua`
- TTT: `vgui/ScrollLabel.lua` -> `vgui/scrolllabel.lua`

iPad側のcase-sensitive filesystemへそのまま委譲すると失敗する。VFS indexは正規化pathとASCII case-fold keyを分離し、曖昧なcase衝突を検出する。

### 6.4 Gamemode配布path alias

SERVERの `spawnmenu/init.lua` は `sandbox/gamemode/spawnmenu/...` を `AddCSLuaFile` へ渡す。一方、物理ファイルは `garrysmod/gamemodes/sandbox/gamemode/spawnmenu/...` にある。active gamemode名を使ったalias解決が必要。

### 6.5 include以外のLua loader

`contentsidebar.lua` は `vgui.RegisterFile("contentsearch.lua")` でLuaをロードする。`include` だけをtraceして依存graphを作ると漏れる。`vgui.RegisterFile` は同じVFS/source context/error reportingを使う必要がある。

TTTではさらに `file.Find(..., "LUA")` の結果から動的な `include(file)` / `AddCSLuaFile(file)` を行う。定数文字列include専用の実装ではTTT language corpusが欠落する。

## 7. Sandbox Spawnmenu / VGUI / Content system

### 7.1 静的規模

Spawnmenu subtreeは33ファイル、約5,189行。

| 登録対象 | 数 | 内容 |
|---|---:|---|
| `vgui.Register` | 20 | SpawnMenu、ToolMenu、ControlPanel、CreationMenu、Content*、各Ctrlなど |
| `spawnmenu.AddContentType` | 6 | `header`, `entity`, `vehicle`, `npc`, `weapon`, `postprocess` |
| `spawnmenu.AddCreationTab` | 8 | Content、Entities、PostProcess、Weapons、Vehicles、NPCs、Saves、Dupes |
| `hook.Add` | 34 | lifecycle、populate、search、save/revert、content refreshなど |

登録される20 classは次のとおり。

```text
SpawnMenu, ToolMenu, ToolPanel, ControlPanel, ContextMenu, CreationMenu,
ControlPresets, PresetEditor, RopeMaterial, CtrlNumPad, CtrlColor, CtrlListBox,
SpawnmenuContentPanel, ContentIcon, PostProcessIcon, ContentContainer,
ContentHeader, ContentSidebar, ContentSidebarToolbox,
SpawnmenuNPCSidebarToolbox
```

### 7.2 最低限必要な既存VGUI class

継承parentとして少なくとも次が必要。

```text
Panel, EditablePanel, DPanel, DPropertySheet, DForm, DFrame,
DScrollPanel, DLabelEditable, DButton, DComboBox, DDrawer, MatSelect
```

Spawnmenu subtreeが直接 `vgui.Create` する既存classにはさらに次がある。

```text
DBinder, DCategoryList, DCheckBox, DColorMixer, DHorizontalDivider,
DHTML, DIconBrowser, DImageButton, DLabel, DListView, DProperties,
DTextEntry, DTileLayout, DTree, PropSelect
```

最初のVGUI milestoneでは描画を完全再現しなくてもよいが、次は実装する必要がある。

- class registryとinheritance lookup
- `PANEL` table method、`BaseClass`、`DEFINE_BASECLASS`
- panel identity、parent/child ownership、Remove/IsValid
- `vgui.Create/CreateFromTable/Register/RegisterTable/RegisterFile`
- property/method assignment、callback override、`self:Add`
- Dock/layout/size/visibility/focusの状態モデル
- hook/concommand/ConVarとの連携
- tree/node、property sheet、scroll、form、button、text entryの構造的挙動

### 7.3 Content Browserが要求する非UI API

本家Spawnmenuは見た目だけのLuaではない。

- `file.Find/Open` とpath ID (`GAME`, `MOD`, `LUA`)
- `engine.GetAddons/GetGames`
- `game.GetMap/GetWorld`
- `list.Get/GetEntry/Set`
- `util.TableToJSON/TableToKeyValues`
- `spawnmenu.GetPropTable/GetCustomPropTable/PopulateFromEngineTextFiles`
- `steamworks.DownloadUGC/ViewFile`
- model/material/icon metadata
- saves/dupesのローカルファイルとWorkshop metadata

したがって、最初はSaves/Dupes/Addon Propsを「利用不能だが登録済み」のcapability stateとして表示してもよい。ただし関数をnilにせず、結果・error・非同期completionを型どおり返す。後からWorkshop/GMA実装へ差し替えられる境界にする。

## 8. TTTを大規模回帰コーパスにする

### 8.1 規模とrealm分類

TTTは合計142 Luaファイル、約41,816行。

| subtree | ファイル | 行数 |
|---|---:|---:|
| `gamemode/` | 68 | 30,918 |
| `entities/` | 74 | 10,898 |

top-level gamemode Luaの内訳は次のとおり。

- CLIENT entry/implementation: 23本（`cl_init.lua` と `cl_*` 22本）
- SHARED: 9本（`shared.lua`, `util.lua`, `*_shd.lua` 7本）
- SERVER entry/implementation: 14本（`init.lua` とround/entity/player/scoring等）
- 残り: `lang/` 14本と`vgui/` 8本（CLIENTへ動的配布/ロード）

Entity corpusの物理分類は、effects 5本、entities 33本、weapons 32本に加え、entity個別ディレクトリ内の4本である。

### 8.2 TTT entry graph

SHARED entry:

```text
shared.lua
  util.lua
  lang_shd.lua
    cl_lang.lua / lang/*.lua   # realmによりincludeまたはAddCSLuaFile
  equip_items_shd.lua
  radio_shd.lua
```

SERVER entry:

```text
init.lua
  shared.lua
  karma.lua
  entity.lua
  radar.lua
  admin.lua
  traitor_state.lua
  propspec.lua
  weaponry.lua
  gamemsg.lua
  ent_replace.lua
  scoring.lua
  corpse.lua
  player_ext_shd.lua
  player_ext.lua
  player.lua
```

CLIENT entry:

```text
cl_init.lua
  shared.lua
  corpse_shd.lua
  player_ext_shd.lua
  weaponry_shd.lua
  vgui/{ColoredBox,SimpleIcon,ProgressBar,ScrollLabel}.lua
  cl_radio -> cl_disguise -> cl_transfer -> cl_targetid -> cl_search
  -> cl_radar -> cl_tbuttons -> cl_scoreboard -> cl_tips -> cl_help
  -> cl_hud -> cl_msgstack -> cl_hudpickup -> cl_keys -> cl_wepswitch
  -> cl_scoring -> cl_scoring_events -> cl_popups -> cl_equip -> cl_voice
```

SERVER `init.lua` は33個のnetwork stringをpoolし、TTT全体にも33個の `net.Receive` 登録がある。これはnet codecとrealm配送の対称テストに使える。

### 8.3 APIストレスの広さ

次は142ファイルを対象としたnamespace参照の静的件数であり、API個数ではない。コメント/文字列を完全除外するlexer集計ではないため、規模の目安として扱う。

| namespace | 参照 | 該当ファイル | 主な検証対象 |
|---|---:|---:|---|
| `net` | 283 | 24 | message lifecycle、bit width、Entity、realm配送 |
| `util` | 225 | 55 | trace、JSON、effects、network string、CRC/serialization |
| `vgui` | 198 | 21 | scoreboard、equipment、search、popup |
| `surface` | 307 | 30 | font、HUD、icon、material |
| `hook` | 79 | 31 | round/gameplay lifecycle、return override |
| `timer` | 71 | 23 | round transition、idle、radar、delayed action |
| `ents` | 100 | 30 | SENT lifecycle、cache、find/create |
| `player` | 71 | 24 | iterator、role selection、spectator |
| `concommand` | 50 | 25 | admin/client/game commands |
| `render` / `draw` / `cam` | 110 | 25前後 | HUD、world marker、model/3D rendering |
| `file` | 9 | 4 | language discovery、config/report |

TTTだけでもGLua `continue` は7ファイル11箇所、`!=` は54ファイル146箇所、unary `!` は35ファイル619箇所ある。Base+autorun+Sandbox+TTT全体では `continue`、`!=`、`&&`、`||`、unary `!`、C-style commentがすべて現れる。parser回帰は公式Lua 5.1テストだけでなく、この実GLua corpusも毎回通す。

### 8.4 TTT回帰tier

| tier | 実行内容 | 合格条件 |
|---|---|---|
| T0 Parse | 142ファイルをdecode/lex/parse | parser error 0、source名/line保持 |
| T1 Shared boot | `shared.lua` graph | 定数、Color、ConVar、team、LANG/equipment/radio tableが構築される |
| T2 Server boot | `init.lua` graph | 33 network string、server hooks/timers/concommands、round stateが登録される |
| T3 Client boot | `cl_init.lua` graph | 4 TTT VGUI base部品、23 client scripts、33 receiver側が登録される |
| T4 Entity registry | effects/SENT/SWEP全体 | class、Base、realm、Spawnable、network varsが保持される |
| T5 Deterministic behavior | fake clock/player/entity/netでscenario実行 | round、role、corpse、equipment、score、languageをgolden比較 |
| T6 Render contract | headless draw command capture | HUD/VGUIが出したdraw/material/font command列をsnapshot比較 |

T5の最低scenarioは次とする。

1. `ROUND_WAIT -> ROUND_PREP -> ROUND_ACTIVE -> ROUND_POST` の遷移
2. deterministic RNGでのtraitor/detective role assignment
3. `TTT_Role` / `TTT_RoundState` のencode-decode往復
4. death -> corpse creation -> body search -> score event
5. credits付与 -> equipment購入 -> client receiver反映
6. language file discoveryとfallback
7. player disconnect/reconnect、invalid Entity、dead coroutineではなくdead Player参照

clock、random seed、EntIndex、SteamID、map entity一覧はfixtureから注入し、実時間や実ネットワークに依存させない。

## 9. 要求APIの実装優先度

| 優先 | substrate | この段階で解禁される範囲 |
|---:|---|---|
| P0 | realm別Lua state、VFS、include stack、AddCS queue、case-fold、source metadata | 全entry pointの正しい探索と配布 |
| P0 | GMod型/registry基盤: metatable、Entity identity、IsValid、GM/GAMEMODE、baseclass | Base sharedとGamemode inheritance |
| P0 | hook、gamemode、concommand、list、player_manager、drive、properties | Base/autorun/Sandboxのload-time登録 |
| P0 | ConVar/cvars、timer、engine clock | taunt camera、Base timer、Sandbox settings |
| P1 | net bitstream、NetworkString pool、realm queue | Base deathnotice、Sandbox save、TTT protocol |
| P1 | Entity/Player/Weapon/PhysicsObject/UserCmd/MoveData/DamageInfo | Base callbacks、Sandbox spawn、TTT gameplay |
| P1 | file path ID、DATA sandbox、JSON/compress | persistence、save/dupe、language discovery |
| P1 | cleanup、undo、duplicator、constraint | Sandbox server spawn pipeline |
| P2 | structural VGUI class system、input/focus/layout | Base scoreboard、Sandbox Spawnmenu load/create |
| P2 | surface/draw/render/material/model command backend | Sandbox preview、TTT HUD/VGUI |
| P3 | Steamworks/GMA/Workshop、DHTML、mounted game content | Addon Props、Saves/Dupes online content |

P0とP1は「nilを返すstub」ではなく、登録・検索・identity・順序を維持する必要がある。たとえば `hook.Add` がcallbackを保存しない、`GetConVar` が毎回別userdataを返す、`Entity(1)` が毎回別identityを返す実装ではloadは進んでも回帰scenarioが成立しない。

## 10. 最初の実行可能マイルストーン

マイルストーン名を `GLua Gameplay Bootstrap M1` とする。

### 10.1 実装範囲

1. 本家 `lua/includes/init.lua` とcore modules/extensionsをrealm別に起動する。
2. Base SERVER/CLIENT graphを実ファイルの順で実行する。
3. realmに応じたautorunを実行する。
4. Sandbox SERVER/CLIENT graphを実行する。
5. CLIENTでSpawnmenu subtreeをすべてロードし、class/content/hookを登録する。
6. `PostGamemodeLoaded -> Initialize -> InitPostEntity` をdispatchする。

### 10.2 合格条件

- include traceが本書2章のgolden sequenceと一致する。
- SERVER/CLIENTのglobal、hook、ConVar、net receiverが混線しない。
- 引数なし `AddCSLuaFile()` がcurrent sourceを正しく記録する。
- `gui/IconEditor.lua` 等のcase違いを解決できる。
- `drive/drive_sandbox.lua` をglobal Lua mountから解決できる。
- `player_default`、`player_sandbox`、`drive_sandbox` がparent関係込みで登録される。
- Baseのnetwork string 6個、Sandboxの `GModSave` がpoolされる。
- cleanup category 8個が保持される。
- autorun 34本のrealm別registry snapshotがgoldenと一致する。
- SpawnmenuのVGUI class 20個、content type 6個、creation tab 8個が登録される。
- `OnGamemodeLoaded` の `CreateSpawnMenu` hookを保持し、headless panel treeを少なくとも生成できる。
- 未対応のrender/Workshop capabilityは明示的なtyped errorまたは利用不能stateになり、nil callや偽PASSにしない。

このM1が通れば、iPad上でも本家Sandbox Luaの構造を保持したまま、Metal描画やnative physicsを段階的に接続できる。

## 11. 回帰コーパスの保持方法

GMod本体のLuaをリポジトリへ複製するのではなく、ローカルinstallをfixture sourceとして読む方式を推奨する。

```text
Tests/GModCorpus/
  manifest.json                 # logical path, realm, phase, SHA-256
  expected/
    base_server_trace.txt
    base_client_trace.txt
    sandbox_server_trace.txt
    sandbox_client_trace.txt
    autorun_registry.json
    spawnmenu_registry.json
    ttt_net_registry.json
  fixtures/
    fake_players.json
    fake_entities.json
    fake_convars.json
    fake_map.json
```

RunnerへはGMod install rootを明示的に渡す。

```text
--gmod-root <.../GarrysMod/garrysmod>
--realm server|client|menu
--phase parse|load|lifecycle|scenario
--gamemode base|sandbox|terrortown
```

レポートは少なくとも次を分離する。

- `[PASS][PARSE]`
- `[FAIL][LUA51]`
- `[FAIL][GLUA-SYNTAX]`
- `[FAIL][VFS]`
- `[FAIL][MISSING-API]`
- `[FAIL][REALM]`
- `[FAIL][BEHAVIOR]`
- `[SKIP][RENDER]`
- `[SKIP][WORKSHOP]`

GCと同じく、未実装のrender、physics、WorkshopをPASS扱いしない。load-onlyでcallback本体をまだ実行していない場合も、`[PASS][LOAD]` と `[PASS][BEHAVIOR]` を分ける。

## 12. 実装判断

- 本家Sandbox LuaとSpawnmenu Luaを正本とする。
- Swift側はAPI substrateとrenderer/backendを担当する。
- VGUIは本家PANEL tableを動かし、Swift/Metal viewへ投影する。
- SERVER/CLIENT/MENUは別state・別registry・別VFS permissionで扱う。
- TTTはSandbox M1完了後の必須回帰であり、単なるサンプルGamemodeにしない。
- 246ファイルparser gateは今すぐCI/Windows Runnerへ固定できる。
- 次のコード実装はP0のrealm-aware VFS/include/AddCSLuaFileから始め、その直後にBase SERVERのload-time registryを通す。
