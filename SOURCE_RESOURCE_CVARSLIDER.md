# Resource CCvarSlider binding and pointer behavior

The resource adapter now constructs CCvarSlider with a real installed ConVar.
MENU and the app factory accept an explicit host engine-ConVar catalog; the
adapter does not create a dummy fps_max or make unknown engine values real.
The user's owned OptionsSubVideo.res identifies fps_max, range 30..300 and
allowoutofrange=0. No owned resource payload is copied into the repository.

Behavior references are Valve SDK revision
`c8f4c6351162fbff83bfa5a428d45d1e6eed3824`:

- [CCvarSlider](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/common/GameUI/cvarslider.cpp)
- [Slider](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/vgui2/vgui_controls/Slider.cpp)

This independent resource-only adapter uses a shipped Derma container and a
painted, input-transparent thumb. It does not alter global DSlider behavior or
register a pretend native control in GLua. Its source-scale tick state supports:

- Bounds intersected with the actual ConVar's optional min/max; with
  use_convar_minmax=1, supplied ConVar bounds replace the resource bounds.
  Missing bounds remain absent, not GetMin/GetMax's public zero fallback.
- Hundredth-value integer ticks; clamped visual thumb, plus the separate
  unbounded current value for allowoutofrange=1.
- Reset, external ConVar changes, SetSliderValue, ApplyChanges and the native
  modified-once flag (which stays sticky across Reset and ApplyChanges).
- Track click jumping without starting a drag, thumb-only capture retaining
  its original press offset, and resource-created release applying changes.
- Unscaled 8px thumb, y=8/h=4 track, 11 tick marks and two-decimal captions.

Host APIs on the resource instance expose sliderValue, setSliderValue,
resetSlider, applySliderChanges and sliderHasBeenModified. Editing does not
write the ConVar until release or explicit apply. No ConVar persistence or
engine side effect is invented: the embedding host must consume its catalog
value (for example, applying a display cadence) and own persistence.

External changes synchronize at the visible frame's Think boundary instead of
native Paint, because the command renderer snapshots child geometry before
calling Paint. This lets the thumb and value update in the same captured frame.
The adapter checks local/ancestor visibility, but complete native clipped-paint
eligibility parity is not asserted. Keyboard adjustment handlers exist; routing
hardware keyboard events into them remains outside this resource slice.

Invalid/missing ConVars and nonfinite, degenerate, reversed or out-of-int32
tick ranges are explicitly rejected before any resource panel is constructed.
This is a stricter supported subset than native invalid-ConVar/reset handling
or inverted ranges, not an assertion that these unsupported cases match Source.
The resource-created pointer model is covered; native action-signal delivery
(ControlModified/SliderMoved), dynamic/proportional schemes, native border/font
palette, full float32 edge equivalence and code-created-slider lifecycle remain
open. The current colors use the installed Derma palette.

The full OptionsSubVideo dialog is still not complete: URLButton, other
unapplied resource fields, real device-mode enumeration and settings-page
ownership/apply integration remain. This does not establish that the FPS
slider is already wired into the shipped iPad settings screen or renderer.

Windows validation on 2026-10-18: the registry/resource/MENU/ConVar/thread
selection executed 97 tests, 96 passed and one installed-content opt-in test
skipped. Three stock Sandbox Q/C/context-ray regressions also passed. After
the final caption precision correction, the resource suite was rerun: 14
executed, 13 passed and the same opt-in test skipped. New pointer assertions
verify the native track-click formula (83.77), unchanged value on thumb press,
25-to-50 drag with retained press offset, deferred catalog writes and release
apply. Other checks prove bounds modes, missing-bound handling, out-of-range
values, same-frame thumb geometry, eleven ticks, original-bound caption
rounding, reset/sticky modification and no leaked panels after preflight errors.

The Apple-only app factory change passed syntax parsing on Windows, not Apple
typechecking. Apple CI for the earlier ComboBox/popup commit is separate; this
slider still needs Apple and physical-iPad acceptance. No VGUI speedup is
claimed by these functional changes.
