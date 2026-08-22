import Testing
@testable import GModEngine
import GModGameAssets

@Suite("Detailed BSP brush and displacement world collision")
struct SourceBSPDetailedWorldCollisionProviderTests {
    @Test("gm_construct util line/hull hit real displacement with full world EHANDLE")
    func constructDetailedTrace() throws {
        try verifyDetailedTrace(map: .construct, worldSerial: 417)
    }

    @Test("gm_flatgrass util line/hull hit real displacement with full world EHANDLE")
    func flatgrassDetailedTrace() throws {
        try verifyDetailedTrace(map: .flatgrass, worldSerial: 733)
    }

    @Test("gm_construct player movement lands on real displacement terrain")
    func constructPlayerWalk() throws {
        let fixture = try makeFixture(map: .construct, worldSerial: 951)
        let movementProvider = try SourceBSPDetailedWorldCollisionProvider(
            bsp: fixture.bsp,
            staticPhysicsAsset: fixture.asset,
            worldIdentity: fixture.worldIdentity
        )
        let landing = try findWalkableDisplacementLanding(
            fixture: fixture,
            provider: movementProvider
        )
        let solver = SourceWorldWalkSolver(
            collisionProvider: movementProvider
        )
        var state = SourceWorldWalkState(
            origin: landing.endPosition + SourceVector3(0, 0, 96)
        )
        for commandNumber in Int32(1) ... Int32(160) {
            state = try solver.simulate(
                state: state,
                command: SourceUserCommand(
                    commandNumber: commandNumber,
                    tickCount: commandNumber
                )
            ).state
            if state.isOnGround { break }
        }

        #expect(state.isOnGround)
        #expect(state.origin.z > landing.endPosition.z - 0.1)
        let groundProbe = try movementProvider.traceWorldWalk(
            SourceRay(
                start: state.origin,
                end: state.origin - SourceVector3(0, 0, 2),
                mins: SourceWorldWalkSolver.standingHullMins,
                maxs: SourceWorldWalkSolver.standingHullMaxs
            ),
            mask: SourceWorldWalkSolver.playerMask
        )
        #expect(groundProbe.didHitWorld)
        #expect(
            groundProbe.entityHandle == fixture.worldIdentity.handle
        )
        #expect(
            groundProbe.displacementFlags ==
                SourceDisplacementTraceFlags.surface
        )
    }

    private func verifyDetailedTrace(
        map: GModBundledMap,
        worldSerial: Int
    ) throws {
        let fixture = try makeFixture(map: map, worldSerial: worldSerial)
        let provider = try SourceBSPDetailedWorldCollisionProvider(
            bsp: fixture.bsp,
            staticPhysicsAsset: fixture.asset
        )
        let line = try findDisplacementSurface(
            fixture: fixture,
            provider: provider
        )

        #expect(line.didHitWorld)
        #expect(line.entityHandle == fixture.worldIdentity.handle)
        #expect(
            line.displacementFlags == SourceDisplacementTraceFlags.surface
        )
        #expect(line.plane.normal.lengthSquared > 0.999)

        let hullRay = SourceRay(
            start: line.endPosition + line.plane.normal * 8,
            end: line.endPosition - line.plane.normal * 0.5,
            mins: SourceVector3(-0.125, -0.125, -0.125),
            maxs: SourceVector3(0.125, 0.125, 0.125)
        )
        let hull = try provider.traceWorld(GMLuaTraceRequest(
            kind: .hull,
            ray: hullRay,
            mask: SourceMasks.playerSolidBrushOnly,
            worldIdentity: fixture.worldIdentity,
            excludedEntityHandles: []
        ))
        #expect(hull.didHitWorld)
        #expect(hull.entityHandle == fixture.worldIdentity.handle)
        #expect(
            hull.displacementFlags == SourceDisplacementTraceFlags.surface
        )

        // A remote miss remains byte-for-byte the BSP miss. Detailed terrain
        // must not perturb the existing brush clipper's empty result.
        let missRay = SourceRay(
            start: SourceVector3(10_000_000, 10_000_000, 10_000_000),
            end: SourceVector3(10_000_000, 10_000_000, 9_999_000)
        )
        let brushMiss = try fixture.bsp.traceWorld(
            missRay,
            mask: SourceMasks.playerSolidBrushOnly
        )
        let detailedMiss = try provider.traceWorld(GMLuaTraceRequest(
            kind: .line,
            ray: missRay,
            mask: SourceMasks.playerSolidBrushOnly,
            worldIdentity: fixture.worldIdentity,
            excludedEntityHandles: []
        ))
        #expect(detailedMiss == brushMiss)

        // Move one unit through a real brush entering plane. Its zero-length
        // trace proves StartSolid/AllSolid and the BSP result are retained;
        // only the placeholder world handle is replaced by the caller's full
        // canonical generation.
        let extendedBrushRay = SourceRay(
            start: line.endPosition + SourceVector3(0, 0, 1_024),
            end: line.endPosition - SourceVector3(0, 0, 4_096)
        )
        let brushEntry = try fixture.bsp.traceWorld(
            extendedBrushRay,
            mask: SourceMasks.playerSolidBrushOnly
        )
        #expect(brushEntry.didHit)
        let inside = brushEntry.endPosition - brushEntry.plane.normal
        let zeroRay = SourceRay(start: inside, end: inside)
        var expectedStartSolid = try fixture.bsp.traceWorld(
            zeroRay,
            mask: SourceMasks.playerSolidBrushOnly
        )
        #expect(expectedStartSolid.startSolid)
        expectedStartSolid.entityHandle = fixture.worldIdentity.handle
        let detailedStartSolid = try provider.traceWorld(GMLuaTraceRequest(
            kind: .line,
            ray: zeroRay,
            mask: SourceMasks.playerSolidBrushOnly,
            worldIdentity: fixture.worldIdentity,
            excludedEntityHandles: []
        ))
        #expect(detailedStartSolid == expectedStartSolid)

        let pointContents = try provider.worldWalkPointContents(
            at: inside,
            mask: SourceMasks.playerSolidBrushOnly
        )
        let expectedPointContents = try fixture.bsp.worldPointContents(
            at: inside,
            mask: SourceMasks.playerSolidBrushOnly
        )
        #expect(pointContents == expectedPointContents)
    }

    private func findDisplacementSurface(
        fixture: Fixture,
        provider: SourceBSPDetailedWorldCollisionProvider
    ) throws -> SourceGameTrace {
        let firstDisplacement = fixture.asset.includedBrushIndices.count
        let parts = fixture.asset.geometry.parts.dropFirst(firstDisplacement)
        for part in parts {
            for triangle in part.triangles {
                let first = part.vertices[triangle.first]
                let second = part.vertices[triangle.second]
                let third = part.vertices[triangle.third]
                var normal = cross(second - first, third - first)
                let length = normal.length
                guard length > 0 else { continue }
                normal = normal / length
                if normal.z < 0 { normal = -normal }
                guard normal.z >= 0.7 else { continue }
                let center = (first + second + third) / 3
                let ray = SourceRay(
                    start: center + normal * 8,
                    end: center - normal * 0.5
                )
                let detailed = try provider.traceWorld(GMLuaTraceRequest(
                    kind: .line,
                    ray: ray,
                    mask: SourceMasks.playerSolidBrushOnly,
                    worldIdentity: fixture.worldIdentity,
                    excludedEntityHandles: []
                ))
                if detailed.displacementFlags ==
                    SourceDisplacementTraceFlags.surface {
                    return detailed
                }
            }
        }
        throw FixtureError.noDetailedDisplacementHit
    }

    private func findWalkableDisplacementLanding(
        fixture: Fixture,
        provider: SourceBSPDetailedWorldCollisionProvider
    ) throws -> SourceGameTrace {
        let firstDisplacement = fixture.asset.includedBrushIndices.count
        let parts = fixture.asset.geometry.parts.dropFirst(firstDisplacement)
        for part in parts {
            for triangle in part.triangles {
                let first = part.vertices[triangle.first]
                let second = part.vertices[triangle.second]
                let third = part.vertices[triangle.third]
                var normal = cross(second - first, third - first)
                let length = normal.length
                guard length > 0 else { continue }
                normal = normal / length
                if normal.z < 0 { normal = -normal }
                guard normal.z >= 0.98 else { continue }
                let center = (first + second + third) / 3
                let ray = SourceRay(
                    start: center + SourceVector3(0, 0, 96),
                    end: center - SourceVector3(0, 0, 32),
                    mins: SourceWorldWalkSolver.standingHullMins,
                    maxs: SourceWorldWalkSolver.standingHullMaxs
                )
                let hit = try provider.traceWorldWalk(
                    ray,
                    mask: SourceWorldWalkSolver.playerMask
                )
                if hit.displacementFlags ==
                    SourceDisplacementTraceFlags.surface,
                   !hit.startSolid,
                   !hit.allSolid,
                   hit.plane.normal.z >= SourceWorldWalkSolver.walkableNormalZ {
                    return hit
                }
            }
        }
        throw FixtureError.noWalkableDisplacementHit
    }

    private func makeFixture(
        map: GModBundledMap,
        worldSerial: Int
    ) throws -> Fixture {
        let data = try GModGameAssets.data(for: map, kind: .bsp)
        let bsp = try SourceBSP(data: data)
        let manifest = try GModGameAssets.manifest()
        let logicalPath = "maps/\(map.rawValue).bsp"
        guard let entry = manifest.assets.first(where: {
            $0.logicalPath == logicalPath
        }) else {
            throw FixtureError.missingManifestEntry(logicalPath)
        }
        let asset = try SourceBSPStaticPhysicsBridge.build(
            bsp: bsp,
            bspSHA256: entry.sha256,
            contentsMask: SourceMasks.playerSolidBrushOnly
        )
        return Fixture(
            bsp: bsp,
            asset: asset,
            worldIdentity: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle(
                    entryIndex: 0,
                    serialNumber: worldSerial
                )
            )
        )
    }

    private func cross(
        _ lhs: SourceVector3,
        _ rhs: SourceVector3
    ) -> SourceVector3 {
        SourceVector3(
            lhs.y * rhs.z - lhs.z * rhs.y,
            lhs.z * rhs.x - lhs.x * rhs.z,
            lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private struct Fixture {
        let bsp: SourceBSP
        let asset: SourceBSPAttestedStaticPhysicsAsset
        let worldIdentity: SourceCanonicalEntityIdentity
    }

    private enum FixtureError: Error {
        case missingManifestEntry(String)
        case noDetailedDisplacementHit
        case noWalkableDisplacementHit
    }
}
