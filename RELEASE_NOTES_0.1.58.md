# Garry's PAD / GModCore 0.1.58

0.1.58 follows the formal 0.1.57 release after physical-iPad observation showed
that the stock Q menu could still fail to publish and that firing a stock Hint
could leave walking slow for the rest of the session.

## Q menu and Surface scheduling

- Keeps the first stock Q presentation ahead of passive refresh work so a slow
  texture-rich Surface frame cannot become a continuous same-lane capture loop.
- Publishes the structural menu frame before completing the texture-rich Metal
  scene, allowing the real stock VGUI window to become visible promptly.

## Hint and gameplay responsiveness

- Restricts overlay-only docking, layout, animation, and Think work to the live
  OverlayPanel subtree. A Hint no longer reprocesses the retained WorldPanel and
  hidden stock spawn-menu tree at overlay refresh cadence.
- Stops expired Hint overlay work from perpetuating Surface refresh requests,
  allowing movement processing to return to the ordinary gameplay cadence.

## Validation boundary

- Focused tests cover stock Hint expiry/recovery, OverlayPanel isolation from a
  large WorldPanel tree, and Q Surface publication/scheduling.
- Automated Apple validation covers the package and installable app boundary.
  Physical-iPad behavior remains the final device check and is not represented
  as already re-tested by this release process.
