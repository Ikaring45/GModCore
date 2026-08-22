# Garry's PAD / GModCore 0.1.56

0.1.56 advances the existing Source/GMod compatibility runtime; it is not a
claim of complete Garry's Mod or VPhysics compatibility.

## Rendering and world

- Adds Source-material water reflection/refraction targets, normal/DuDv
  distortion, Fresnel blending, authored fog, and reflected dynamic entities.
- Renders 3D skybox geometry from the map's real `sky_camera` origin/scale and
  BSP visibility, alongside the existing 2D sky and compiled sun lighting.
- Carries displacement terrain collision into the static physics scene and
  renders terrain detail/vertex-transition materials with retained Source UVs,
  mip selection, and anisotropic sampling.
- Coalesces touch-look camera updates per rendered frame and retains immutable
  world resources across camera-only changes to reduce avoidable scene work.

## Physics, entities, and gameplay

- Adds canonical No-Collide constraints and stock two-entity tool behavior,
  including solver filtering, lifecycle, snapshots, replay, undo, and cleanup.
- Adds the canonical Thruster tool path with real entity ownership, force and
  torque commands, wake/toggle state, effects, undo, and cleanup.
- Adds a canonical Physgun interaction slice for authoritative pickup/drop,
  held distance and rotation, shadow-motion targets, freeze/unfreeze hooks,
  stale-handle cleanup, and replicated CLIENT hold display state.
- Expands `PhysObj` over authoritative body state and binds independently
  attested surface-property names/indices; missing material evidence remains
  unavailable rather than being guessed.
- Supports registered world Weapon creation, contact/`+use` pickup, drop, and
  replicated inventory ownership. Stock `Spawn_Weapon` now stores creator as a
  canonical full EHANDLE and obtains `OBBMins`/`OBBMaxs` from attested PHY data
  or the exact model's authored Studio hull.
- Keeps the fixed-step solver, entity replication, console/net delivery, and
  cleanup ordering on the existing session FIFO.

## Lua, VGUI, and models

- Completes stock Hint notification creation and frame animation without the
  previous missing Panel/active-weapon errors.
- Runs Home, Options, Problems, and Console through the Lua/Derma/Surface MENU
  path, with touch input, text entry, responsive resizing, and less stale frame
  construction.
- Decodes Studio skeleton/animation data from owned assets and provides bounded
  frame loading plus CPU skinning inputs for animated renderable models.

## Explicit boundaries

- The current deterministic solver is not a general Source VPhysics backend.
  Full rigid-body parity, ragdolls, vehicles, and every constraint type remain
  incomplete.
- Automatic water buoyancy and submerged-body force integration are not
  implemented.
- Physgun behavior and the Toolgun stool catalog are incomplete; the implemented
  canonical slices must not be read as full tool compatibility.
- Arbitrary Workshop/addon mounting, multiplayer prediction, Steam services,
  and physical-device acceptance remain outside this release.

## Validation status

Dedicated regression tests are checked in for the individual 0.1.56 slices,
but release preparation did not rerun the complete Swift suite, the Apple
package/app/Metal build, Simulator launch, or physical-iPad interaction and
performance gates. Those unexecuted gates are not reported as passes.
