# Garry's PAD / GModCore 0.1.65

## Fixes since 0.1.64

- Removes the remaining manual CoreText bitmap-row reversal in response to
  physical iPad photographs showing upside-down VGUI glyphs.
- Separates MENU presentation revisions: stale captured pixels, errors and
  close actions cannot overwrite a newly opened utility.
- Captures MENU frames and their deferred actions in one actor turn; publishes
  pixels before delivering actions that may synchronously close the window.
- Rejects queued touch/text/delete input belonging to a previous window and
  clears keyboard focus when switching utilities.
- Changes resource ProgressBar painting from the generic continuous green
  Derma skin to Source-style complete segments using 4px gaps, 8px segments,
  4px inset and the installed GMod white/black-alpha palette.

## Validation and limitations

- Local Windows compilation and focused MENU/resource tests completed:
  eight passed, one installed-asset test skipped. Includes five repeated
  Problems close -> Settings cycles and segmented progress geometry.
- A separate installed-resource attempt could not find the old Steam asset
  path; direct installed-resource validation is not claimed.
- Portable CI passed for f518f5a. Latest runtime source af0f9a8 is undergoing
  [Apple validation](https://github.com/Ikaring45/GModCore/actions/runs/38994462698)
  and [portable validation](https://github.com/Ikaring45/GModCore/actions/runs/38994462780).
- Apple pixel-test success, physical iPad text orientation, Q/C reopening and
  overall device stability are not yet confirmed for these changes.
- Settings still uses the existing limited host-settings Derma window, not
  the original tabbed Source Options dialog. Full native scheme overrides,
  proportional loading control sizing, borders and localization remain open.
  The segmented progress correction is not a claim of full loading UI parity.

Select **0.1.65** in Swift Playgrounds. This is a formal Swift Package release,
not a prerelease; no signed iPad app binary is attached.
