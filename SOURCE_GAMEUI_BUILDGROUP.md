# Source resource context loading

This is a loader milestone for the original Options pages, **not** a claim that
the seven-tab Options dialog is connected to the app or complete.

## Source contract

The implementation was checked against Valve's published Source SDK revision
`c8f4c6351162fbff83bfa5a428d45d1e6eed3824`:

- [BuildGroup.cpp](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/vgui2/vgui_controls/BuildGroup.cpp#L1203):
  removal deletes resource-created controls, not the code-created context;
  `ApplySettings` skips scalar keys, matches existing panels by the resource
  **block key** case-insensitively, then calls the context factory if unmatched.
  A null factory result does not create a placeholder or abort the whole file.
- [Panel.cpp](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/vgui2/vgui_controls/Panel.cpp#L4152):
  the base panel background comes from `Panel.BgColor`. `ApplySettings` may rename
  the panel using `fieldName`, after BuildGroup's block-name lookup.
- [KeyValues.cpp](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/tier1/KeyValues.cpp#L984):
  `FindKey` traverses ordered peers and stops at the first matching key.

## Adapter behavior

`existingPanel(control:)` returns an opaque binding to a panel that actually
exists. `GMLuaMenuSession.loadResource` accepts that binding as the context and
optionally accepts other code-created controls. Bindings from another runtime or
removed panels are rejected before applying the file. No caller-supplied string
can turn an unknown class into a fabricated implementation.

The resource's custom `ControlName` may describe a C++ Options page that does not
have a factory. When its block matches a supplied live panel, the adapter applies
the supported base control fields to that panel. `reusedControls` records both
the declared custom class and the applied base class. This does **not** implement
the custom page's constructor, event handlers, action signals, or ConVar logic.

The default missing-factory policy remains strict. The explicit
`missingFactoryPolicy: .sourceContinue` mode records every omitted control in
`skippedControls`, and constructs no dummy. This lets an original Legal page load
despite its unavailable `BuildModeDialog` editor factory; skipped factories must
still be inspected before claiming page completeness. Invalid supported fields,
missing real ConVars, unresolved includes, and unresolved conditionals remain
errors, not silent skips.

New controls are parented to the context. Removing the resource deletes only its
new controls, not the supplied context or controls. A resource without a matching
context block uses the context's current dimensions for child coordinates.
Context-size changes invalidate this geometry cache without resetting it on
idle frames. A WorldPanel parent uses the requested viewport even before the
next runtime render updates its screen metrics.
Nested code-created child-parent geometry, duplicate blocks that reapply the same
panel, and fully native BuildGroup reload/action-signal behavior remain separate.

`SourceVGUIResource(source:activeSymbols:)` can explicitly select the bounded
reference-platform symbols also used by Scheme parsing. Omitting the symbols
preserves conditionals. Unknown/compound conditions fail rather than guessing
that the iPad host means Windows. Includes remain unresolved. Resource scalar
lookup now uses the native first case-insensitive match; GLua table conversion's
separate last-value contract is unchanged.

Resource `Panel` / `EditablePanel` backgrounds use the authored `Panel.BgColor`
when a Scheme is supplied. Foreground semantics, custom page painting, and
arbitrary Panel borders are not claimed. Stock Derma Q/C palettes are untouched.
Repeated Scheme application replaces its own Think wrapper rather than nesting
another per-frame callback. A subsequently replaced host Think becomes the new
base callback; it is not overwritten with a stale saved function.

## Verification scope

`SourceVGUIBuildGroupTests` exercises real shared panel identity, live renaming,
case-insensitive block-key lookup distinct from `fieldName`, commands, resource
removal, invalid bindings, cross-runtime rejection, and context-relative layout.

The opt-in owned-content test loads the **unmodified**
`garrysmod/resource/OptionsSubGModLegal.res` and `SourceScheme.res` from
`GMOD_CONTENT_PACK_DIAGNOSTIC_PATH`. It checks the authored page and five button
backgrounds, dispatches the five resource command strings, and confirms the
context survives removal. It does not guess legal URLs or claim that C++ command
handlers, localized strings, tab selection, or the complete Options lifecycle
are implemented. No user-owned payload is copied into the repository.
Another owned-content test parses all seven original Options page resources and
checks Windows versus OSX/POSIX enabled-field selection on the Mouse page. That
test is parser coverage, **not** a seven-page rendering or behavior PASS.

Windows package tests are not Apple compilation, an independent Source rendering
oracle, or physical-iPad appearance/interaction proof. The app's old simplified
settings entry point still needs replacement with the actual page controller,
seven tabs, real consumers/bindings, Apply/Cancel/reset, and device verification.

On 2026-10-19, the focused Windows run executed 138 tests: 137 passed, one
installed-file-only loading test was skipped, and none failed (70.611 seconds).
This included both owned-content tests above, the existing owned Scheme/loading
test, resource/Scheme/font/Frame/registry/menu/surface coverage, and all three
stock Q/C/context-ray interaction regressions. The owned ZIP was explicitly
supplied as `GMOD_CONTENT_PACK_DIAGNOSTIC_PATH`; it was not a skipped fixture.

Apple run [39234080881](https://github.com/Ikaring45/GModCore/actions/runs/39234080881)
completed successfully for **504c090**, covering the preceding font/Marlett
changes. It does not validate the subsequent Frame or this BuildGroup commit.
Those changes require their own Apple run, and physical iPad remains separate.
