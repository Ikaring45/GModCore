# Garry's PAD / GModCore 0.1.66

- Sends Lua print/Msg and error logs to Swift Playgrounds stdout with
  `[GarrysPAD]` / realm prefixes. MENU ordinary logs are no longer filtered out
  of stdout. Gameplay logs emit on the worker before the MainActor hop;
  host-detected gameplay errors also print. No persistent crash log is added.
- Coalesces pointer-driven foreground captures behind the current resolved
  scene build instead of repeatedly invalidating it during interaction.
  This targets C/Q interaction latency; improvement is not device-measured.
- Corrects the asymmetric-L orientation regression test to compare occupied
  ink bounds rather than asymmetric blank font padding. Multiline and Japanese
  coverage remains; this change does not itself alter glyph rendering.

## Validation boundary

Changed Swift files passed syntax parsing. Latest runtime source 629b0aa is
still undergoing [Apple validation](https://github.com/Ikaring45/GModCore/actions/runs/38996310263)
and [portable validation](https://github.com/Ikaring45/GModCore/actions/runs/38996310257).
No full-suite or physical iPad success is claimed. The previous Apple run at
af0f9a8 failed the L-orientation assertion; a new pass is not yet established.

Home sound replay, 3D skybox visibility, footsteps, Source movement feel and
the original tabbed Options dialog remain open. Existing 0.1.65 limitations
remain. This is a formal Swift Package release, not a prerelease or signed app.

Select **0.1.66** in Swift Playgrounds to capture the new console logs.
