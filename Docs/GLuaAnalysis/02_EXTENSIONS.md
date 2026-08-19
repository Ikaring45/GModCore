# GLua extensions 互換層解析

## 0. 調査範囲と結論

この文書は、ローカルの Garry's Mod 実インストールから次の本家 Lua を読み取り専用で解析した結果である。

- Steam appid: `4000`
- Steam branch: `x86-64`
- buildid: `24721252`
- 調査日: `2026-08-19`
- ルート: `garrysmod/lua/includes/extensions/`
- 主対象: `string.lua`, `table.lua`, `math.lua`, `file.lua`, `net.lua`, `entity.lua`, `player.lua`
- 関連分割: `math/ease.lua`, `entity_iter.lua`, `player_auth.lua`, `client/entity.lua`, `client/player.lua`

最重要の結論は次のとおり。

1. **これらの大半は本家 Lua をそのまま実行できる。Swift に再実装すべきなのは、その下の engine primitive と型だけである。**
2. `string/table/math` は、GLua 構文、Lua 5.1 標準ライブラリ、byte string、GMod 型判定を揃えればほぼ全量を Lua のまま流用できる。
3. `file` は薄い Lua wrapper であり、実体は `file.Open`、検索パス付き VFS、File userdata である。
4. `net` は高水準の table/type/entity/color codec が Lua にあり、Swift 側に必要なのは bitstream、message lifecycle、realm 間配送、NetworkString ID、基本型 codec である。
5. `entity/player` は高水準挙動の多くが Lua にある一方、**userdata/metatable registry、EntIndex、per-entity Lua table、NetworkVar/DT slot、NW/NW2、entity lifetime、SQL、realm 分離**は native substrate が必須である。
6. `entity.lua` と `player.lua` は、単なる便利関数集ではない。GMod のオブジェクト lookup 規則そのものを `__index` で定義するため、Workshop 互換性の基礎に位置する。
7. Spawnmenu や Sandbox を先に模造するより、この primitive 層を実装して本家 extensions を無改変で起動する方が、最終的な互換範囲が広い。

## 1. 本家の実ロード順と realm

### 1.1 gameplay realm の順序

`lua/includes/init.lua` では `util.lua` と `util/sql.lua` の直後、通常 modules より前に `extensions/net.lua` がロードされる。その後に `hook`, `gamemode`, `list` などの modules が入り、extensions 本体は次の順でロードされる。

```text
util.lua
util/sql.lua
extensions/net.lua
modules ... hook/gamemode/etc.
gmsave.lua
extensions/entity_iter.lua
extensions/file.lua
extensions/angle.lua
extensions/debug.lua
extensions/entity.lua
extensions/ents.lua
extensions/math.lua
extensions/player.lua
extensions/player_auth.lua
extensions/string.lua
extensions/table.lua
extensions/util.lua
extensions/vector.lua
extensions/game.lua
extensions/motionsensor.lua
extensions/weapon.lua
extensions/coroutine.lua
CLIENT only extensions/client/{entity,globals,panel,player,render}.lua
```

注意点:

- `net.lua` は非常に早くロードされる。`TYPE_*` 定数と native `net` table はこの時点で存在しなければならない。
- `entity.lua` は `string.lua` / `table.lua` より先にロードされるが、それらの追加関数は主に遅延実行される method 内で参照される。
- `hook` module は `entity.lua` / `player.lua` より前なので、extensions はロード時に `hook.Add` を実行できる。
- `player.lua` はロード時に SQL table を確認・作成する。SQL は後回しにできない。
- SERVER の `player_auth.lua` はロード中に `settings/users.txt` を `MOD` search path から読む。VFS mount も後回しにできない。

### 1.2 MENU realm の順序

`lua/includes/init_menu.lua` は gameplay realm より限定された集合だけをロードする。

```text
extensions/string.lua
extensions/table.lua
extensions/math.lua
extensions/client/panel.lua
extensions/util.lua
extensions/file.lua
extensions/debug.lua
extensions/client/render.lua
extensions/client/globals.lua
```

したがって MENU realm には、少なくとも `string/table/math/file` が必要だが、`net/entity/player` を当然のように露出してはいけない。

### 1.3 realm matrix

| ファイル | SERVER | CLIENT | MENU | 備考 |
|---|---:|---:|---:|---|
| `string.lua` | yes | yes | yes | shared pure-Lua extension |
| `table.lua` | yes | yes | yes | shared pure-Lua extension |
| `math.lua` + `math/ease.lua` | yes | yes | yes | shared pure-Lua extension |
| `file.lua` | yes | yes | yes | native VFS policy は realm ごとに分ける |
| `net.lua` | yes | yes | no | 同じ Lua codec、配送方向だけ realm 依存 |
| `entity_iter.lua` | yes | yes | no | engine が cache invalidation を呼ぶ |
| `entity.lua` | yes | yes | no | 内部に SERVER/CLIENT branch がある |
| `client/entity.lua` | no | yes | no | render origin/angle accessor |
| `player.lua` | yes | yes | no | Client の ConCommand queue は CLIENT only |
| `player_auth.lua` | yes | partial | no | query API は shared、user load/mutation は SERVER only |
| `client/player.lua` | no | yes | no | bind/HUD hook を利用 |

実装では単一の `_G` の `SERVER/CLIENT` を切り替えて使い回さず、少なくとも SERVER / CLIENT / MENU ごとに独立した `LuaState`、global table、hook table、net receiver table、per-entity Lua table を持つべきである。

## 2. 共通して要求される GLua 差分

対象ファイルには PUC Lua 5.1 だけでは解釈できない構文が実際に含まれる。

- `!`, `!=`, `&&`, `||`
- `continue`
- `//` や `/* */` は今回の対象本体では目立たないが、同じ loader で扱う前提
- `module("math.ease", package.seeall)`
- userdata/type 固有 metamethod を含む演算

言語・runtime 側で先に満たすべき条件:

- byte-oriented string。NUL と非 UTF-8 byte を壊さない。
- Lua pattern の `%z`、`.`、capture、replacement table/function の Lua 5.1 semantics。
- primitive string metatable が writable で、`getmetatable("")` の `__index` を function に交換できる。
- `str[1]` のような数値 string indexing。これは `string.lua` が追加する `__index` によって成立する。
- `pairs`, `next`, `ipairs`, `#`, `unpack`, `table.sort` の Lua 5.1 semantics。
- function/table/userdata identity が key として安定すること。
- userdata の `__index`, `__newindex`, `__eq`, arithmetic metamethod、method call `:`。
- `module`, `package.seeall`, nested module table の正確な environment behavior。
- error level と型名を含む GMod 互換診断。

## 3. `extensions/string.lua`

### 3.1 追加 API

本家 Lua が追加する API:

- 変換・分割: `ToTable`, `Explode`, `Split`, `Implode`
- escape: `JavascriptSafe`, `PatternSafe`
- path helper: `GetExtensionFromFilename`, `StripExtension`, `GetPathFromFilename`, `GetFileFromFilename`
- 表示: `FormattedTime`, `ToMinutesSecondsMilliseconds`, `ToMinutesSeconds`, `NiceTime`, `NiceSize`, `Comma`, `CardinalToOrdinal`, `NiceName`
- slice/edit: `Left`, `Right`, `Replace`, `Trim`, `TrimRight`, `TrimLeft`, `SetChar`, `GetChar`
- predicate/helper: `StartsWith`, alias `StartWith`, `EndsWith`, `Interpolate`
- Color: `FromColor`, `ToColor`
- string primitive metatable の `__index` override

### 3.2 標準 Lua との差分と落とし穴

- `string` method lookup に加え、数値 key を `string.sub(self, key, key)` に変換する。`"abc"[2] == "b"` 相当が成立する。
- `JavascriptSafe` は NUL、control bytes、quote、backtick、`${}` 関連文字、UTF-8 の U+2028/U+2029 byte sequence を扱う。内部 string を Swift `String` として正規化してはいけない。
- `PatternSafe` は NUL を `%z` にする。pattern engine が byte/NUL safe である必要がある。
- `Explode` の第3引数は `withpattern`。未指定時は plain search であり、separator が空なら byte 単位の `ToTable` になる。
- `FormattedTime` / `NiceSize` / `Comma` は `string.format` の整数、float、padding を利用する。
- `NiceName` は numeric string indexing と GLua `continue` を同時に使う。
- `FromColor` は global `Format`、`ToColor` は global `Color` constructor を利用する。

### 3.3 native primitive

先に native/基盤側で必要:

- Lua 5.1 `string.*`, pattern, `string.format`
- byte string と primitive metatable registry
- `Format` (`string.format` と互換の global helper)
- `Color(r,g,b,a)` と fields `r/g/b/a`
- `isstring`, `isnumber`

### 3.4 実装判断

`string.lua` は**全量を本家 Lua のまま流用**する。Swift で個別 helper を複製しない。特に numeric indexing と binary string の semantics は native layer で保証し、その上でこのファイル自身に string metatable を変更させる。

## 4. `extensions/table.lua`

### 4.1 追加 API

本家 Lua が追加する API:

- copy/merge: `Pack`, `Inherit`, `Copy`, `CopyFromTo`, `Merge`, `Add`
- mutation/query: `Empty`, `IsEmpty`, `HasValue`, `Count`, `ForceInsert`, `RemoveByValue`, `KeyFromValue`, `KeysFromValue`, `MemberValuesFromKey`, `GetKeys`, `Flip`
- order/random: `SortDesc`, `SortByKey`, `SortByMember`, `Random`, `Shuffle`, `Reverse`
- shape/serialization: `IsSequential`, `ToString`, `Sanitise`, `DeSanitise`, `LowerKeyNames`, `CollapseKeyValue`, `ClearKeys`
- traversal: globals `SortedPairs`, `SortedPairsByValue`, `SortedPairsByMemberValue`, `RandomPairs`
- navigation: `GetFirstKey`, `GetFirstValue`, `GetLastKey`, `GetLastValue`, `FindNext`, `FindPrev`, `GetWinningKey`
- `ForEach`
- 32-bit build 向け `table.move` polyfill

### 4.2 型依存

通常の table に加え、次の GMod 型を識別・表現する。

- `Vector`: `x/y/z`, constructor `Vector`
- `Angle`: `pitch/yaw/roll` と `p/y/r` constructor 引数
- `Color`: `r/g/b/a`, `IsColor`, constructor `Color`
- Bool: `isbool`

`table.Copy` は `debug.getmetatable` を使い、metatable を保った再帰 copy を作る。identity key と循環参照 lookup が正しくなければならない。

`Sanitise/DeSanitise` は Vector/Angle/Color/Bool を `__type` 付き table に落として復元する。これは dupe/save/keyvalue 系の互換性に直結するので、Swift 独自の JSON 変換へ置換しない。

### 4.3 native primitive

- Lua table identity と arbitrary key
- `debug.getmetatable`
- `istable`, `isnumber`, `isbool`, `isstring`, `isvector`, `isangle`, `IsColor`
- Vector/Angle/Color constructors と field access
- Lua 5.1 `next/pairs/ipairs/table.insert/remove/sort/concat/unpack`
- `math.random`, `math.huge`

### 4.4 実装判断

`table.lua` も**全量を Lua のまま流用**する。順序や edge case に本家由来の癖があるため、「より正しい」Swift utility に差し替えない。例えば `GetLastKey` の実装も含め、互換層では本家挙動を正本とする。

## 5. `extensions/math.lua` と `math/ease.lua`

### 5.1 追加 API

- 定数/alias: `math.tau`, `Dist`, `Max`, `Min`
- 基本 helper: `DistanceSqr`, `Distance`, `BinToInt`, `IntToBin`, `Clamp`, `Rand`
- interpolation: `EaseInOut`, `CHSpline`, `Approach`, `ApproachAngle`, `TimeFraction`, `Remap`, `SnapTo`, `CubicBezier`, `QuadraticBezier`
- spline: `calcBSplineN`, `BSplinePoint`
- number: `Round`, `Truncate`, `Sign`, `NormalizeAngle`, `AngleDifference`, `Factorial`, `IsNearlyEqual`
- `math.ease`: Sine/Quad/Cubic/Quart/Quint/Expo/Circ/Back/Elastic/Bounce の In/Out/InOut 30 functions

### 5.2 native/type 依存

大部分は pure numeric Lua だが、次が重要。

- `math.IntToBin` は `string.format("%o", int)` を使う。
- `math.BSplinePoint` は `Vector()`、`Vector:Add`、number × Vector を使う。
- `CHSpline`, `CubicBezier`, `QuadraticBezier` は引数型の arithmetic metamethod により number 以外にも作用する。
- `math/ease.lua` は `module("math.ease", package.seeall)` と GLua `&&/||` を使う。

### 5.3 実装判断

両ファイルは**本家 Lua のまま流用**する。Swift 側は標準 `math/string.format`、module environment、Vector/Angle 等の arithmetic metamethod を提供する。`math.Round` の負数を含む挙動などを Swift の標準 rounding に置き換えない。

## 6. `extensions/file.lua`

### 6.1 Lua layer

このファイルが定義するのは3つだけである。

- `file.Read(filename, path)`
- `file.Write(filename, contents)`
- `file.Append(filename, contents)`

すべて native `file.Open` と File object method の薄い wrapper である。

```text
Read   -> Open(filename, "rb", path) -> Size -> Read -> Close
Write  -> Open(filename, "wb", "DATA") -> Write -> Close
Append -> Open(filename, "ab", "DATA") -> Write -> Close
```

path の互換規則:

- `true` は `GAME`
- `nil` / `false` は `DATA`
- `Write` / `Append` は常に `DATA`
- 実コードでは `GAME`, `MOD`, addon/mounted-game 名も使われる

### 6.2 native primitive

最低限この extension のために必要:

- `file` global table
- `file.Open(path, mode, searchPath)`
- File userdata: `Read(byteCount)`, `Write(bytes)`, `Size()`, `Close()`
- modes: `rb`, `wb`, `ab`
- binary/NUL safe read/write

本家 core 全体の起動・Spawnmenu まで考えると、同じ native VFS layer に次も早期実装する。

- `file.Exists`
- `file.Find`（files と directories の複数 return、wildcard、sort mode）
- `file.Delete`
- directory operations と metadata operations
- `DATA`, `GAME`, `MOD`, addon/mounted-content 名を解決する mount/search-path registry

実インストールの core Lua 内では `file.Exists` と `file.Find` がそれぞれ12箇所あり、`player_auth.lua` は `file.Read("settings/users.txt", "MOD")` を extension load 中に実行する。

### 6.3 Garry's PAD VFS 方針

推奨 layer:

```text
Lua file API
    -> normalized virtual path + searchPath ID
        -> DATA writable overlay
        -> Garry's Mod base read-only mount
        -> gamemode/addon mounts in precedence order
        -> mounted Source-game content
```

安全要件:

- host absolute path、drive letter、mount root を越える `..` を拒否する。
- Lua には host filesystem path を返さない。
- DATA だけを書き込み可能にする。
- path matching/case behavior は Source/GMod 検索規則として固定し、Windows の偶然の case-insensitivity に依存しない。
- 同名ファイルの mount precedence を deterministic にする。

現状の `LuaVirtualFileSystem` は byte read/write/exists/remove/move の良い土台だが、GLua `file.Open`、directory listing、wildcard、mount/search-path ID、read-only overlay がまだ必要である。標準 Lua `io` の File userdata と GLua File object は API 名・policy が異なるため、単純 alias にしない。

### 6.4 実装判断

`Read/Write/Append` は本家 Lua のまま流用し、`file.Open` と VFS policy を Swift に実装する。

## 7. `extensions/net.lua`

### 7.1 Lua layer

このファイルは次を Lua で実装する。

- case-insensitive receiver registry: `net.Receivers`, `net.Receive`
- native incoming dispatch: `net.Incoming`
- Bool: alias `WriteBool = WriteBit`, `ReadBool`
- Entity/Player codec
- Color codec
- cyclic table rejection
- sequential/non-sequential table codec
- `TypeID` ベースの `WriteType` / `ReadType`

`WriteType/ReadType` が扱う型:

- nil, string, number, table, bool
- Entity, Vector, Angle, Matrix
- Color (`TYPE_COLOR = 255` はこの Lua が定義)

非 sequential table は key/value pair を連続送信し、nil type を terminator とする。sequential mode は32-bit lengthを先に書く。number は double である。

### 7.2 native primitive

Swift/native 側で必要な最小層:

- message lifecycle: `net.Start`, current write buffer, finalize/cancel
- delivery: `Send`, `Broadcast`, `SendToServer` と recipient validation
- incoming read cursor と bounds checking
- `WriteBit/ReadBit`
- `WriteUInt/ReadUInt`, `WriteInt/ReadInt`
- `WriteDouble/ReadDouble`
- `WriteString/ReadString`
- `WriteVector/ReadVector`, `WriteAngle/ReadAngle`, `WriteMatrix/ReadMatrix`
- `ReadHeader`
- `util.AddNetworkString`, `util.NetworkStringToID`, `util.NetworkIDToString`
- `MAX_EDICT_BITS`, `MAX_PLAYER_BITS`
- `TYPE_*` constant map と `TypeID`
- Entity registry: `Entity(index)`, `EntIndex`, `IsValid`, `IsPlayer`
- Color: `IsColor`, `Unpack`

型 ID と bit width は独自値を決めず、対象 GMod build の値を golden probe で固定する。特に on-wire compatibility を目指すなら byte/bit ordering、string terminator、整数 overflow/truncation もテスト vector 化する。

### 7.3 realm/message model

- SERVER と CLIENT は別々の `net.Receivers` を持つ。
- client -> server の receiver callback は `(len, client)`。
- server -> client は client 引数なしの形になる。
- `len` には native header の16 bitが含まれて到着し、Lua `net.Incoming` が16を引いて callback に渡す。
- receiver 名は登録時・dispatch 時とも lowercase 化される。
- 書き込み中 message buffer と読み込み中 message cursor は coroutine/re-entrancy を壊さない state 管理が必要。

iPad の1プロセス内で SERVER/CLIENT を同時に持つ場合も、関数を直接呼ばず、immutable packet を realm message bus に enqueue して次の安全な dispatch point で `net.Incoming` へ渡す方が本家の境界に近い。

### 7.4 実装判断

table/type/entity/color の高水準 codec と receiver registry は本家 `net.lua` をそのまま流用する。Swift には bitstream、primitive codec、NetworkString registry、realm transport だけを持たせる。

## 8. `extensions/entity.lua` と関連分割

### 8.1 関連ファイル

- `entity_iter.lua`: `ents.Iterator`, `player.Iterator`, `InvalidateInternalEntityCache`
- `entity.lua`: Entity/Vehicle metatable extension、DT/NetworkVar、editvariable
- `client/entity.lua`: `AccessorFunc` による RenderAngles/RenderOrigin

### 8.2 最重要 lookup semantics

`entity.lua` は Entity metatable の `__index` を次の順にする。

```text
1. Entity metatable 自身
2. meta.GetTable(self) が返す entity 固有 Lua table
3. key == "Owner" の legacy fallback -> GetOwner(self)
4. nil
```

この順序は addon 互換性の中心である。Entity userdata に method を全部 Swift dispatch で焼き込むだけでは不十分で、各 entity に永続した Lua table が必要になる。また `self.m_bPlayPickupSound = ...` のような userdata field assignment が同じ table に入り、後で `__index` から読めなければならない。

### 8.3 Lua layer の主要機能

- spawn flags helper
- per-entity `GetVar/SetVar`
- SERVER creator ownership
- constraint status と NWBool mirror
- `CallOnRemove/RemoveCallOnRemove` と `EntityRemoved` hook
- physics wake
- Color wrapper
- child bone enumeration
- legacy DTVar と modern `NetworkVar`, `NetworkVarElement`, notify proxy
- editable network variables、map input、dupe save/restore
- NW2 proxy registry と `EntityNetworkedVarChanged` hook
- Vehicle の class/third-person/camera distance DT slot wrappers

`InstallDataTable` は entity ごとに closure と table を構築し、`self.dt` の `__index/__newindex` まで Lua で定義する。この層は Swift に書き直さず、本家 Lua を動かすべきである。

### 8.4 native metatable/type substrate

必須:

- `FindMetaTable("Entity")`, `FindMetaTable("Player")`, `FindMetaTable("Vehicle")`
- stable native metatable registry
- Entity userdata identity と `EntIndex`
- `NULL` invalid-entity sentinel
- `Entity(index)`, `IsValid`, `isentity`
- per-entity Lua table と userdata `__newindex` routing
- `GetTable`, `GetOwner`, `SetKeyValue`, `GetSpawnFlags`
- entity create/remove lifecycle と `OnEntityCreated`, `EntityRemoved`
- `ents.GetAll`, `player.GetAll`、engine からの `InvalidateInternalEntityCache`
- `AccessorFunc`
- `ProtectedCall`, `tobool`, `bit.band/bor/bnot`

Entity method primitives referenced directly:

- physics: `GetPhysicsObject`; PhysicsObject `Wake`
- color: `GetColor4Part`, `SetColor4Part`
- bones: `GetBoneCount`, `GetBoneParent`
- NW: `GetNWBool`, `SetNWBool`, `GetNWString`, `SetNWString` および NW2 change event
- DT: dynamic `GetDT<Type>` / `SetDT<Type>`
- network edit: native `net` primitives

NetworkVar substrate は最低限 `Angle`, `Bool`, `Entity`, `Float`, `Int`, `String`, `Vector` の slot storage、server-to-client replication、initial snapshot、change notification を持つ。SERVER/CLIENT の同じ EntIndex は同じ logical entity を表しても、per-realm Lua table は共有しない。

### 8.5 load-time hard dependencies

- `FindMetaTable("Entity")` が nil だとファイル冒頭で静かに return する。boot が成功したように見えて Entity API が全欠落するため、runner は include 後に sentinel method の存在を assert する。
- `FindMetaTable("Vehicle")` は後半で無条件に method 定義されるため、Vehicle metatable が nil なら load error になる。
- `hook.Add` はロード中に呼ばれる。
- SERVER では `util.AddNetworkString("editvariable")` と `net.Receive` がロード中に呼ばれる。

### 8.6 実装判断

Entity registry、lifetime、native methods、NW/DT replication を Swift に実装する。その上の `entity_iter.lua`, `entity.lua`, `client/entity.lua` は本家 Lua を無改変で流用する。

## 9. `extensions/player.lua` と関連分割

### 9.1 関連ファイル

- `player.lua`: Player lookup、PData、hands、flag helpers、player lookup helpers
- `player_auth.lua`: usergroup/auth
- `client/player.lua`: temporary player option input/HUD hooks
- `entity_iter.lua`: `player.Iterator`

### 9.2 Player lookup semantics

Player metatable `__index` の順序:

```text
1. Player metatable
2. Entity metatable
3. Entity.GetTable(self) の player 固有 Lua table
4. nil
```

Player は Entity userdata の単なる別 class ではなく、この lookup precedence を満たす必要がある。`GetName` と `Name` は native `Nick` の alias として Lua 側で追加される。

### 9.3 Lua layer の主要機能

- `DebugInfo`
- CLIENT `ConCommand` rate queue（1 tick あたり128 bytes超で打ち切り）
- persistent player data: `GetPData`, `SetPData`, `RemovePData`
- default weapon switch
- flashlight state
- `gmod_hands` setup
- SERVER legacy `Freeze`, `GodEnable`, `GodDisable`
- shared `IsFrozen`, `HasGodMode`
- `player.GetByAccountID/UniqueID/SteamID/SteamID64`
- auth: `IsAdmin`, `IsSuperAdmin`, `IsUserGroup`, `GetUserGroup`; SERVER `SetUserGroup`
- SERVER users.txt load と `PlayerInitialSpawn` hook
- CLIENT player option bind/HUD hook

### 9.4 load-time hard dependencies

`player.lua` は include された時点で次を実行する。

```text
sql.TableExists("playerpdata")
sql.Query("CREATE TABLE IF NOT EXISTS playerpdata ...")
```

したがって native SQLite bridge は Player extension の後工程ではなく、boot prerequisite である。必要 API:

- `sql.TableExists`
- `sql.Query`
- `sql.QueryValue`
- global `SQLStr`
- realm/profile に紐づく永続 DB

SERVER の `player_auth.lua` は include 中に:

- `file.Read("settings/users.txt", "MOD")`
- `util.KeyValuesToTable`
- `hook.Add("PlayerInitialSpawn", ...)`

を実行する。

### 9.5 native Player/engine primitives

- Player/Entity metatable と per-player Lua table
- `Nick`, `SteamID`, `SteamID64`, `UniqueID`, `AccountID`
- `IsValid`, `IsPlayer`, `IsListenServerHost`, authentication state
- `LocalPlayer`
- `ConCommand`, `IsConCommandBlocked`
- `GetInfo`, `HasWeapon`, `SelectWeapon`
- `GetHands`, entity `Remove`, `ents.Create`, entity `Spawn`
- `AddFlags`, `RemoveFlags`, `IsFlagSet`; constants `FL_FROZEN`, `FL_GODMODE`
- `game.SinglePlayer`
- `CurTime`
- `Msg`, `Format`
- hook dispatch: `Tick`, `PlayerInitialSpawn`, `PlayerBindPress`, `HUDPaint`

CLIENT `client/entity.lua` が使う `AccessorFunc`、CLIENT `client/player.lua` が使う input/render hook は VGUI/Spawnmenu 前段でも必要になる。

### 9.6 実装判断

Player identity、native methods、flags、SQL、connection lifecycle を Swift に実装し、`player.lua`, `player_auth.lua`, `client/player.lua` は本家 Lua を流用する。

## 10. native primitive 実装優先順

extensions を実際に無改変ロードするための推奨順。これは上位 gamemode API の見た目ではなく、boot-time dependency から逆算している。

### P0: GLua base/type ABI

- realm ごとの global state: SERVER / CLIENT / MENU
- GLua syntax と Lua 5.1 standard behavior
- byte string、pattern、format、primitive metatable
- GMod predicates: `isstring/isnumber/isbool/istable/isfunction/isentity/isvector/isangle`
- `tobool`, `IsValid`, `TypeID`
- `TYPE_*`, `MAX_EDICT_BITS`, `MAX_PLAYER_BITS`, flag constants
- `FindMetaTable`, `AccessorFunc`, `ProtectedCall`, `Format`, `Msg`, `MsgN`
- `bit` library

### P1: value types と metatable registry

- Color
- Vector + arithmetic + fields + `Add`
- Angle + arithmetic + fields/aliases
- Matrix
- Entity/Player/Vehicle/PhysicsObject/File userdata kind
- stable equality/hash/identity と type-specific printable/type names

### P2: VFS と SQL

- mount-aware VFS: DATA/GAME/MOD/addon/content
- GLua `file.Open`, File methods, `Exists`, `Find`, `Delete`
- 本家 `file.lua` をロード
- SQLite-backed `sql.*`, `SQLStr`
- KeyValues parser primitive

ここまでで `string/table/math/file` と Player extension の load-time DB 初期化を通せる。

### P3: entity world substrate

- EntIndex registry、NULL、create/remove
- per-realm per-entity Lua table
- Player -> Entity lookup precedence
- native Entity/Player method 最小集合
- `ents.GetAll/player.GetAll` と iterator cache invalidation
- hook lifecycle bridge
- DT/NW/NW2 storage と replication

### P4: net transport

- NetworkString registry
- bitstream/read cursor/write buffer
- primitive codecs
- server/client packet queue と recipient routing
- 本家 `net.lua` codec/receiver layer の実行

P3/P4 は開発上並行可能だが、`net.WriteEntity` と editable Entity まで通す integration test で合流させる。

### P5: extensions 無改変 boot gate

- 本家ファイルを load order どおりに実行
- SERVER/CLIENT/MENU ごとに export snapshot を比較
- silent early-return を sentinel assert で検出
- Base -> autorun -> Sandbox へ進む前の固定回帰 suite にする

## 11. GModCore 現状との接続点

2026-08-19 の作業 tree を文字列検索した範囲では、次は既に良い土台になっている。

- pure Swift Lua runtime
- byte-oriented `LuaString`
- GLua operator/`continue` parser
- Lua 5.1 standard libraries、`module/package.seeall`
- generic `LuaUserdata` + metatable
- primitive string metatable
- `LuaVirtualFileSystem` と writable memory filesystem

一方、今回の本家 extensions が要求する次の symbol はまだ実装箇所を確認できなかった。

- `FindMetaTable`, `AccessorFunc`, GMod type registry/`TypeID`
- Vector/Angle/Color/Matrix の GLua value model
- Entity/Player/Vehicle world model
- GLua `file.Open` と mount/search-path layer
- GLua `net` transport
- `ents`, `player`, SQL/auth substrate

したがって次の実装 milestone は、Lua helper をSwiftで増やすことではなく、**GLua primitive ABI + VFS/SQL + object registry**をひとまとまりで入れるのがよい。

## 12. 回帰テスト設計

### 12.1 source fidelity gate

- 実インストールまたは固定 upstream snapshot の対象 Lua を無改変で取得する。
- SERVER/CLIENT/MENU の各 realm で本家順に include する。
- include 完了だけで PASS にしない。代表 export を assert する。
- source hash/buildid を test report に残し、GMod update による drift を検出する。

### 12.2 string/table/math

- NUL/0x80-0xFF を含む `JavascriptSafe`, `PatternSafe`, `Explode`
- numeric string indexing と method lookup の両立
- cyclic/shared-reference table copy
- Vector/Angle/Color sanitise round-trip
- SortedPairs/RandomPairs iterator protocol
- all `math.ease` functions の boundary `0`, `0.5`, `1`
- Vector spline と polymorphic Bezier

### 12.3 file/VFS

- DATA write -> append -> read の byte equality
- `nil/false -> DATA`, `true -> GAME`
- MOD `settings/users.txt`
- mount precedence と wildcard `Find`
- non UTF-8/NUL file
- traversal/absolute path denial
- write forbidden read-only mount

### 12.4 net

- receiver name case folding
- bool/int/uint/double/string byte vectors
- invalid Entity -> index 0
- Entity/Player/Vector/Angle/Matrix/Color round-trip
- nested table、sequential table、cycle rejection
- server -> client と client -> server の callback signature/len
- truncated/oversized packet の deterministic error

### 12.5 entity/player

- Entity meta -> entity table -> Owner fallback precedence
- Player meta -> Entity meta -> player table precedence
- userdata assignment が per-object table へ残る
- EntityRemoved `CallOnRemove`
- iterator cache invalidation
- DT slot allocate/read/write、NetworkVar notify、server-client mirror
- editable variable net round-trip と permission check
- PData persistence across LuaState restart
- users.txt auth と PlayerInitialSpawn
- client ConCommand 128-byte/tick queue
- SERVER-only/CLIENT-only API leakage がないこと

## 13. 次工程への明確な引き継ぎ

実装側は、まず次の縦切りを完成させると本家 source を早く実行できる。

```text
GLua type ABI
  + Color/Vector/Angle
  + mount-aware file.Open/File userdata
  + SQLite sql.*
  + Entity/Player/Vehicle metatable registry
  + minimal hook/net primitives
        -> 本家 string/table/math/file/net/entity/player を無改変 include
        -> realm 別 extension smoke suite
        -> Base Gamemode 起動へ接続
```

本家 Lua は互換仕様そのものであり、高水準処理をSwiftへ転記しない。Swift側は「エンジンが本来供給する primitive、型、state、I/O、realm 境界」に限定する。
