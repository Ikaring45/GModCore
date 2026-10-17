# VGUI runtime follow-up (unreleased)

- Separate ordinary self-invalidation from the same-frame child-extent/docking
  worklist. Stock RopeMaterial previously exhausted the 64-pass guard at the
  1024 x 768 viewport; its four-frame regression now completes.
- Provide CLIENT gui.ScreenToVector from the live viewport, player view angles
  and world horizontal FOV, returning a normalized canonical Vector.
- Add BOX direction constants and native popup modal ownership/IsModal state.
- Root the canonical NULL captured by native entity methods across Lua GC.
- Expose IMaterial:GetString for the retained base-texture metadata only.
  Arbitrary VMT string parameters remain unsupported; CreateMaterial is still
  missing, so the complete stock DImage VertexLit/Cable conversion is not done.

Validation: Windows portable build; 59 VGUI registry tests and the stock Rope
regression pass after the layout fix. Separate screen-ray, captured-NULL and
base-texture tests passed during this work. These do not prove iPad latency,
Metal rendering, all Hint userdata failures, or complete modal input parity.
The reported users.txt startup message and stuckRecovery are not fixed here.
