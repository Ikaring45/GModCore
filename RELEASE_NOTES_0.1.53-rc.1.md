# Garry's PAD / GModCore 0.1.53-rc.1

## iPad UI, live Spawnmenu, content integrity, and Source rendering preview

This is a prerelease for device acceptance, not a claim of complete Garry's
Mod compatibility. It replaces the earlier debug-oriented playable view with
a stock-GMod-shaped Home, Loading, Pause, and in-world control flow while
continuing to execute the owned original menu, Sandbox, Derma, and Spawnmenu
Lua wherever the compatibility runtime supports them.

### Home, Loading, Pause, and iPad input

- Home runs from the selected content pack in WKWebView with pinch and
  double-tap zoom disabled, a fixed viewport, and persisted English/Japanese
  language selection shared with native Loading, controls, Problems, and
  Options.
- Loading progress comes from completed BSP, geometry, collision, realm Lua,
  Sandbox, material, texture, Metal upload, and first-presented-frame work. It
  does not advance on a timer. A typed CPU or renderer failure stays visible
  and offers a safe return to Home instead of exposing a black or bootstrap
  frame.
- Pause releases movement, look, jump, action buttons, and VGUI capture while
  retaining the live map, origin, view angles, and simulation state for
  Resume Game.
- Normal play hides Render Preview, raw map buttons, Console, counters, and
  diagnostic borders. They remain available only after Developer diagnostics
  is explicitly enabled.
- iPad controls include movement, look, jump, Q, C, Pause, FIRE, ALT, and USE,
  with centralized ownership, cancellation handling, persisted sensitivity,
  inverted-Y support, and a 60/120 FPS preference.

### VGUI and Spawnmenu

- Label and Panel sizing now uses the existing text measurer for
  SizeToContents, axis-specific sizing, GetContentSize/GetTextSize, wrapping,
  alignment, invalidation, and convergent layout.
- Native Panel lifecycle, docking, size/parent callbacks, deferred removal,
  clipping, focus, capture, coordinates, TextEntry caret state, scissor and
  texture-filter state, and common stock drawing helpers are modeled without
  fixed-size test shims.
- A strict interaction test opens the real g_SpawnMenu, changes the Weapons
  tab and Half-Life 2 category, activates a genuine ContentIcon, opens the
  Button tool, selects a real SpawnIcon, resizes to a compact viewport, and
  scrolls the real Balloon control panel through its DVScrollBar.
- Missing VGUI calls are aggregated as structured Problems with class, method,
  source, and line rather than being reported as successful no-ops.

### Content ZIP and audio

- ZIP replacement is transactional: a candidate must validate before the
  current security-scoped source, mount, bookmark, and caches are replaced.
  Unmount never deletes the original Files/iCloud ZIP.
- Stored and legacy deflated root manifests are bounded and authenticated.
  Candidate validation checks exact authorization plus critical payload
  hashes; manual Revalidate streams CRC and SHA-256 across every manifest
  payload with real file/byte progress and cancellation.
- The Home and gameplay paths share a bounded WAV/MP3 player pool. Loose ZIP
  and mounted VPK lookup, repeated and concurrent playback, separate master,
  menu, and gameplay volumes, cache invalidation, and AVAudioSession foreground
  recovery are connected. Stock surface.PlaySound requests are drained once
  in order from CLIENT frames.

### Source world and Metal

- BSP texinfo/texdata UVs, generated cubemap-material fallback, worldspawn
  skyname, six-face painted sky, linear HDR lightmaps with independent UVs,
  and explicit linear-to-display encoding are carried into the Metal scene.
- Displacement faces use their parsed dispinfo/dispverts/disptris recursive
  mesh, unnormalized Source displacement vectors, dedicated texture/lightmap
  UVs, and averaged triangle normals.
- Construct water selects top or beneath ranges by camera side and uses its
  real VMT fog/reflection/refraction values with a premultiplied-alpha,
  depth-read/no-write pass and animated BGRA normal map. Unsupported UV88 dudv
  data remains diagnosed rather than silently treated as decoded.
- Per-command Surface texture filtering reaches bounded Metal sampler variants.
  Encoded BSP, world, displacement, index, and lightmap allocations are
  preflighted against typed device-tunable budgets.

## Validation for the candidate source tree

- 480/480 Windows tests pass with warnings treated as errors.
- 67/67 strict VGUI/Surface/stock-Q tests pass.
- 51/51 strict Session/BSP/Renderer/Loading tests pass.
- All 188 Swift source and test files parse.
- The real 4,876,093,827-byte content pack validates all 2,641 authorized
  payload SHA-256 values and passes Home background, both maps, painted sky,
  water, material, Sandbox startup, and movement gates.
- Bundled maps, 2,162 client-content files, 28 fonts, and the 117-key English
  and Japanese catalogs pass their manifest contracts.
- Embedded Metal source extraction finds all 12 required shader functions and
  11 pipeline contracts.

The exact prerelease commit must still pass the checked-in Apple/iPadOS
workflow before the tag is published. That workflow is the semantic ARM64
GModApp/GModMetal build, Metal compiler/pipeline smoke, Simulator install and
launch, accessibility smoke, and package XCTest gate.

## Honest boundaries

- Physical iPad and Swift Playgrounds acceptance is still required for the
  4.8 GB Files security scope, peak memory/jetsam behavior, touch ownership,
  inactive-to-active audio recovery, and the final sky/lightmap/displacement/
  water pixels. Windows and Simulator results are not reported as that proof.
- Static props and Studio-model rendering, displacement-aware collision,
  complete water/ladder/step movement, dynamic entity physics, multiplayer,
  Steam/authentication, Workshop/addon discovery, and a complete weapon/tool
  runtime are not implemented.
- Keyboard, Voice, several Game Options, the full Permissions bridge, noclip,
  meaningful entity undo, and full weapon selection/execution remain staged
  compatibility work. Unavailable controls are labelled as such.
- Source sound scripts, symbolic/rndwave/channel/pitch/loop semantics, spatial
  sound, sound.Play, EmitSound, and CreateSound are not covered by the current
  surface.PlaySound bridge.
- The external content ZIP is not a GitHub release asset. Generated source
  archives must be checked for hydrated Git LFS map objects before use.

GModCore is independent compatibility research and is not affiliated with or
endorsed by Facepunch Studios or Valve Corporation.
