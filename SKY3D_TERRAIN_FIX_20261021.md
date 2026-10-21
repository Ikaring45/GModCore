# 3D sky displacement partition repair (2026-10-21)

## Reproduced cause

The sky compiler used only ordinary `LUMP_LEAFFACES` membership. In the
bundled gm_flatgrass BSP, none of the sixteen displacement terrain faces
(2906...2921) occurs in that list. They were therefore emitted as ordinary
world geometry, without the sky camera transform. gm_construct likewise
had twenty-one sky displacement patches incorrectly assigned to the world.
This was not evidence that the terrain was missing from the content pack.

The user's stored content ZIP and bundled BSPs have identical SHA-256 values:

| Map | SHA-256 |
| --- | --- |
| gm_construct | `4d1c027f2b93fa9100bcc4cb08b1dfdda437cadf4cf7d01d4b515dc2caa5a6a2` |
| gm_flatgrass | `4dfd95ecb8f77a093e3079697b04c5be5675e8595c05639aaf57ad1541024d76` |

## Implementation

After allocation-policy validation, compile each displacement's full deformed
bounds using the existing render geometry generator. Traverse the validated
BSP partition tree with those bounds to recover non-solid cluster membership.
This is conservative AABB render membership, not exact triangle/leaf clipping.
It avoids relying on a single corner or centroid that could be inside solid.

Use the recovered leaves for both sky-area/PVS classification and per-face
PVS spans. Sky terrain uses the existing `(position - skyOrigin) * scale`
baking and existing Metal sky pass. Original UVs, lightmap coordinates, alpha,
topology and collision data remain unchanged. Membership is computed at mesh
build time, not per frame. No replacement hills, map-specific coordinates,
model substitutes or disabled-PVS workaround are introduced.

| Map | Ordinary world indices | 3D sky indices (excluding 2D sky cube) |
| --- | ---: | ---: |
| gm_construct | 92,922 | 31,074 |
| gm_flatgrass | 11,466 | 24,630 |

Older tests explicitly required every displacement to be ordinary world
geometry and the world index count to dominate the sky twentyfold. Those
expectations encoded the bug; they now check the correct layer partition,
unchanged total topology and exact layer-specific PVS span coverage.

## Validation boundary

Windows focused run: 17 passed, 1 optional installed-VPK test skipped,
0 failures. Tests include real BSPs, absence of flatgrass terrain leaf-face
references, nonempty recovered cluster spans, transformed vertex positions,
retained lightmap UVs, and nonempty terrain selection in four cardinal views.

The subsequent `GModWorld|GModMapAllocation` regression selection passed
21 tests, skipped the same optional VPK test, and reported zero failures.
Allocation-policy rejection still occurs before terrain membership generation.

At the outdoor spawn (90-degree vertical FOV, 4:3 aspect), selected sky index
counts for +X, +Y, -X, -Y changed as follows:

- gm_flatgrass: `[0, 0, 36, 18]` -> `[12288, 12288, 12324, 15378]`.
- gm_construct: `[1008, 1683, 840, 972]` -> `[17520, 18195, 17352, 17484]`.

These are portable geometry/visibility results, not rendered-image proof.
Apple build, Metal rendering, iPad visual parity, static-prop sky renderables,
and dynamic sky-camera changes are not established by this test run.
This change has not been published in a release.
