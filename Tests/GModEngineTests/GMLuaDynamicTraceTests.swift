import XCTest
@testable import GModEngine
import GModLua

private final class DynamicTraceWorldProvider: GMLuaTraceProvider,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var fractionStorage: Float?

    init(fraction: Float? = nil) {
        fractionStorage = fraction
    }

    var isWorldReady: Bool { true }

    var fraction: Float? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return fractionStorage
        }
        set {
            lock.lock()
            fractionStorage = newValue
            lock.unlock()
        }
    }

    func traceWorld(_ request: GMLuaTraceRequest) throws -> SourceGameTrace {
        var result = SourceGameTrace(ray: request.ray)
        guard let fraction else { return result }
        result.fraction = fraction
        result.endPosition = request.ray.actualStart + request.ray.delta * fraction
        result.plane = SourcePlane(
            normal: SourceVector3(-1, 0, 0),
            distance: result.endPosition.x
        )
        result.contents = .solid
        result.entityHandle = request.worldIdentity.handle
        return result
    }
}

private final class DynamicTraceCandidateProvider:
    GMLuaDynamicTraceCandidateProvider, @unchecked Sendable
{
    private let lock = NSLock()
    private var candidatesStorage: [GMLuaDynamicTraceCandidate] = []
    private var lastRequestStorage: GMLuaTraceRequest?
    var collisionPolicy: @Sendable (Int32, Int32) -> Bool = { _, _ in true }

    var isDynamicTraceReady: Bool { true }

    var candidates: [GMLuaDynamicTraceCandidate] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return candidatesStorage
        }
        set {
            lock.lock()
            candidatesStorage = newValue
            lock.unlock()
        }
    }

    var lastRequest: GMLuaTraceRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequestStorage
    }

    func dynamicTraceCandidates(
        for request: GMLuaTraceRequest
    ) throws -> [GMLuaDynamicTraceCandidate] {
        lock.lock()
        lastRequestStorage = request
        let value = candidatesStorage
        lock.unlock()
        return value
    }

    func shouldCollide(
        queryCollisionGroup: Int32,
        candidateCollisionGroup: Int32
    ) -> Bool {
        collisionPolicy(queryCollisionGroup, candidateCollisionGroup)
    }
}

final class GMLuaDynamicTraceTests: XCTestCase {
    func testLineUsesStudioHitboxWhileHullUsesAttestedConvexShape() throws {
        let harness = try makeHarness()
        harness.dynamic.candidates = [try candidate(identity: harness.prop)]

        try harness.runtime.execute(
            """
            local line = util.TraceLine({
                start = Vector(0, 0, 0),
                endpos = Vector(20, 0, 0),
                mask = MASK_SHOT
            })
            assert(line.Hit and line.HitNonWorld and not line.HitWorld)
            assert(line.Entity == Entity(7))
            assert(line.Contents == CONTENTS_HITBOX)
            assert(line.HitBox == 4 and line.HitGroup == 7 and line.PhysicsBone == 2)
            assert(math.abs(line.Fraction - 0.1984375) < 0.000001)
            assert(math.abs(line.HitPos.x - 3.96875) < 0.00001)

            local hull = util.TraceHull({
                start = Vector(0, 0, 0),
                endpos = Vector(20, 0, 0),
                mins = Vector(-0.5, -0.5, -0.5),
                maxs = Vector(0.5, 0.5, 0.5),
                mask = MASK_SHOT_HULL
            })
            assert(hull.Hit and hull.HitNonWorld and not hull.HitWorld)
            assert(hull.Entity == Entity(7))
            assert(hull.Contents == CONTENTS_MOVEABLE)
            assert(hull.HitBox == -1 and hull.HitGroup == 0)
            assert(math.abs(hull.Fraction - 0.4234375) < 0.000001)
            assert(math.abs(hull.HitPos.x - 8.46875) < 0.00001)
            """,
            sourceName: "@GMLuaDynamicStudioAndHullTrace.lua"
        )
    }

    func testEntityTableFunctionWhitelistAndCollisionGroupFilterCandidates() throws {
        let harness = try makeHarness()
        harness.dynamic.candidates = [try candidate(identity: harness.prop)]
        harness.dynamic.collisionPolicy = { query, candidate in
            query == 5 && candidate == 9
        }

        try harness.runtime.execute(
            """
            local base = {
                start = Vector(0, 0, 0),
                endpos = Vector(20, 0, 0),
                mask = MASK_SHOT,
                collisiongroup = 5
            }
            base.filter = Entity(7)
            assert(not util.TraceLine(base).Hit)

            base.filter = { Entity(7), NULL }
            base.whitelist = true
            assert(util.TraceLine(base).Entity == Entity(7))

            local calls = 0
            base.whitelist = false
            base.filter = function(entity)
                calls = calls + 1
                return entity == Entity(7)
            end
            assert(util.TraceLine(base).Entity == Entity(7))
            assert(calls == 1)

            base.filter = function() return false end
            assert(not util.TraceLine(base).Hit)

            base.filter = nil
            base.collisiongroup = 6
            assert(not util.TraceLine(base).Hit)
            """,
            sourceName: "@GMLuaDynamicTraceFilters.lua"
        )

        XCTAssertEqual(harness.dynamic.lastRequest?.collisionGroup, 6)
    }

    func testWorldWinsExactFractionTieAndNearerDynamicHitWins() throws {
        let world = DynamicTraceWorldProvider(fraction: 0.198_437_5)
        let harness = try makeHarness(world: world)
        harness.dynamic.candidates = [try candidate(identity: harness.prop)]

        try harness.runtime.execute(
            """
            local tied = util.TraceLine({
                start = Vector(0, 0, 0), endpos = Vector(20, 0, 0),
                mask = MASK_SHOT
            })
            assert(tied.HitWorld and tied.Entity == Entity(0))
            """,
            sourceName: "@GMLuaDynamicTraceWorldTie.lua"
        )

        world.fraction = 0.3
        try harness.runtime.execute(
            """
            local nearer = util.TraceLine({
                start = Vector(0, 0, 0), endpos = Vector(20, 0, 0),
                mask = MASK_SHOT
            })
            assert(nearer.HitNonWorld and nearer.Entity == Entity(7))
            """,
            sourceName: "@GMLuaDynamicTraceNearerEntity.lua"
        )
    }

    func testStaleDynamicCandidateCannotResolveByEntryIndexAlone() throws {
        let harness = try makeHarness()
        let stale = SourceCanonicalEntityIdentity(handle: SourceBaseHandle(
            entryIndex: harness.prop.entryIndex,
            serialNumber: (harness.prop.serialNumber + 1) & 0xFFFF
        ))
        harness.dynamic.candidates = [try candidate(identity: stale)]

        let values = try harness.runtime.executeReturningValues(
            """
            local ok, message = pcall(function()
                util.TraceLine({
                    start = Vector(0, 0, 0), endpos = Vector(20, 0, 0),
                    mask = MASK_SHOT
                })
            end)
            return ok, tostring(message)
            """,
            sourceName: "@GMLuaDynamicTraceStaleHandle.lua"
        )
        guard values.count == 2,
              case let .boolean(ok) = values[0],
              case let .string(message) = values[1] else {
            XCTFail("unexpected pcall result")
            return
        }
        XCTAssertFalse(ok)
        XCTAssertTrue(message.utf8String.contains("unavailable EHANDLE"))
    }

    private struct Harness {
        let runtime: GMLuaRuntime
        let adapter: GMLuaSourceRuntimeAdapter
        let dynamic: DynamicTraceCandidateProvider
        let prop: SourceCanonicalEntityIdentity
    }

    private func makeHarness(
        world: DynamicTraceWorldProvider = DynamicTraceWorldProvider()
    ) throws -> Harness {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: runtime)
        _ = try adapter.createCanonicalEntity(kind: .world, at: 0)
        let prop = try adapter.createCanonicalEntity(kind: .propPhysics, at: 7)
        let dynamic = DynamicTraceCandidateProvider()
        runtime.traceBridge?.connect(provider: GMLuaCompositeTraceProvider(
            world: world,
            dynamic: dynamic
        ))
        return Harness(
            runtime: runtime,
            adapter: adapter,
            dynamic: dynamic,
            prop: prop.identity
        )
    }

    private func candidate(
        identity: SourceCanonicalEntityIdentity
    ) throws -> GMLuaDynamicTraceCandidate {
        let hitbox = try GMLuaDynamicStudioHitbox(
            minimum: SourceVector3(-1, -1, -1),
            maximum: SourceVector3(1, 1, 1),
            boneToWorld: SourceStudioMatrix3x4(
                1, 0, 0, 5,
                0, 1, 0, 0,
                0, 0, 1, 0
            ),
            contents: .hitbox,
            surface: SourceTraceSurface(name: "studio", flags: 12),
            hitBox: 4,
            hitGroup: 7,
            physicsBone: 2
        )
        let hull = try GMLuaDynamicHullCollision(
            transform: SourceEntityTransform(origin: SourceVector3(10, 0, 0)),
            collisionProperty: SourceCollisionProperty(
                mins: SourceVector3(-1, -1, -1),
                maxs: SourceVector3(1, 1, 1)
            ),
            physicsShape: try cubeShape(),
            contents: .moveable,
            surface: SourceTraceSurface(name: "vphysics", flags: 22)
        )
        return GMLuaDynamicTraceCandidate(
            identity: identity,
            className: "prop_physics",
            collisionGroup: 9,
            studioHitboxes: [hitbox],
            hullCollision: hull
        )
    }

    private func cubeShape() throws -> SourcePhysicsShapeSnapshot {
        let vertices = [
            SourceVector3(-1, -1, -1), SourceVector3(1, -1, -1),
            SourceVector3(-1, 1, -1), SourceVector3(1, 1, -1),
            SourceVector3(-1, -1, 1), SourceVector3(1, -1, 1),
            SourceVector3(-1, 1, 1), SourceVector3(1, 1, 1),
        ]
        let indices = [
            (0, 4, 6), (0, 6, 2), (1, 3, 7), (1, 7, 5),
            (0, 1, 5), (0, 5, 4), (2, 6, 7), (2, 7, 3),
            (0, 2, 3), (0, 3, 1), (4, 5, 7), (4, 7, 6),
        ]
        let triangles = try indices.map {
            try SourcePhysicsIndexedTriangle(
                first: $0.0,
                second: $0.1,
                third: $0.2,
                materialIndex: 0
            )
        }
        return try SourcePhysicsShapeSnapshot(
            topology: .convexParts,
            parts: [try SourcePhysicsMeshPartSnapshot(
                vertices: vertices,
                triangles: triangles
            )]
        )
    }
}
