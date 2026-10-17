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
