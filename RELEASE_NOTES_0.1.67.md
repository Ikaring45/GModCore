# Garry's PAD / GModCore 0.1.67

- Fixes same-frame VGUI layout re-entry reproduced by stock RopeMaterial.
- Connects CLIENT gui.ScreenToVector to live viewport, view angles and FOV.
- Adds BOX constants, popup modal ownership/IsModal, and base-texture GetString.
- Keeps native-captured canonical NULL alive across Lua garbage collection.
- Logs server startup configuration, loading stages, SERVER/CLIENT startup
  outcomes and direct Lua file paths, connection, disconnect and shutdown to
  the existing Swift Playgrounds console output.

## Validation and remaining limitations

Windows portable build and 60 VGUI/Rope regression tests passed. Separate
screen-ray, captured-NULL, material metadata and lifecycle logging tests passed.
Apple CI and physical iPad behavior are not confirmed for this release.

CreateMaterial and arbitrary VMT string parameters remain unsupported. Complete
Hint userdata recovery, original Options, home audio replay, skybox visibility,
footsteps and stuckRecovery remain open. Logs describe actual implemented work,
not complete original-engine console parity. See VGUI_RUNTIME_STABILITY_20261017.md.

This is a formal Swift Package release, not a signed app. Select **0.1.67** in
Swift Playgrounds and refresh the package dependency.
