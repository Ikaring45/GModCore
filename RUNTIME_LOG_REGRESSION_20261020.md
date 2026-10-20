# Runtime log follow-up after 0.1.69

## Fixed in the working branch, not the published 0.1.69 tag

- `Entity:GetAngles()` was missing from the canonical Entity Lua bridge. Stock
  `Spawn_Vehicle` calls the inherited Player method and edits the returned
  Angle before attempting vehicle creation. The getter now returns a fresh
  Angle containing canonical entity rotation; editing it does not mutate the
  entity. This removes the reported missing-method failure, not the separate
  vehicle implementation boundary.
- `Player:IsListenServerHost()` was missing on CLIENT, causing the original
  menubar's host-only Think check to fail. The bridge now uses live host session
  facts: true for single-player and false for dedicated sessions, as specified
  by [Facepunch](https://wiki.facepunch.com/gmod/Player:IsListenServerHost).
  A multiplayer listen session without an authenticated host-player identity
  remains an explicit unavailable error; LocalPlayer is not guessed to be host.
  A missing host session also remains explicit rather than returning a fake
  boolean.

The [GetAngles contract](https://wiki.facepunch.com/gmod/Entity:GetAngles)
describes entity orientation. This change does not add a separate body-versus-eye
orientation model for players or claim vehicle simulation works.

## Still open in the supplied log

- MENU `UpdateMapList`, `UpdateLanguages`, `LoadNewsList`, `SaveLastMap`,
  `hook.Run('StartGame')` and listed `RunConsoleCommand` calls are not connected
  to the full engine MENU runtime. The WebView handoff still reports them as
  unhandled. Actual map startup occurs through a separate host action; seeing
  a loaded map does not prove these commands worked or their settings persisted.
- `weapon_357` is an engine-native weapon, not a registered scripted weapon in
  the current lookup route. Its viewmodel resolver still needs native weapon
  data; inventing a SWEP table would hide this boundary.
- `physgun_drawbeams`, `effects_freeze`, `effects_unfreeze`, `gm_snapgrid`,
  `gm_snapangles`, `physgun_rotation_sensitivity` and `physgun_wheelspeed` are
  not accepted by the engine command route in this log. Registering no-effect
  values would not implement their renderer/controller behavior.
- Movement's `stuckRecovery` refusal remains a real unsupported movement path,
  not a successful recovery.
- `settings/users.txt` loading failed, but subsequent startup stages completed
  in this capture. The message is not evidence that the server failed to start.
  `Lua session ready` also explicitly does not assert renderer readiness.

Original bundled game files, manifests and the published release tag are not
modified by these API repairs. Windows tests, Apple CI and physical iPad
acceptance must remain separate.

## Windows validation, 2026-10-20

Swift 6.4.1, x86_64 Windows:

```sh
swift test --jobs 2 --filter 'SourceCanonicalEntityGLuaBridgeTests|SourceCanonicalSinglePlayerGLuaBridgeTests'
```

10 XCTest tests passed, zero failures. This includes live changes between
single-player/dedicated/listen session facts, explicit unavailable states, fresh
Player/Prop Angle values and actual SERVER/CLIENT session queries. Three live
Q-menu render frames produced no captured Think failure or host-query error.
This is not proof of complete vehicle spawning, all menu settings, Apple build
or physical iPad rendering.
