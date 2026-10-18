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
