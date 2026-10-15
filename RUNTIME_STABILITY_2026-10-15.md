# Runtime stability update, 2026-10-15

Based on release 0.1.60 (`99f7d3c`).

## Embedded player recovery

Disabling noclip inside terrain previously made the next WALK hull trace throw
before the session could deliver another CLIENT console command. The app then
stopped the session, preventing noclip or a server teleport from recovering it.

The session now reports embedded movement as the existing `stuckRecovery`
capability rejection and preserves the pre-command movement state. SERVER and
CLIENT ticks and the original console/net FIFO continue in their existing order.
Sandbox still decides whether `PlayerNoClip` is allowed. A denied request leaves
the player in place; an approved request allows movement on the following tick.
The solver still rejects embedded WALK hulls. No unstick position is invented.
Non-finite input, invalid traces, and configuration errors still propagate.

The regression follows queued CLIENT noclip through SERVER approval, CLIENT
replication, embedded movement, disabling noclip inside solid, denial, and a
later approved recovery. Dedicated Apple CI also checks non-finite input and
stock Q persistence. Portable runtime checks now run separately so these
regressions do not require waiting for the complete iPad build.

Physical iPad/Swift Playgrounds validation is a separate outstanding check.

## Verification and next work

- `git diff --check` passed for this update.
- Installed the official Windows Swift 6.4.1 toolkit using WinGet and verified
  its SDK with the existing Visual Studio 2022 x64 build environment.
- Local `swift test --jobs 4` passed all 43 selected tests: noclip integration
  (including embedded WALK/FIFO recovery and Sandbox denial), stock Q passive
  frame persistence, non-finite movement rejection, and all SourceWorldWalk
  tests. The test run took approximately 125 seconds after an 83-second build.
- GitHub rejected the branch push with HTTP 403,
  `You must verify your email address`. Neither new CI workflow has executed
  for this branch; local tests do not establish Apple/device presentation.
- The historical 0.1.60 Apple run `32617758441` completed its focused gates,
  but its full XCTest run failed: 818 tests, 13 skipped, 15 assertion/error
  failures (2 unexpected). This is a pre-existing baseline, not a result for
  the new update.
- That baseline includes missing Studio appearance metadata in stock prop and
  player-hands routes, body-group resolver tests, a missing sky bitmap, stale
  mesh allocation/terrain expectations, floating-point equality in viewmodel
  conversion, and player respawn/combat expectations. These require separate
  fixes with their asset and runtime contracts preserved.
