# Garry's PAD / GModCore 0.1.54

## Status

`0.1.54` is a physical-iPad correction build intended for normal-version
publication so Swift Playgrounds can select it. Publication requires the
checked-in Apple workflow to pass on the exact commit. Physical-device
acceptance remains pending
until the downloadable build completes the Home -> Loading -> map -> movement
and look -> Jump -> Pause -> Q Menu -> Audio route.

## Changes

- Reuses one immutable BSP collision world instead of rebuilding every brush,
  side, and plane array for each movement hull trace.
- Uses the complete Source `AngleVectors` camera basis near vertical pitch,
  avoiding the prior arbitrary up-axis switch.
- Separates `sky_camera` geometry from the ordinary world, applies its real
  origin/scale and visibility data, renders the 2D and 3D sky passes before a
  depth clear, and then renders the main world.
- Retains and uploads authored VTF mip levels and applies Source texture flags
  for minification, addressing distant-texture shimmer without inventing a
  blur or replacement LOD.
- Defaults new installs to 60 FPS; 120 FPS remains an explicit persisted video
  setting.
- Resolves stock `#phrase` labels for VGUI measurement and drawing while
  preserving raw `GetText()` identity, and corrects CoreText bitmap baselines
  for Latin and Japanese glyphs.
- Stops renderer-facing VGUI capture when no Q/Context menu owns the foreground,
  preventing stale upper-left panel fragments and unnecessary full-tree work.
- Adds a touch-sized bottom-right DFrame resize target with stock Lua sizing,
  immediate layout, bounded capture, and guaranteed release on cancellation or
  callback failure.
- Keeps pointer callbacks ordered while coalescing expensive Surface scene
  rebuilds into a separate latest-only refresh lane, so drag input is not held
  behind glyph and texture materialization.
- Adds the CLIENT-realm Spawnmenu engine boundary, stock notification
  bootstrap, host-backed `GetHostName`, and logical DHTML registration APIs
  needed to eliminate the corresponding observed missing-API timer failures
  without replacing the original Derma code.

## Deliberate boundaries

- Home remains the original WKWebView menu in this version. Replacing the
  Swift Options, Problems, and Console windows with real MENU-realm Lua
  Derma/VGUI is the next isolated release slice.
- Weapon inventory/execution, Tool actions, prop/entity spawning, Studio-model
  rendering, and dynamic physics are not claimed by this release.
- DHTML object registration is logical runtime compatibility; an embedded
  JavaScript/DOM execution bridge is not claimed.
- Stock spawnlist reads are supported, but `SaveToTextFiles` remains
  unavailable because no atomic writable spawnlist store is connected.
- Ordinary-world PVS/frustum/distance culling and LOD are not complete;
  sustained iPad performance remains a physical-device gate.
- The external user-owned 4.8 GB content ZIP is not a release asset and is not
  bundled into the Playground package.
- Apple CI/Simulator evidence does not substitute for the physical-iPad visual,
  touch, audio-session, memory, and sustained-performance pass.
