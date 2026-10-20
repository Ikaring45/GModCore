# Rope anchor impulses

## Published Source contract

[Valve's `constraint_lengthparams_t`](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/public/vphysics/constraints.h#L251)
defines local attachment points and maximum/minimum lengths. A flexible rope
allows shortening; a rigid rope sets both limits to the same length.
[Facepunch's Rope implementation](https://github.com/Facepunch/garrysmod/blob/master/garrysmod/lua/includes/modules/constraint.lua)
passes local PhysObj attachment points through `phys_lengthconstraint` and sets
the rigid spawn flag. These sources define behavior, not the private numerical
VPhysics solver.

## Connected deterministic behavior

The independent backend now computes the velocity at each attachment, rather
than comparing only the two centers' linear velocities:

```text
r = R * (localAnchor - massCenterLocal)
v_anchor = v_center + (R * angularVelocity_degrees * pi/180) cross r
K = inverseMassA + inverseMassB
    + n dot ((inverseInertiaWorldA * (rA cross n)) cross rA)
    + n dot ((inverseInertiaWorldB * (rB cross n)) cross rB)
J = dot(v_anchorB - v_anchorA, n) / K
```

The endpoints receive opposite impulses at their attachment points. This
changes both world linear velocity and object-local angular velocity, using
the authored local center and principal inertia. A pure spin can therefore
create tension even if the center has no separation velocity.

- Upper-only limits cancel outward velocity, never inward velocity. A stretched
  rope which is already shortening is position-corrected without a pushing
  velocity impulse. Equal limits resist both signs; positive lower limits
  resist compression only.
- A taut rope responds at the boundary, not one tick after it. A roundoff-sized
  tolerance (four Float ULPs, capped below overlapping limits) is not an added
  gameplay slack length.
- Kinematic anchors contribute their actual linear and angular point velocity
  but have zero solver inverse mass. Static-world and motion-disabled anchors
  remain immovable and cannot contribute stale stored velocities.
- Constraint wake requests on frozen props no longer reject the fixed-tick
  batch. Wake does not enable motion: frozen endpoints remain frozen. This
  backend policy keeps the separate public
  [Wake](https://wiki.facepunch.com/gmod/PhysObj:Wake)/[EnableMotion](https://wiki.facepunch.com/gmod/PhysObj:EnableMotion) operations
  distinct; it is not evidence of a private VPhysics sleep implementation.
- Quietly supported bodies can accumulate settled ticks and sleep. An idle
  rope pass does not continuously wake them.
- Non-finite world anchors, effective mass, or impulses fail the candidate
  batch atomically, retaining the previous poses, velocities, constraint state
  and FIFO sequence. Separation magnitude uses Double intermediates so squaring
  a representable Float length does not overflow first.

The existing `constraint.Rope` -> shared FIFO -> SERVER fixed tick -> canonical
Entity/PhysObj commit path uses this solver. Immutable world endpoints and full
EHANDLE identities are retained. No guessed collider, mass, or trusted prop
manifest is introduced.

## Explicit remaining boundaries

Position drift correction still translates endpoints by inverse mass; it does
not perform a nonlinear angular pose projection. The iterative velocity solve
does not yet use accumulated/warm-started joint impulses or native VPhysics
joint-group policies. Coupled contacts/chains and degenerate coincident anchors
therefore still need further solver work and comparative acceptance. No native
numeric parity or complete rope stability is claimed.

Positive break-force limits remain explicitly unsupported, rather than using
an invented force threshold. Visible `keyframe_rope` rendering is still
unavailable and reported separately from a valid physical constraint. This
work does not add rope rendering, arbitrary prop attestation, or iPad proof.

The replay byte format remains v12. Earlier v12 recordings parse under the same
schema but may not numerically replay when they contain the corrected rope
behavior; re-record them with the current solver rather than replacing expected
snapshots to hide a mismatch.

## Validation

Focused Windows tests cover analytical off-center impulses in both endpoint
orders, rotated inertia/nonzero COM, pure spin, two dynamic endpoints, kinematic
rotation, disabled motion, unilateral/rigid boundary cases, sleep, atomic
failure and deterministic replay. A real `GModPlayableSession` test exercises
stock `constraint.Rope`, actual solver execution, canonical state/replication,
PhysObj reads and constraint removal using synthetic fixture data.

Windows results, Apple CI and actual iPad acceptance are separate gates.

### Windows regression, 2026-10-20

Swift 6.4.1 on x86_64 Windows:

```sh
swift test --jobs 2 --filter 'Physics|Physgun|Thruster|SourceCanonicalRopeConstraintIntegrationTests|GModStockPropVerticalIntegrationTests|GModAttestedPropRuntimeBridgeIntegrationTests'
```

60 XCTest tests and 108 Swift Testing tests passed, with zero failures or skips
(168 total). The real-session angular Rope case is included; its synthetic
attestation does not approve arbitrary content-pack props. The existing Apple
run for `80fc59d` predates this change and was still running at this validation
point. This result is not an Apple/device or visible rope-rendering acceptance.
