# Source rigid-body angular convention

## Verified contract

Valve's published SDK fixes two distinct conventions:

- [vphysics_interface.h, coordinates](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/public/vphysics_interface.h#L24):
  QAngle components describe pitch/yaw/roll about Y/Z/X, whereas AngularImpulse
  is an axis/twist vector in degrees. They cannot be interchanged componentwise.
- [IPhysicsObject velocity methods](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/public/vphysics_interface.h#L772):
  linear velocity is world-space; angular velocity is object-local.
- [Facepunch PhysObj](https://wiki.facepunch.com/gmod/PhysObj):
  GetAngleVelocity uses local degrees/second; CalculateVelocityOffset returns
  values consumable by AddVelocity/AddAngleVelocity. GetVelocityAtPoint reports
  world velocity at a world point.
- [Valve's published grab controller](https://github.com/ValveSoftware/source-sdk-2013/blob/c8f4c6351162fbff83bfa5a428d45d1e6eed3824/src/game/server/hl2/weapon_physcannon.cpp#L2636):
  its target origin subtracts the local attachment point rotated by the target
  orientation, not by the previous body pose. This establishes the geometric
  target relationship; it is not evidence of full Garry's Mod physgun dynamics.

## Implemented correction

The deterministic backend previously mixed local angular state with world
contact impulses, and directly added angular X/Y/Z to QAngle pitch/yaw/roll.
This rotated bodies about incorrect axes. The correction keeps public angular
state local and:

- integrates the local axis/twist exponential map by right-multiplying the
  orientation quaternion, then projects the result back to the Source basis;
- converts world torque/offset/contact impulses through the body frame and
  principal inertia before changing local angular velocity;
- transforms angular velocity to world space for contact-point velocity and
  fixed-constraint velocity comparison;
- returns local angular velocity from CalculateVelocityOffset;
- computes physgun orientation error as the shortest relative quaternion in
  the held body's local frame, rather than subtracting Euler components;
- uses that same target orientation to position an off-center grab, while
  retaining the linear/angular speed limits and the existing FIFO lifecycle;
- exposes GetVelocityAtPoint over the authoritative body snapshot.

Fixed constraints retain their existing backend-independent approximation;
correcting their coordinate convention is not a claim of native VPhysics joint
solver parity. The same applies to the physgun's existing velocity controller.

## Scope and remaining work

This does not replace the backend with Valve's VPhysics binary or authenticate
arbitrary PHY geometry. Existing exact-asset validation remains in place; no
fallback collider, mass, inertia, material, or successful PhysObj is fabricated.
The current body contract still assumes the body origin is its mass center.
Nonzero local mass-center offsets, full asymmetric torque-free dynamics,
rotational continuous collision, contact manifolds and native shadow-controller
matching remain separate physical work, not implied by correct axis conversion.

The numerical reference tests compare basis vectors with independent Rodrigues
rotation, not the production quaternion conversion. Physical iPad prop spawn,
fall, rotate, physgun hold/drop and contact behavior still require device tests.

## Validation recorded 2026-10-19

Windows x86_64, Swift 6.4.1:

```sh
swift test --jobs 2 --filter 'Physics|Physgun|Thruster|GModStockPropVerticalIntegrationTests|GModAttestedPropRuntimeBridgeIntegrationTests'
```

50 XCTest tests and 93 Swift Testing tests passed, with no failures or skips.
Coverage includes the real Lua session/FIFO prop and physgun fixture,
off-center simultaneous rotation/translation, retained gravity and speed
limiting, drop/freeze/unfreeze/removal, rotated spinning contact response,
fixed constraints, material responses, BSP collision queries, generation-safe
body lifecycle, and deterministic replay. Fixture attestations are synthetic
test data, not new approvals for arbitrary models in the user's content pack.
The optional owned-content diagnostic suite is not selected by this command.

The replay byte schema is unchanged. This does not promise that recorded
outputs from the older faulty angular solver match the corrected simulation.
Apple compilation/Simulator validation for this physics change and physical
iPad acceptance remain separate gates; Windows passing does not establish them.
