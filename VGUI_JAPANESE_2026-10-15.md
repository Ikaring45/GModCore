# Japanese VGUI update

## Input

- MENU utilities and CLIENT Q/C menus share a UIKit `UITextView` keyboard
  bridge. Native Japanese IME marked text remains in UIKit until committed;
  candidate updates do not mutate the Lua TextEntry or fire OnTextChanged.
- Accepted text, Backspace, and Return use the focused original TextEntry and
  its callbacks. Focus changes discard unfinished composition.
- CLIENT edits are serialized on the existing game lane and validated against
  session generation, pointer/input epochs, and the exact focused panel ID.
  MENU edits also verify focused panel identity before applying queued input.

## Rendering and response

- CoreText measurement and rasterization share fallback-aware shaping. The
  requested Source font tall is maintained for multiline Japanese text.
- Font scaling is stable across the full string and its caret prefixes so
  mixed Latin/Japanese input does not move the caret to a different scale.
- Repeated Japanese text measurement is cached with a 256-entry/4 KiB-per-key
  bound, including actual font face, size, weight and italic state. Redefining
  a GLua font cannot reuse measurements for its previous definition.
- Existing stock DFrame touch drag/resize and Hint overlay lifecycles are
  retained and included in regression testing.

## Validation boundary

Windows tests cover original Lua behavior and session input ownership. Apple
CI separately exercises real UIKit marked text, CoreText bitmap visibility,
measurement agreement and mixed-script caret positions. Physical iPad touch,
IME candidate UI and Metal presentation still need device verification.

Linux has no native image decoder in this package. Its fast CI job now tests
portable movement/localization/Hint contracts; stock image-backed Sandbox
session tests run on Windows and in the dedicated iPad Simulator gate.
