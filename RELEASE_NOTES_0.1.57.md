# Garry's PAD / GModCore 0.1.57

0.1.57 is a focused regression hotfix for the formal 0.1.56 release.

## Session startup and terrain

- Allows finite `CDispVert::m_Alpha` values to retain their authored BSP value
  and saturates them at the Metal material boundary. This fixes bundled
  `gm_construct` startup, whose Valve-authored displacement data contains a
  small overshoot above 255.
- Continues to reject non-finite displacement data instead of hiding corrupt
  map input.

## VGUI, Hint, and input

- Repairs the gameplay VGUI regressions reported on iPad, including the stock
  Q-menu, Problems text presentation, and visible Hint notifications.
- Prevents notification-frame work from accumulating after a Hint fires, so
  movement input remains responsive.

## Validation status

- The bundled `gm_construct` displacement regression test passes.
- Focused VGUI, Hint, input-latency, and Apple test-target checks are recorded
  on the release commit. Physical-iPad observations reported against 0.1.56
  were the source of this hotfix; they are not represented as automated tests.
