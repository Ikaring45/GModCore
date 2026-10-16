# Garry's PAD / GModCore 0.1.62

## VGUI recovery

- Replaces the custom Problems text window with the bundled original Problems,
  Lua Errors and Permissions tabs. Permission revocation reaches the real host
  store through the MENU action queue.
- Fixes hexadecimal string escapes in GMod realms, restoring the byte pattern
  used by original UTF-8 markup wrapping. Plain LuaState keeps Lua 5.1 behavior.
- Prevents an individual Hint/HUD Think or Paint error from blanking unrelated
  Q/C panels. Callback failures remain visible through bounded diagnostics.
- Allows small resolved foreground content rather than requiring a single
  command to cover one percent of the viewport.
- Synchronizes MENU windows with the actual viewport before drawing and touch
  dispatch, keeping right-hand buttons on screen after a size change.
- Advances visible MENU animations without requiring another touch. Combined
  log budgets no longer make Settings/Problems/Console initialization fail.

## Validation and limitations

- 64 focused Windows tests passed, including original Problems tab touches,
  permission revocation after viewport resizing, returning to Settings, and
  Q/C switching after a Hint at 2752x2064.
- [Dedicated Apple validation](https://github.com/Ikaring45/GModCore/actions/runs/38895311875)
  passed for production source `86ce1b2`: strict ARM64 libraries, installable
  iPad app, Metal pipelines, Simulator launch, accessibility smoke and the
  dedicated Japanese VGUI/IME/Retina Q/C/Problems/noclip gate. The dedicated
  gate completed at 2026-10-16 11:58:55 UTC. Subsequent changes are release
  metadata and a stronger Windows-tested diagnostic assertion, not runtime code.
- Full Apple XCTest success and physical iPad / Swift Playgrounds presentation
  are not claimed. Settings is still the host-settings window, not the complete
  Source GameUI options dialog. The unsupported lua_strict control is disabled;
  rotated Surface rectangles currently support exact 0/180-degree cases only.

Select package version **0.1.62** in Swift Playgrounds.
See `VGUI_RECOVERY_2026-10-16.md` for implementation and validation boundaries.
