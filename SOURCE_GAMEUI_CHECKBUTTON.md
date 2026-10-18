# Authored Source CheckButton images and colors

The original Options dialog remains an acceptance requirement, not a new name
for the six-button host utility. This slice addresses native resource
CheckButton presentation; it does not finish page ownership, bindings,
Apply/Cancel, or all seven original Options tabs.

## Native reference and supported path

Valve SDK revision `c8f4c6351162fbff83bfa5a428d45d1e6eed3824`:

- [CheckButton.cpp](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/vgui2/vgui_controls/CheckButton.cpp)
- [CheckButton.h](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/public/vgui_controls/CheckButton.h)

With an explicit GameUI Scheme, a resource CheckButton now uses the shipped
DButton input/capture path, one authored input region, and independent native
check-image painting. Without a Scheme, existing DCheckBoxLabel calls retain
their legacy behavior. Global Derma/GWEN Q/C controls are not replaced or recolored.

The authored caption font and Marlett/MarlettSmall check-image font are resolved
at layout. Missing/unsupported fonts are explicit errors, not generic square or
Unicode-check substitutes. Native check-image drawing layers `g`, `e`, `f` at
image y+1, and selected `b` at y+2, with the six-pixel image/text gap. The palette
comes from the actual CheckButton background, Border1/Border2, check, selected,
highlight, disabled glyph/background and caption Scheme roles. Selection is
live, `selected` is honored, disabled input stays disabled, and no ConVar or
command is invented for a plain CheckButton.

## Actual font, not Latin letters

The existing project-authorized bundled `marlett.ttf` is already listed in
GModFonts.manifest.json: 6136 bytes, SHA-256
`3b6192eca4451835f4d634b0b6b0841da321ec65c1f3f1aa22d186da45787b9c`.
No additional system font or owned game asset is copied by this change.

Its Microsoft symbol cmap (platform 3, encoding 0, format 4) covers F030..F039
and F061..F079. The explicit Marlett adapter maps those byte characters to
their private-use code points for CoreText. It accepts already mapped points
and line breaks, rejects other characters, and does not pretend this rule
implements Wingdings or arbitrary symbol fonts. Rasterization still verifies
the actual resolved font. Bitmap and text-measurement caches distinguish
symbol and ordinary text. Symbol images do not shrink to accommodate the
unrelated Japanese fallback probe used for normal multilingual text.

## Validation boundary

Portable tests cover the exact cmap mapping, command-level glyph layers,
caption/image font descriptors, authored normal/selected/hover/disabled colors,
single-region clicking and disabled input. The real owned-pack Scheme regression
also remains in the focused selection. Apple tests additionally require the
bundled face to resolve, each native check-image symbol to have a nonzero glyph,
nonempty raster pixels, and measurement/bitmap dimensions to agree.

These tests do not establish native pixel-identical alignment, proportional
scaling, wrapped labels, keyboard mnemonics/focus decoration or disabled-caption
embossing. The current layout is an independent unscaled implementation over
Derma input, not a claim that the original C++ CheckButton is executing.
Other native factories, including CCvarToggleCheckButton, are not silently
aliased to this plain checkbox. Their actual binding lifecycle remains separate.
Physical-iPad appearance and the full Options screen remain unverified.

Windows validation on 2026-10-18: the focused mapping/Scheme/font/KeyValues/
registry/resource/MENU/Surface/thread selection executed 123 tests, 122 passed,
one separate installed-file opt-in test skipped, no failures. A final selection
of the mapping/Scheme suite plus three stock Q/C/context-ray regressions passed
all nine tests. That run included the unmodified Voice-page CheckButton block
and actual Scheme read from the user's Stored ZIP; it was not a skipped test.
Apple-only files passed Swift syntax parsing on Windows. The new CoreText
raster assertions still require the next Apple CI run; syntax parsing and CPU
commands are not Apple or physical-device rendering proof.
