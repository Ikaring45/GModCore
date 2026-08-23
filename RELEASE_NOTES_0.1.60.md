# Garry's PAD / GModCore 0.1.60

0.1.60 follows physical-iPad observation that pressing Q in 0.1.59 hid the
game controls but still left no visible stock Spawnmenu, and that entering BSP
terrain in noclip could stop the active session.

## Persistent stock Q presentation

- Applies the renderer-visible foreground gate to every Q/C Surface
  replacement, including passive host captures after the initial transition.
- Retains the last complete resolved Gwen scene when a transient capture only
  contains transparent or sparse solid strips.
- Keeps ordinary overlay publication independent from the foreground-menu
  coverage gate.
- Adds a stock Sandbox session contract that keeps Derma textures and text
  present across repeated passive host frames.

## Embedded noclip recovery

- Allows noclip's ground categorization trace to report `StartSolid` or
  `AllSolid` without terminating the playable session.
- Preserves trace-free noclip movement so the player can leave the terrain on
  the following tick.
- Keeps the existing fatal embedded-world contract for normal walking.

## Validation boundary

- Focused Windows tests cover repeated stock-Q host frames plus the real
  CLIENT command/FIFO route into embedded noclip recovery.
- Apple release CI builds the ARM64 package and installable app, launches the
  real app target in Simulator, compiles the Metal pipelines, and runs the
  dedicated Q persistence/noclip contracts.
- Physical Swift Playgrounds presentation remains the final device check and
  is not represented as already re-tested here.
