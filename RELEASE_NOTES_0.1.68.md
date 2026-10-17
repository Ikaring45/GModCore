# Garry's PAD / GModCore 0.1.68

Swift Package update for Swift Playgrounds. Refresh the dependency and select 0.1.68.

- Fix notification OverlayPanel lifetime across Lua garbage collection and resolve stock DImage-generated Unlit materials from actual texture pixels.
- Index VGUI children and overlay traversal, maintain topology incrementally, and reduce deferred deletion and subtree traversal work. Preserve existing removal callback ordering.
- Route direct GameUI Options commands and log unhandled menu commands instead of silently dropping them.
- Preserve touch-dragged resource windows across idle frames. Resource CheckButtons retain captions and live selection; TextEntry resources apply initial text and editable state and expose live edited text.
- Extend asset-backed Studio/ViewModel sequence resolution, SERVER animation cycle replication, inline RLE position/rotation evaluation and detached Metal animation preparation. Add named bone-following and bounded bone-merge preparation.

## Validation and limitations

Focused Windows tests: 76 passed, 1 skipped, 0 failures. These cover MENU close/reopen, VGUI registry/notification behavior and resource controls. Apple CI is still in progress; physical iPad opening, rendering and performance are not verified for this release. The installed loading-resource test is skipped without a user-supplied asset.

Original Source Options is **not complete**: the currently connected settings utility remains limited host-backed Derma controls. Full Source engine/VPhysics parity, all weapons/tools, separate hands GPU rendering, prediction parity and the complete original game are not delivered by this version. This is an experimental package release, not a signed app or a claim of feature completion.

See VGUI_RUNTIME_STABILITY_20261017.md for detailed implementation and validation boundaries.
