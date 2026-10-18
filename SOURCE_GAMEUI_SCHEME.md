# Authored GameUI palette, distinct from Derma

The user's fidelity requirement includes the original Options tabs, layout,
controls, fonts, behavior and colors, plus other screens with color differences.
This change does not declare that requirement complete. In particular, the
current six-button Garry's PAD settings utility is still not the original
Source Options dialog. Native Options page ownership/binding remains required.
The reference tabs (Game, Keyboard, Mouse, Audio, Video, Voice and Legal),
their authored resource controls, captions/fonts and actual apply/cancel
semantics remain acceptance requirements, not a renamed host utility.

## Implemented data path

SourceVGUIScheme parses the mounted original resource/SourceScheme.res with
explicit reference-platform symbols. The loading host requests WIN32/WINDOWS
to match the user's desktop reference, rather than accidentally selecting
POSIX/Xbox values from the iPad host's own OS. No owned Scheme file is bundled
or copied into this repository. Colors retain authored RGBA bytes, including
zero/non-opaque alpha; aliases are case-insensitive and cycle-checked.

Ordered first-match lookup follows the native KeyValues FindKey model; Lua's
existing last-key-wins table conversion is not changed. Primary reference:
[Valve KeyValues.cpp, fixed revision](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/tier1/KeyValues.cpp).
The actual Scheme exposed another parser gap: a platform condition can occur
between a key and its font object, not only after a value. The common KV parser
now preserves that form. Multiple conditions on one entry, unsupported
condition expressions and unresolved include/base directives remain errors.

Native resource colors now apply, when an explicit Scheme is supplied, to:

- hidden-title Frame background/focus background and authored line border;
- Label normal/dull/bright foreground;
- Button normal/hover/depressed foreground, background and line border;
- segmented ProgressBar foreground/background;
- CCvarSlider thumb, track, caption and disabled tick colors.

The loading app path supplies the actual mounted Scheme. Without a Scheme,
legacy adapter calls retain their existing behavior. Controls still using the
Derma color path are reported by unappliedSchemeColorControls. The global
Default Derma/GWEN skin is untouched: stock Q/C/Problems are not native GameUI
controls and must not inherit the wrong palette.

## Validation and remaining fidelity gates

The opt-in real-pack regression reads the user's Stored ZIP, parses the actual
Scheme and LoadingDialogGMod.res, captures original loading button/label colors,
verifies Cancel reaches disconnect, then captures actual Scheme slider colors.
A synthetic palette regression checks normal/hover/down colors and real button
commands, so these checks do not merely pass against hardcoded GMod colors.
Parser tests check aliases, alpha, platform selection, duplicate order and errors.

Line borders retain side order, depth and start/end trims; they are not flattened
to an outline when the authored pressed border uses offset 0 1 / 1 0. The edge
trim rendering interpretation is independently implemented from the authored
data, not asserted as native pixel parity without image comparison. Custom or
rounded/image borders remain unsupported. Insets are preserved as data, not
claimed as full native layout support.

The later font-descriptor adapter now connects authored single-glyph-set aliases
to resource controls; see SOURCE_GAMEUI_FONTS.md for its strict subset and
typeface/rendering gates. CustomFontFiles are still not registered from Scheme
entries. Native title controls, proportional scaling, focus transitions,
keyboard focus/default/selected button decoration, disabled-label embossing,
editable ComboBox and remaining resource control types are still open. The
app's original Options pages and real settings application must be integrated;
changing the six-button utility's colors is not a substitute.

Tests prove CPU command values and interaction, not physical-iPad colors or
pixel-identical rendering. The existing Metal Surface path preserves normalized
UI byte colors on bgra8Unorm; this change does not add world sRGB transfer to UI.
Apple-only host source parsing is distinct from Apple build/Simulator and device
acceptance. The final focused Windows selection executed 99 tests: 98 passed,
one separate installed-loading-resource opt-in test skipped, no failures. The
real Stored-ZIP Scheme/loading/slider regression ran and passed; it was not the
skipped test. Changed Apple-only host files passed syntax parsing on Windows.
Three stock Sandbox immediate-Q/C, strict spawn-menu interaction and context-ray
regressions also passed after the final code changes. Physical rendering and
full native Options remain unverified.
