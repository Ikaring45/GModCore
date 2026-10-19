# Native resource Frame chrome and retained lifetime

This is part of the original Source Options requirement, not a replacement
definition of that goal. The application's six-button settings utility is still
not the seven-tab Options dialog. Page factories, real engine setting consumers,
Apply/Cancel/Reset and full app presentation remain required.

## Primary behavior reference

Valve SDK revision `c8f4c6351162fbff83bfa5a428d45d1e6eed3824`:

- [Frame.cpp](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/vgui2/vgui_controls/Frame.cpp)
- [Button.cpp](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/vgui2/vgui_controls/Button.cpp)

Resource-only Frame presentation now uses authored Frame background/border,
normal/inactive title bar/text and normal/inactive title-button colors. The
global shipped DFrame/Derma skin is unchanged. Focus is the live hierarchical
focus from the host registry, including logical children/owned popups. Its
presentation updates immediately, without claiming native focus-fade animation.
Title/button foreground setters run on focus transitions instead of being
reapplied on every idle Think; the original drag/resize Think still executes.

Normal-caption unscaled geometry follows Frame.cpp: title bar from (5,5) to
(wide-5,28); title at Frame.TitleTextInsetX (native fallback 28), y=9 and width
wide-72; close button 18x18 at (wide-25,8). The title uses the resource title_font
override, otherwise FrameTitleBar.Font, otherwise Default. The close image uses
the real Marlett `r` symbol and the native button's (2,1) text inset. Its normal,
depressed and inactive borders are resolved separately. The owned Scheme's
explicit empty backgroundtype=0 title borders are supported as empty borders;
other background types remain unsupported rather than flattened to a guess.

The host has no native OS window minimize/maximize capability. Those buttons
are hidden according to the no-capability Source path, not exposed with
Derma's unrelated Close callbacks. Nonempty Scheme system-menu icons are
explicitly rejected until the native system-menu path is implemented. This
slice supports the actual owned Scheme's empty icon settings.

## Close is not destruction

Source Frame initializes m_bDeleteSelfOnClose=false and ignores .res visible in
ApplySettings. The resource adapter now follows those behaviors, independently
of whether a Scheme is supplied. The owning host controls visibility explicitly.
Closing a retained resource Frame hides it and preserves live child state;
reopening does not reconstruct controls from defaults. Explicit instance.remove
still destroys the owned resource panels. Public setVisible/isVisible/requestFocus
forward to the actual live Panel methods on the runtime's owning lane.

This is Frame lifetime, not an invented Options Cancel transaction. The owning
PropertyDialog/pages must still implement ResetData, apply, cancellation,
persistence and real engine effects. It does not route a subwindow close into a
game disconnect. Global DFrame DeleteOnClose remains unchanged for stock GLua.

The rapid close/reopen regression originally failed on the second and third
click: shipped DLabel recognized a double click and skipped its ordinary press
path. Native Button::OnMouseDoublePressed forwards to OnMousePressed instead.
Resource Buttons, CheckButtons and Frame close buttons therefore disable only
their instance-local Derma double-click interception. No artificial clock
advance is needed to make repeated native presses work, and global GLua/Q/C
double-click behavior is not changed.

## Verification scope and remaining work

Synthetic command tests use unique authored colors and title fonts to verify
normal/inactive background, title position, close symbol, close-button bounds,
title_font precedence, close visibility and three close/reopen cycles retaining
edited child text. The actual owned Scheme/loading/Voice-check regression stays
in the broader selection. Tests are not a pixel comparison or physical-iPad proof.

Native small/proportional captions, system menus, native resize/snap grips,
frame-specific pointer-focus preservation, focus fading, title ellipsis,
OnFinishedClose/action signals and full native client-area/layout semantics
remain open. The adapter still uses shipped Derma input/lifecycle primitives;
it does not claim that the original C++ engine or full Options dialog is running.
Unapplied resource fields and unsupported palettes for other controls remain
reported separately.

Apple CI 39131978040 (head 2848c37) passed arm64 libraries, generic iPad app,
Metal pipelines, Simulator install/launch, accessibility, Japanese/IME/Q/noclip
and package XCTest. That proves the earlier Scheme/loading path, not this Frame
work. CI 39234080881 is for head 504c090 (font/Marlett checkbox work); this Frame
implementation must receive its own later Apple validation and device check.

Windows validation on 2026-10-19: the focused Frame/resource/Scheme/font/
KeyValues/registry/MENU/Surface/thread selection executed 127 tests, 126 passed,
one separate installed-file opt-in test skipped, no failures. The real Stored
ZIP test included the owned Scheme's UiBold title selection, empty title borders,
Marlett close glyph, active title color, close and retained reopen. Three stock
Sandbox immediate-Q/C, strict spawn-menu interaction and context-ray regressions
also passed after the final changes. These are CPU command/interaction tests,
not the physical app's original Options screen acceptance.
