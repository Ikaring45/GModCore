# Garry's PAD / GModCore 0.1.55

## Visible fixes

- Restores the original Q-menu Surface immediately after the CLIENT menu
  transition instead of waiting for a later Metal frame callback.
- Preserves the sky color explicitly between the sky and ordinary-world Metal
  passes on iPad tile GPUs, while clearing world depth independently.
- Keeps the ordinary-world geometry dominant in both bundled maps; the
  `sky_camera` miniature remains a separate Source sky pass.

## Canonical Entity foundation

- Uses one Source EHANDLE identity and one `SourceEntityList` contract for
  world, Player, and future `prop_physics` state.
- Adds engine-owned transform, movement, model, solid, move type, lifecycle,
  revision, and deferred-removal snapshots.
- Routes SERVER-to-CLIENT Entity packets through the existing net/console FIFO
  with connection generations, ordered initial snapshots and deltas, and
  transactional CLIENT registry projection.
- Adds a bounded MDL/VVD/VTX asset validation boundary. An opaque PHY companion
  is checked only for its documented header/checksum/size contract; a physics
  shape is not fabricated.

## Deliberate boundaries

- This release does not yet claim `gm_spawn`, `ents.Create`, Studio-model Metal
  drawing, rigid-body physics, Physgun, Toolgun, or Undo. Those continue in the
  next vertical slice.
- The world fix is covered by bundled-map range checks and Apple CI; final
  visual acceptance remains the downloaded build on physical iPad.
- The external user-owned content ZIP is not bundled and was not revalidated
  for this source-only correction.
