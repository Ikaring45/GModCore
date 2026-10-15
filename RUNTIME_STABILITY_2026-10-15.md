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
