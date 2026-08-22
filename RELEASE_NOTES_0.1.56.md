# Garry's PAD / GModCore 0.1.56

## Gameplay and Lua error fixes

- Adds canonical replicated Weapon entities and Player inventory state for
  `Give`, `HasWeapon`, `GetWeapon`, `GetWeapons`, `SelectWeapon`, and
  `GetActiveWeapon`.
- Runs the original Sandbox `gm_giveswep` route through SERVER and selects the
  resulting Toolgun instead of stopping at a missing Player API.
- Implements engine-owned Player names and Weapon hold types used by stock
  Sandbox Lua.
- Completes the original Hint path from the 5/7-second timers through
  `GAMEMODE:AddNotify`, `NoticePanel`, and Surface text rendering. The observed
  `GetDockPadding` and `GetActiveWeapon` errors are covered directly.
- Routes SERVER `Player:ConCommand` to the exact connected CLIENT in the shared
  FIFO, removing the prior target-client delivery error.

## VGUI and menus

- Presents Home, Options, Problems, and Console through one real Lua/Derma
  MENU realm and the same Surface-to-Metal renderer used by gameplay VGUI.
- Supports touch pointer input, text entry, and touch resizing for sizable
  VGUI windows.
- Coalesces MENU frame construction so repeated VGUI updates do not queue
  stale Metal scenes.
- Reports only active Problems; the old unconditional permissions roadmap
  warning is no longer presented as a runtime fault.
- Connects MENU `permissions.Grant`, `Revoke`, `IsGranted`, `GetAll`, and
  `Connect` to the native persistent store. Local Connect resumes the real
  single-player host; unsupported remote multiplayer targets still fail
  explicitly.

## Source world and entity work

- Carries canonical `prop_physics` state through model validation, Studio body
  groups, collision bounds, physics-object ABI, ordered replication, dynamic
  model scene projection, Metal rendering, deferred removal, and removal hooks.
- Reuses bounded BSP trace workspaces for walking and query hot paths while
  preserving trace ordering and collision semantics.
- Keeps uncertain VPhysics inputs fail-closed. No placeholder mass, shape, or
  rigid body is reported as a successful Source physics object.

## Validation boundary

- The release is submitted to the checked-in Apple package/app/Simulator test
  workflow as one final gate. Physical-iPad visual and interaction acceptance
  remains a device gate.
