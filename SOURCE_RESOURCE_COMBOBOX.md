# Read-only resource ComboBox and owned popups

The owned `garrysmod/resource/OptionsSubVideo.res` contains read-only ComboBox
controls (Resolution, AspectRatio, DisplayModeCombo and Renderer). The resource
adapter can now construct that explicitly `editable "0"` mode using the shipped
DComboBox, DMenu and DMenuOption Lua. MENU bootstrap loads those real controls.
No copies of the user-owned resource were added to this repository.

The host populates available choices with `addChoice`, selects one with
`selectChoice(at:control:)`, and reads `selectedChoiceIndex`/`text(control:)`.
Indices are stock Derma one-based indices, not native ComboBox item IDs. Choices
retain insertion order instead of DComboBox's default alphabetical menu sort.
The adapter does not invent available device modes, bind convars, persist an
Apply action or silently implement editable text input. Native ComboBox factory
defaults to editable; both omitted editable and editable=1 remain explicit
errors rather than being misrepresented as a read-only widget.

Format/behavior reference: Valve SDK
[`ComboBox_Factory` and `ComboBox::ApplySettings`](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/vgui2/vgui_controls/ComboBox.cpp).
Original DComboBox/OpenMenu and DMenu/Open callbacks remain responsible for
selection and menu lifecycle, rather than synthetic host click callbacks.

The pointer regression exposed an owned-popup clipping defect. Popup panels
now have screen-space drawing and hit-test roots, while retaining logical
parent ownership for GetParent, modal ancestry, visibility and removal. Popups
are painted exactly once after ordinary roots; raising/lowering a popup updates
the popup tier. LocalToScreen/ScreenToLocal stop accumulating at popup roots.
This screen-space model is inferred from the stock DMenu/OpenMenu flow and
validated with its dropdown, not claimed as complete native ISurface parity.
The documented input/focus aspect of
[`MakePopup`](https://wiki.facepunch.com/gmod/Panel:MakePopup) remains unchanged.

Windows regressions open the dropdown by pointer, locate actual rendered text,
click its first insertion-ordered choice, and read back the changed selection.
They also check invalid selection, rejection before editable-mode construction,
owned popup clipping, input outside the owner, retained parent and deletion,
and existing popup stack moves. Apple/device acceptance is outstanding.

Validation on 2026-10-18: registry/resource suites executed 78 tests with no
failures (one opt-in test skipped). Eight focused menu/resource regressions
also passed. The stock Sandbox immediate Q/C, strict spawn-menu interaction
and live context screen-ray regressions then passed: three tests, no failures.
These are Windows CPU/runtime checks, not physical-iPad interaction evidence.

Apple revalidation completed successfully for commit `8afaf5a` in
[run 39129421893](https://github.com/Ikaring45/GModCore/actions/runs/39129421893):
the strict libraries, generic iPadOS app, Metal pipelines, Simulator launch,
accessibility, Japanese/IME/Q/noclip checks and package XCTest steps passed.
This covers the ComboBox/owned-popup commit, not later text-input, CCvarSlider
or Scheme-color changes. Physical-iPad acceptance remains outstanding.

Full OptionsSubVideo loading is still incomplete: URLButton, native editable
ComboBox, other reported unapplied fields, real device mode enumeration and
applying settings remain required. CCvarSlider's binding/pointer subset is
now documented in SOURCE_RESOURCE_CVARSLIDER.md, with its remaining gates.
This is not a claim that the original Options dialog is complete.
