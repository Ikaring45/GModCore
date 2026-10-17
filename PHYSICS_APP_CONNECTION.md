# App physics connection

The existing independent deterministic rigid-body backend is connected to the
SERVER fixed tick, canonical Entity/PhysObj state and FIFO replication. It is
not Valve's VPhysics binary, Jolt, or proof of complete Source physics parity.

The public Swift Playgrounds entry point now forwards an explicitly supplied
independently attested physics manifest to every map start:

```swift
GModMainView(attestedPropPhysicsManifestURL: manifestURL)
```

`manifestURL` must point to an app-readable file (copy an imported document into
app storage first). Mount the matching owned content ZIP before starting a map.
The existing loader checks the exact MDL/PHY digests, selected solid, geometry,
mass, inertia, axis convention and material data. A missing or invalid record
does not authorize guessed shapes or a dummy PhysObj. No manifest is bundled
or automatically trusted by this change.

No-argument `GModMainView()` remains supported. Without matching attested prop
data, arbitrary prop bodies remain unavailable; this API is not an assertion
that every Sandbox model now spawns physically. A built-in import UI and actual
iPad spawn/fall/settle/remove acceptance are still outstanding.

Validation: existing manifest/coordinator Windows suites, 13 tests passed.
Changed Apple app sources passed syntax parsing only; Apple typecheck/CI and
physical iPad integration remain unverified.
