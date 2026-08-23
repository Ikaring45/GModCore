# Garry's PAD / GModCore 0.1.59

0.1.59 follows physical-iPad observation that pressing Q in 0.1.58 still did
not produce a visible stock Spawnmenu.

## Stock Q visibility

- Removes the resolver-free first-frame shortcut. The real stock Q snapshot is
  primarily Derma textures and text; its remaining solid-only commands were
  thin, nearly transparent list strips rather than a visible menu.
- Keeps the initial Q/C transition ahead of passive host refresh work until a
  resolver-backed Surface scene is ready.
- Requires the first foreground scene to contain resolved textures or glyphs
  and materially visible alpha-weighted viewport coverage before it is
  published to Metal.
- Prevents host refreshes from invalidating the initial publication token and
  avoids a 120 Hz rebuild loop after a hard asset-resolution failure.

## Renderer evidence

- Adds immutable Surface visibility metrics that include command tint, bitmap
  alpha, and viewport coverage.
- Adds a stock-Q Apple contract proving that the resolver-free frame is not a
  visible menu while the resolved Gwen scene contains a materially visible
  `GModDefault.png` command.

## Validation boundary

- Focused Windows session testing covers the original stock Q lifecycle and
  Surface snapshot route.
- Apple package/App compilation and a dedicated stock-Q resolver/visibility
  contract are run by the release CI. Physical Swift Playgrounds presentation
  remains the final device check and is not represented as already re-tested
  here.
