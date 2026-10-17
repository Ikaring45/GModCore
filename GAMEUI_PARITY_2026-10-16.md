# GameUI parity follow-up (after 0.1.63)

## Implemented in this change

- MENU Metal surface can clear to transparent, leaving the actual Home/world
  behind Problems, Settings and Console instead of an opaque replacement page.
- Native deferred panel deletion dispatches OnRemove once, including cascading
  owner removals. Stock ProblemsFrame depends on this to remove ProblemsPanel.
  Actions emitted during frame processing are drained to the App, not only
  after pointer/text callbacks. Closing Problems can release the modal layer.
- Home outside gameplay rotates real content-pack backgrounds every 30 seconds
  with a one-second crossfade; missing photographic assets remain an explicit
  limitation, not generated replacements. In-game Home hides photographs and
  composites darkness over the retained world. Gameplay input/tick suspension
  remains owned by the existing pause boundary.
- Hidden Home explicitly relinquishes hit testing above Q/C/pause controls.
  This addresses a possible input interception path; it is not physical-device
  proof that the newly reported 0.1.63 Q/C regression is resolved.
- Disconnect is admitted during startup. Startup tasks check their generation
  before entering the engine lane, preventing a canceled start from reviving
  a session after close. Exact console `disconnect` reaches the host lifecycle;
  GameMenuCommand Disconnect/ResumeGame aliases are also recognized.
- SourceVGUIResource parses native KeyValues resource controls and retains raw
  fields, unknown control classes, includes and conditionals. Fixed, centered
  and right/bottom-anchored coordinates resolve explicitly. Unsupported layout
  expressions fail rather than silently becoming zero.
- Native resource instances now create real Derma panels, labels, buttons,
  checkboxes, text entries, images and progress controls. Resource commands use
  real button callbacks; unsupported fields are returned as diagnostics.
- Loading uses user-owned LoadingDialogGMod.res when present in the mounted
  pack, with actual startup progress and Cancel routed to session disconnect.
  The old host progress HTML is hidden only after the native surface exists.
  Titleless Frame resources use a panel body rather than an invented titlebar.
  The thin Playground pack builder now includes .res files and original menu
  background photos. Previously generated packs need regeneration for these.

## Remaining implementation work (NOT reported complete)

- Extend native control factories, #base/#include resolution,
  platform conditionals, schemes, proportional sizing, pinning, autoResize,
  localization, action targets, cvar bindings and specialized control behavior.
  A parsed .res is not a working GameUI dialog.
- Load the user's OptionsSub*.res through that adapter. Native scheme fidelity,
  segmented Source progress appearance and specialized CCvarSlider behavior are
  not yet complete; host settings are not the original native options dialog.
- Reproduce physical iPad 0.1.63 Q/C opening and Disconnect, and compare against
  the supplied original screenshots. Portable/Simulator tests are separate.

## Authority

- Shipped `lua/menu/background.lua`: 30-second lifetime, one-second outgoing
  alpha fade, no photographic background updates in-game or during loading.
- Shipped `lua/menu/problems/problems_pnl.lua`: modal root, child DFrame,
  removal cascade and Escape/outside-click dismissal.
- Installed `garrysmod/resource/LoadingDialogGMod.res`: 400x75 frame at r10/r10;
  InfoLabel, progress and real Cancel action. Read locally, not redistributed.
- Installed `resource/OptionsSubAudio.res`, Keyboard/Video/Voice/Multiplayer:
  native resource controls, not a replacement SwiftUI options screen.
- User reference image 10: frozen world/viewmodel behind dimmed Home; image 11:
  world/viewmodel visible through Q. Sky/world-underneath images are original
  renderer references, not automatically classified as runtime defects.

PANEL:OnRemove contract: https://wiki.facepunch.com/gmod/PANEL:OnRemove
The old GLua LoadControlsFromString API is deprecated/no-op in current GMod;
native GameUI resource support must not be implemented by pretending this API
alone restores the C++ GameUI dialogs: https://wiki.facepunch.com/gmod/Panel

## Validation follow-up

- Original installed LoadingDialogGMod.res was read without copying it into the
  repository: real status label, progress fraction and Cancel→disconnect passed
  portable execution. Two resource-factory tests also passed. This is not an
  iPad screenshot or complete resource/schema parity.
- Apple run 38908602847 passed the targeted UI/IME/Q/C/Problems/disconnect gate
  for source 8bfe144. Its complete suite failed (16 failures), including CoreText
  orientation, stock-menu scroll visibility and unrelated model/terrain cases.
  Full-suite success is explicitly NOT claimed; UI failures remain follow-up work.
# Native resource field continuation (2026-10-17)

## Physical-device regression follow-up

Storage recovery continuation: local compilation resumed with about 59 GB free.
The focused MENU/resource run executed nine tests: eight passed, one skipped
without an explicit installed asset. This includes five Problems close ->
Settings cycles and the segmented ProgressBar rectangle assertion. A separate
installed-resource attempt failed because the old Steam file path no longer
exists; it is not an installed-resource pass.

Queued pointer/text/delete tasks now carry the presentation revision as well
as the session generation, checked before and after actor delivery. Switching
utilities clears text focus. Added an App actor regression repeating atomic
close-action capture then Settings reopen three times; Apple execution pending.

The supplied 0.1.64 iPad photographs still show vertically inverted VGUI text.
The prior orientation change was not device-validated. Remove the remaining
manual raw-row reversal; the Apple pixel gate must decide correctness before
another orientation fix is described as verified.

MENU presentation changes now invalidate stale captured actions/pixels/errors,
and frame capture plus action drain is one actor turn. Pixels publish before
close actions, so synchronous observers cannot be overwritten by an old frame.
Repeated Problems close -> Settings open coverage has been added.

Loading used a real resource but the wrong continuous green Derma skin. Its
ProgressBar now uses independently implemented eastward segmented geometry
(gap 4, width 8, inset 4), and the installed GMod ClientScheme white/black-alpha
palette. Scheme overrides, proportional sizing, native borders and the full
original options dialog remain incomplete; this is not full GameUI parity.
Geometry contract: https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/vgui2/vgui_controls/ProgressBar.cpp

Local C: storage filled during test editing. The affected test was restored
from HEAD using apply_patch. Only the ignored, rebuildable 32 MB
GModLuaConformance.exe generated by our local tests was removed. No user asset
or source was deleted. New executable tests await Apple CI / available space;
previous test passes must not be attributed to these new changes.

## CoreText orientation continuation

The rasterizer used both an inverted drawing CTM and a bitmap-row reversal.
It now draws in native Quartz coordinates (baseline = height - lineTop - ascent)
and converts rows once at the immutable Metal boundary. The existing failing
asymmetric-L / multiline / Japanese glyph test is now in the dedicated Apple
gate, with a reverse-multiline assertion as well. Windows parsing is not a
CoreText pixel test; Apple results and physical iPad appearance remain pending.
Matrix composition reference:
https://developer.apple.com/documentation/coregraphics/cgcontextsettextmatrix

## Q/C continuation

- Failed first foreground publication now closes the invisible menu through
  the original Lua/FIFO lifecycle instead of retaining an input-stealing owner.
  The first-frame guard stays active during recovery, excluding rapid taps.
- Unchanged, fully resolved snapshots retain the published scene instead of
  repeating CoreText/texture builds. Think/Paint still run; changed commands,
  unresolved assets, dropped commands and ownership changes do not reuse it.
- Windows immediate Q/C capture before the next host tick and stock Q pointer,
  tool selection and compact scroll tests passed. The old one-notch scroll
  assertion was a test-distance assumption, not a demonstrated renderer bug:
  stock scroll=50 did not reach the lower selector. Three genuine notches do.
- This is not evidence that the reported physical iPad blank Q/C is fully
  fixed. Apple typechecking and real-device display/input remain separate.

The resource adapter now applies textinsetx/textinsety, Label wrap,
paintbackground/paintborder and titled Frame sizable/draggable through real
Derma methods. Invalid boolean/non-finite inset values fail explicitly;
unsupported fields remain in unappliedFields. A render-command regression
checks the actual six-pixel horizontal and three-pixel vertical text offset.
Windows focused resource tests: three passed, one installed-asset test skipped
when its explicit asset environment variable was not supplied. This does not
establish physical iPad behavior or complete OptionsSub resource compatibility.

