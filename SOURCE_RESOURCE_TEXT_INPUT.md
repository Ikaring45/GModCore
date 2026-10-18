# Resource TextEntry input restrictions

The owned OptionsSubVideo resource's FPSLimitLabel specifies maxchars=3,
NumericInputOnly=1 and unicode=0. These fields now configure the native
TextEntry input boundary instead of remaining unapplied resource metadata.
No owned resource payload is copied into this repository.

Behavior reference: Valve SDK at fixed revision
[`TextEntry::ApplySettings`, `InsertChar`, `SetText` and `SetMaximumCharCount`](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/vgui2/vgui_controls/TextEntry.cpp).
Numeric input permits decimal digits and period, not minus; it is not a
replacement for the separate Lua DTextEntry:SetNumeric/AllowInput callback.
Negative maximum counts are unlimited, zero blocks insertion, and changing
the limit does not truncate the existing stream. Programmatic SetText remains
independent of these insertion restrictions, as in the reference.

The host batches Swift text insertion, filters restricted input, and clips
accepted input at its existing decoded UTF-8 character boundaries. Caret
movement and OnTextChanged follow actual changes only. This continues the
existing host Unicode policy: it is not complete wchar_t/IME/selection parity.
Decimal classification uses Foundation decimalDigits; locale-specific native
iswdigit behavior and warning sound playback are not asserted as equivalent.
The existing native multiline wrapping and auto-progress behaviors are not
implemented by this limit.

Only explicitly supplied numericinputonly/unicode fields override the shipped
Derma initialization. Omitted-field native ApplySettings defaults remain a
separate adapter parity gap; DTextEntry normally enables non-ASCII input.

Windows validation on 2026-10-18: registry and resource suites executed 80
tests, 79 passed and one installed-content opt-in test skipped. New tests cover
mixed paste into the three-character FPS input, blocked further input,
deletion/reinsertion, zero/unlimited limits, preserving existing text when the
limit changes, and Japanese text boundaries/caret. Apple execution of these
changes and physical-iPad input acceptance remain outstanding.

CCvarSlider's later binding/pointer implementation and remaining gates are
documented in SOURCE_RESOURCE_CVARSLIDER.md. It is not mapped to a naked
DSlider with immediate SetConVarX; explicit host catalog ownership, bounds,
reset/external-change synchronization and drag-end ApplyChanges are required.
