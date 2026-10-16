# Stock MENU and foreground VGUI recovery

## Implemented

- Replaced the custom Problems DFrame/text dump with the bundled
  `lua/menu/problems/problems_pnl.lua` and its original DPropertySheet,
  GenericProblem, LuaProblem and PermissionViewer controls. Original resources
  are loaded unchanged. Lua errors have a separate bounded typed snapshot.
- PermissionViewer reads immutable snapshots from the real native permission
  store. Revoke actions return through the MENU action queue to that store;
  updates then refresh the original viewer on the MENU lane.
- MENU frame capture waits for queued mutations. Visible utilities have a
  coalesced 30 Hz animation capture pump, stopped with the view, rather than
  requiring another touch to complete a Derma tab cross-fade.
- MENU viewport changes resize the original Problems root and its inner frame
  before capture/hit testing. A window created at 1280x720 could otherwise keep
  its right-hand permission-revoke button beyond a later 1024px viewport.
  Opening utilities also synchronizes screen metrics before original Init runs.
- Problem and console text are bounded by both per-line and combined MENU
  budgets. Large logs no longer reject the shared Settings/Problems/Console
  synchronization before the requested window can open.
- Foreground publication accepts small but resolved, nontransparent content.
  A per-command one-percent viewport threshold is not a Source visibility rule.
  Unresolved or fully transparent captures still cannot replace visible Q/C.
- Runtime presentation contains individual Think/AnimationThink/Paint/PaintOver
  errors, reports the first 64 unique callback failures, and continues unrelated
  panels. Direct registry calls remain strict; layout errors still propagate.
  Contained MENU failures are forwarded to the App diagnostics store rather
  than discarded by its MENU logger.
- Added opt-in hexadecimal string escapes to the Lua lexer/state and enabled
  them for GMod realms. The stock UTF-8 charpattern now has the intended bytes,
  fixing markup wrapping. Plain LuaState retains Lua 5.1 unknown-escape behavior.
- Installed official KEY_ESCAPE/ENTER/SPACE values. Added exact centered 0/180
  degree textured-rectangle rendering for stock Problems group arrows.

## Explicit remaining boundaries

- Non-axis-aligned `surface.DrawTexturedRectRotated` angles still raise a clear
  unsupported error; they are not approximated or reported as implemented.
- The original lua_strict checkbox is disabled with an explanatory tooltip;
  strict-mode behavior is not implemented by pretending to accept its command.
- The Settings window still uses host-owned settings controls, not the complete
  Source GameUI options dialog. This update repairs its shared presentation path.
- Physical iPad / Swift Playgrounds display and touch behavior are unverified.

## Validation

- Windows Swift: 64 related tests passed, including original Problems tab
  touches, separate Lua errors, actual permission snapshots, returning to
  Settings, permission-revoke button clicks after a viewport change,
  Q/C switching at 2752x2064 after a Hint, callback containment and
  unchanged plain LuaState escape behavior.
- Local syntax parsing passed for the three edited App Swift files. This is
  not Apple typechecking or a physical-device result.
- Dedicated Apple CI now includes the new MENU, Retina Q/C resolution,
  text-budget and hexadecimal-escape regressions. Run `38895311875`, production
  source `86ce1b2`, passed its dedicated gate at 2026-10-16 11:58:55 UTC, after
  strict ARM64 package/app builds, Metal smoke, Simulator launch and accessibility
  smoke. Full XCTest and physical-device checks are separate, not reported PASS.
- A strengthened Windows Retina Q/C test also passed with no contained VGUI
  failures, rather than accepting a scene that only survives callback errors.

Contract references: [KEY enum](https://wiki.facepunch.com/gmod/Enums/KEY),
[centered rotated rectangle](https://wiki.facepunch.com/gmod/surface.DrawTexturedRectRotated).

## Follow-up: device Problems crash, Q/C cost and slider text overlap

- MENU startup, callbacks and teardown now use a stable dedicated 16 MiB-stack
  actor worker, matching the recursive interpreter's existing gameplay lane.
  Startup no longer runs original Derma Lua on MainActor. Fallback cleanup also
  closes Lua on its owner worker. Without the device crash report, stack
  exhaustion remains a suspected cause, not a confirmed crash diagnosis.
- Dependent layout selection for full Q/C frames uses a bounded heap index
  instead of allocating/filtering the entire pending set for every callback.
  Smallest panel-ID ordering, reinvalidation and scoped rendering are retained;
  Think, animations and input are not disabled to hide the rendering cost.
- FILL docking now uses the remaining area after edge siblings. Stock
  DNumSlider creates its slider before its label; the old one-pass docking put
  the slider under Damage/Delay text. Paint Z order is unchanged, and edge
  sibling order remains unchanged. See the creation-order example in
  [Panel:Dock](https://wiki.facepunch.com/gmod/Panel:Dock).
- Regressions cover the real App MENU actor path, stable worker startup/render/
  teardown, worklist equivalence to Set minimum, and stock DNumSlider geometry
  following Q/C/Hint transitions. Physical iPad frame time and crash recovery
  remain separate from portable tests and Apple CI.
