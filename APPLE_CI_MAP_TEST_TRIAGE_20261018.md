# Apple map-test failures: evidence and correction

Completed CI failure inspected:
[39080455476](https://github.com/Ikaring45/GModCore/actions/runs/39080455476),
commit `696876d`. This is an earlier run, not proof of current Apple success.
The allocation and displacement failures also reproduced on current Windows.

1. Allocation fixture bytes predated `sourceDisplacementAlpha`. Counts remain
   exact and unchanged; current working strides are 144 bytes/world vertex
   and 100 bytes/displacement vertex, rather than the old 136/96. Both Apple
   failure logs and Windows calculations agree. Expectations are updated for
   both bundled maps; byte caps and typed over-limit rejection are unchanged.
2. Construct's `gm_construct/flatgrass` brush range has 84 indices in `sky3D`;
   its displacement range has 13,824 indices in `world`. The old test searched
   only world ranges before demanding both kinds. The correction explicitly
   verifies both layers and both exact counts, plus existing PVS/lightmap tests.
3. `maps/gm_construct/c1436_-571_-71` is a packed VTF, with no corresponding
   VMT. The Metal sampler test incorrectly used material resolution. It now
   uses the existing explicit authored-VTF resolver (made internal for the
   test), not a synthesized material or new fallback. A portable test proves
   materialMissing, decoded VTF, all six authored mip dimensions from 32x32 to
   1x1, and S/T clamp flags from actual bundled BSP bytes.

The targeted six portable tests pass. Changed Metal/test files passed Swift
syntax parsing on Windows only. Apple typecheck, sampler execution, Simulator
tests and physical iPad remain separate gates; no new Apple PASS is asserted.
The wider material/VPK/allocation/terrain run also passed: 20 executed, two
installed-content opt-in diagnostics skipped, no failures.
