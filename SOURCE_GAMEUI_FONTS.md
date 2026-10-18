# Authored Scheme font descriptors and isolated registration

Resource controls with a supplied SourceVGUIScheme now resolve their authored
font alias during layout. Label/Button/TextEntry/ComboBox text uses the explicit
resource font or Default. A titled frame uses FrameTitleBar.Font for lblTitle;
the resource CCvarSlider uses DefaultVerySmall for captions. Primary native
control references are the fixed Valve SDK
[Label](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/vgui2/vgui_controls/Label.cpp) and
[Slider](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/vgui2/vgui_controls/Slider.cpp).

The resolver retains the selected platform's face, tall, weight and effects.
It chooses a single matching yres variant at the logical viewport height;
overlapping glyph sets/fallback faces, range-limited sets, unknown fields and
unsupported dimensions are explicit errors, not a guessed first face. The
supported Surface descriptor limits are 4..255 tall and 31 UTF-8 bytes/face.
Missing effect flags map to zero flags in this adapter; complete native Scheme
default/effect equivalence is not independently attested. GLua extended=true
is a host UTF-8 handoff choice, not a field invented in the authored Scheme.

Descriptors are registered under deterministic content-derived GameUI names.
Existing Surface Default and stock Derma font aliases are never overwritten.
An existing derived name is reused only when its complete supported descriptor
matches; a mismatch fails instead of replacing a live resource's font. Idle
layout returns before resolution, and resize reuses identical registrations.
Controls given a palette-only Scheme with no Fonts block are reported by
unappliedSchemeFontControls, rather than claimed as font-complete.

The user's actual Stored ZIP regression now checks captured loading text with
the authored Tahoma/16 descriptor and slider captions with Tahoma/12, in
addition to their authored colors and Cancel routing. Independent fixtures
check flags/yres, rejection of multiple glyph sets, registration reuse, unchanged
Default, coexisting Scheme sizes, resize and safe layout failure after removal.

## Typeface and rendering fidelity are still open

This is a descriptor/layout connection, not proof that the exact Windows face
was rendered on iPad. GModBundledFontRegistry currently resolves unavailable
Tahoma through the authorized bundled Roboto family for consistent measurement
and rasterization. That established fallback is unchanged here and is not
Tahoma parity. Exact permitted font assets, CJK fallback/shaping and physical
pixel comparison remain required. No Windows system font was copied, bundled
or redistributed by this change.

The current CoreText rasterizer supports antialias selection and the narrow
Marlett symbol path below, but explicitly rejects underline/strikeout/shadow/
outline/blur/scanline/additive effects and other symbol fonts.
Preserving these flags in descriptors does not implement their glyph rendering.
CustomFontFiles registration from the mounted Scheme, proportional scaling,
multiple native glyph ranges and full Options-page integration remain open.
The independent settings utility is still not the original Source Options UI.

The later CheckButton slice adds the authored caption font and
Marlett/MarlettSmall check-image descriptors. CoreText now supports the exact
bundled Marlett symbol cmap through an explicit byte-to-private-use adapter;
other symbol fonts/effects remain unsupported. See SOURCE_GAMEUI_CHECKBUTTON.md.

Windows validation on 2026-10-18: 121 tests executed, 120 passed, one separate
installed-resource opt-in test skipped, no failures. The actual Stored-ZIP
Scheme/loading/slider regression ran and passed. Three stock Sandbox Q/C and
context-ray regressions also passed after the final code changes. Apple
execution for this commit and physical-iPad font acceptance remain separate.
