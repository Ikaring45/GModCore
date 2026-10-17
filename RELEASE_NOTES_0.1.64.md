# Garry's PAD / GModCore 0.1.64

## Changes

- Problems and other MENU utilities layer over Home; original OnRemove callbacks
  cascade to their owners so closing the window restores Home input.
- Pause keeps the world behind a dimmed Home menu; Home backgrounds rotate.
- Disconnect also cancels startup and rejects stale session work.
- Native Source `.res` parsing and real Derma instantiation for supported
  controls; LoadingDialogGMod.res progress and Cancel connect to startup state.
- Resource text insets, wrapping, paint flags and frame behavior are applied.
- Q/C first-frame failures close the invisible input owner through original
  Lua; unchanged complete snapshots avoid repeated text/texture scene builds.
- CoreText coordinate normalization is applied once to address inverted glyphs
  and multiline ordering; dedicated Apple pixel-regression coverage expanded.
- Playground content-pack generation includes original resource files and
  background images. Regenerate an older content pack for these assets.

## Validation and remaining limitations

- Windows resource and stock Q/C interaction tests passed. Portable CI passed
  at runtime source 4749796. The newest CoreText change is Apple-only.
- Apple validation for runtime source 4d67f64 was still running at publication:
  https://github.com/Ikaring45/GModCore/actions/runs/38992382621
- Complete full-suite success and physical iPad Q/C/crash/performance recovery
  are not established. This release does not claim the reported blank Q/C is
  fully fixed on device. CoreText pixel correction awaits Apple test results.
- Settings remains incomplete; unsupported native C++ controls (including
  CCvarSlider), resource directives/conditionals and scheme fields are not
  replaced by successful dummy controls. Unapplied fields remain diagnostic.
- The earlier full Apple suite had failures; passing targeted tests is not a
  claim that all package tests pass.

Select package version **0.1.64** in Swift Playgrounds. This is a formal release,
not a prerelease. It is distributed through the existing Swift Package flow;
no signed iPad application binary is attached.
