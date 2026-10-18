# Owned-pack Q/C CPU profile

Optional test: `testConfiguredRealPackProfilesRepeatedQCFrames`, configured by
`GMOD_CONTENT_PACK_DIAGNOSTIC_PATH`. It mounts the owned STORED ZIP, starts
flatgrass/Sandbox, uses a 1024x768 logical viewport, opens/closes Q and C twice,
and renders ten frames per opening. The corpus is not redistributed.

Windows Debug CPU results (milliseconds, not iPad or GPU measurements):

| Sample | Q first frame | Q second-open warm mean | C first-open warm mean |
| --- | ---: | ---: | ---: |
| Before pending-layout collection change | 1015 | 86.8 | 24.2 |
| After change | 1156 | 100.7 | 27.8 |

These single runs do **not** establish a timing improvement. Startup was
11.5-11.9 seconds. The 233 live panels emit 285 Q commands or 24 C commands.
Second-open frames perform 100 layouts over ten frames for either menu.
This remaining repeated work and Lua/paint cost need further profiling.
The separate diagnostic C frame identified all ten layout callbacks as `DTab`.
The original DTab `PerformLayout` reapplies scheme settings and content sizing;
do not suppress it without examining the owning scroller/property-sheet contract.
A follow-up run measured Q second-open warm mean 92.0ms and C 39.9ms; this
reinforces that the collection change is not an established latency fix.

The collection change preserves start-of-pass ascending dispatch and invalidation
semantics, but avoids a full descriptor dictionary and sorting clean panels.
The 64 registry regressions plus owned Q/C test pass. It must not be represented
as solving the reported two-second interaction delay.

Source behavior is retained: Valve SDK Label.cpp at
`c8f4c6351162fbff83bfa5a428d45d1e6eed3824` invalidates the char-string SetText
path even for repeated input. No blanket suppression of those callbacks was
introduced to obtain an artificial benchmark win. The optional census wraps
layout callbacks only after timed frames, and therefore does not affect the
reported timing samples.

## Source Label inset correction

The perpetual DTab layout was caused by an extra host invalidation:
`DTab:PerformLayout` calls `ApplySchemeSettings`, which calls `SetTextInset`.
The host invalidated Label layout there; the original
[Valve Label::SetTextInset](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/vgui2/vgui_controls/Label.cpp)
only updates the insets and TextImage draw width. Removing the extra Label
invalidation preserves live content measurement and breaks that host-created
self-requeue loop. Explicit InvalidateLayout and actual size changes still work.
TextEntry behavior is not changed by this Label-specific correction.

Same owned pack, Windows Debug, after correction:

- Second-open ten-frame layout count: Q 0, C 0 (previously 100 each).
- Q second-open warm mean: 72.9ms (preceding run 92.0ms).
- C second-open warm mean: 5.2ms (preceding run 39.9ms).
- First-ever Q frame remains approximately 1.1 seconds; this is not solved.
- Commands remain Q 285 / C 24, panels remain 233.

The 65 registry tests and owned-pack profile passed (66 total). A dedicated
regression verifies SetTextInset inside PerformLayout settles, retains the
insets, and still responds to explicit invalidation. Timings are coarse
system-uptime samples and single-run observations, not an iPad latency claim.
The wider follow-up run also passed: 80 tests executed, one opt-in resource
test skipped, no failures. It includes resource-backed controls and all six
stock spawn/context-menu interaction cases. The owned-pack second-open layout
count is now asserted zero rather than merely printed; a repeat observed Q
74.7ms and C 5.2ms, with unchanged draw-command counts.

## Opt-in stage timing

`renderClientVGUIFrame(onFrameProfile:)` now exposes monotonic nanosecond CPU
stage timings through the normal session/runtime/registry path. No clock reads
are performed without the observer; the observer is invoked once after the
successful command snapshot, outside the measured stages. It must not reenter
or mutate the runtime. This does not measure Metal submission or presentation.

Owned-pack Windows Debug sample after the Label correction:

| Stage, ms | First Q frame | Reopened Q warm mean | Reopened C warm mean |
| --- | ---: | ---: | ---: |
| Layout/docking | 998.7 | 0.85 | 0.70 |
| AnimationThink/Think | 29.1 | 12.90 | 1.07 |
| Render tree | 0.63 | 0.61 | 0.49 |
| Paint/PaintOver and command snapshot | 58.9 | 58.86 | 3.33 |

The next primary targets are cold Lua layout and steady-state Lua painting,
not render-tree construction. Profiling is opt-in, and a regression compares
observed/unobserved draw commands. The owned-pack profile asserts one timing
record per frame and retains the zero-layout reopened-menu regression.

## Live raw-hit panel lookup

Panel field lookup and lifecycle callback dispatch now check raw instance
storage first, exactly as `LuaState.getTableValue` does. A raw nil with no
metatable returns nil immediately; all other misses still execute the original
semantic helper. This removes an artificial Lua helper frame for raw hits
without caching a method or changing actual scripted callback execution.
Init, PerformLayout and OnRemove use the same lookup boundary.

Regressions cover false shadows, field replacement, nil removal, dynamic
function-valued `__index`, GC in the fallback and live Paint replacement.
A Lua debug call-hook verifies raw hits make zero index-helper calls, a
metamethod miss does call it, and a later raw replacement does not call it.
67 registry tests plus the owned-pack Q/C profile pass (68 total).

Two Windows Debug samples of reopened Q warm stages were Think 9.76/13.41ms,
Paint 54.74/63.75ms, against the preceding 12.90/58.86ms sample. These noisy
runs do not establish a stable percentage latency improvement. Initial layout
remains roughly a second. Panel and draw counts and the zero repeated-layout
assertion remain unchanged. Physical-device and Release profiling are open.
