# Garry's Mod Lua / Gamemode Boot Sequence

Verified against the installed x86-64 Garry's Mod build on 2026-08-19.
Nested `include()` calls are included in this order.

## Server

1. Base Gamemode
   - `shared.lua`
   - `obj_player_extend.lua`
   - `gravitygun.lua`
   - `player_shd.lua`
   - `animations.lua`
   - `player_class/player_default.lua`
   - `taunt_camera.lua`
   - `player.lua`
   - `npc.lua`
   - `variable_edit.lua`
2. autorun / addons
3. Sandbox
   - `shared.lua`
   - `player_extension.lua`
   - `persistence.lua`
   - `save_load.lua`
   - `player_class/player_sandbox.lua`
   - `drive/drive_sandbox.lua`
   - `editor_player.lua`
   - `commands.lua`
   - `prop_tools.lua`
   - `player.lua`
   - `spawnmenu/init.lua`
4. `PostGamemodeLoaded`
5. `Initialize`
6. `InitPostEntity`

## Client

Before the gamemode sequence, the engine invokes
`lua/includes/vgui_base.lua`. This is a separate native loading stage rather
than an `include()` from `lua/includes/init.lua`; it registers the original Lua
Derma controls such as `DPanel` before gamemode lifecycle code creates them.

1. Base Gamemode and its shared/client includes
2. autorun / addons
3. Sandbox and `cl_spawnmenu.lua`
4. Spawnmenu / VGUI / content system
   - Tool Menu
   - Control Panel
   - Context Menu
   - Creation Menu
   - Content Browser
   - NPC / Weapon / Entity / Vehicle / Save / Dupe / Addon Props content types
5. `PostGamemodeLoaded`
6. `Initialize`
7. player connection
8. `InitPostEntity`

## Compatibility decision

Garry's PAD will run the original Sandbox Lua on top of a compatible VGUI
layer. Spawnmenu will not be replaced with an unrelated Swift implementation;
this preserves the load graph and maximizes Workshop addon compatibility.

The current modeled startup executes loose shared/realm autorun files and the
listed hook dispatches. Addon discovery, CLIENT player connection, and live
engine entity readiness remain explicit unmodeled boundaries.
