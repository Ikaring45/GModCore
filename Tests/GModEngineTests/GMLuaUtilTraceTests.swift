import Foundation
import XCTest
@testable import GModEngine
import GModGameAssets
import GModLua

private final class SyntheticWorldTraceProvider: GMLuaTraceProvider, @unchecked Sendable {
    enum Mode {
        case miss
        case hit
        case startSolid(allSolid: Bool)
        case staleWorld
        case nonWorld
        case nonFinite
    }

    let isWorldReady: Bool
    let mode: Mode

    private let lock = NSLock()
    private var requestStorage: GMLuaTraceRequest?

    init(mode: Mode, isWorldReady: Bool = true) {
        self.mode = mode
        self.isWorldReady = isWorldReady
    }

    var lastRequest: GMLuaTraceRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    func traceWorld(_ request: GMLuaTraceRequest) throws -> SourceGameTrace {
        lock.lock()
        requestStorage = request
        lock.unlock()

        var result = SourceGameTrace(ray: request.ray)
        switch mode {
        case .miss:
            return result
        case .hit:
            result.fraction = 0.25
            result.endPosition = request.ray.actualStart + request.ray.delta * 0.25
            result.plane = SourcePlane(normal: SourceVector3(0, 0, 1), distance: 5)
            result.contents = .solid
            result.displacementFlags = 3
            result.surface = SourceTraceSurface(
                name: "unresolved-test-surface",
                surfaceProperties: 99,
                flags: 128
            )
            result.hitGroup = 2
            result.physicsBone = 4
            result.hitBox = 7
            result.entityHandle = request.worldIdentity.handle
            return result
        case let .startSolid(allSolid):
            result.fraction = 0
            result.fractionLeftSolid = 0.75
            result.endPosition = request.ray.actualStart
            result.startSolid = true
            result.allSolid = allSolid
            result.contents = .solid
            result.entityHandle = request.worldIdentity.handle
            return result
        case .staleWorld:
            result.fraction = 0.5
            let serial = (request.worldIdentity.handle.serialNumber + 1) & 0xFFFF
            result.entityHandle = SourceBaseHandle(entryIndex: 0, serialNumber: serial)
            return result
        case .nonWorld:
            result.fraction = 0.5
            result.entityHandle = SourceBaseHandle(entryIndex: 7, serialNumber: 1)
            return result
        case .nonFinite:
            result.fraction = .nan
            result.entityHandle = request.worldIdentity.handle
            return result
        }
    }
}

final class GMLuaUtilTraceTests: XCTestCase {
    func testTraceLineMapsExactCoreHitFieldsAndOutputIdentity() throws {
        let provider = SyntheticWorldTraceProvider(mode: .hit)
        let (runtime, adapter) = try runtimeWithWorld(provider: provider)
        _ = adapter

        try runtime.execute(
            """
            local output = {
                sentinel = "preserved",
                HitTexture = "stale",
                SurfaceProps = 88,
                MatType = 77
            }
            local tr = util.TraceLine({
                start = Vector(0, 0, 10),
                endpos = Vector(0, 0, -10),
                output = output
            })
            assert(tr == output)
            assert(tr.sentinel == "preserved")
            assert(tr.StartPos == Vector(0, 0, 10))
            assert(tr.HitPos == Vector(0, 0, 5))
            assert(tr.HitNormal == Vector(0, 0, 1))
            assert(tr.Normal == Vector(0, 0, -1))
            assert(tr.Fraction == 0.25 and tr.FractionLeftSolid == 0)
            assert(tr.Hit and tr.HitWorld and not tr.HitNonWorld)
            assert(not tr.StartSolid and not tr.AllSolid)
            assert(tr.Contents == 1)
            assert(tr.Entity == Entity(0) and tr.Entity ~= NULL)
            assert(tr.SurfaceFlags == 128 and tr.DispFlags == 3)
            assert(tr.HitBox == 7 and tr.HitGroup == 2 and tr.PhysicsBone == 4)
            assert(tr.HitTexture == nil and tr.SurfaceProps == nil and tr.MatType == nil)
            assert(MASK_ALL == -1 and COLLISION_GROUP_NONE == 0)
            """,
            sourceName: "@GMLuaUtilTraceHit.lua"
        )

        let request = try XCTUnwrap(provider.lastRequest)
        XCTAssertEqual(request.kind, .line)
        XCTAssertTrue(request.ray.isRay)
        XCTAssertEqual(request.mask, SourceMasks.solid)
        XCTAssertEqual(request.ray.actualStart, SourceVector3(0, 0, 10))
        XCTAssertEqual(request.ray.actualEnd, SourceVector3(0, 0, -10))
    }

    func testTraceLineDefaultsToZeroVectorsAndReturnsCanonicalMiss() throws {
        let provider = SyntheticWorldTraceProvider(mode: .miss)
        let (runtime, adapter) = try runtimeWithWorld(provider: provider)
        _ = adapter

        try runtime.execute(
            """
            local tr = util.TraceLine({})
            assert(tr.StartPos == Vector(0, 0, 0))
            assert(tr.HitPos == Vector(0, 0, 0))
            assert(tr.HitNormal == Vector(0, 0, 0))
            assert(tr.Normal == Vector(0, 0, 0))
            assert(tr.Fraction == 1 and tr.FractionLeftSolid == 0)
            assert(not tr.Hit and not tr.HitWorld and not tr.HitNonWorld)
            assert(not tr.StartSolid and not tr.AllSolid)
            assert(tr.Contents == 0 and tr.Entity == NULL)
            assert(tr.SurfaceFlags == 0 and tr.DispFlags == 0)
            assert(tr.HitBox == -1 and tr.HitGroup == 0 and tr.PhysicsBone == 0)
            """,
            sourceName: "@GMLuaUtilTraceMiss.lua"
        )
    }

    func testTraceHullRequiresBoundsValidatesOrderAndMapsSolidState() throws {
        let provider = SyntheticWorldTraceProvider(mode: .startSolid(allSolid: true))
        let (runtime, adapter) = try runtimeWithWorld(provider: provider)
        _ = adapter

        try assertLuaFailure(
            "util.TraceHull({ maxs = Vector(1, 1, 1) })",
            contains: "requires Vector field 'mins'",
            runtime: runtime
        )
        try assertLuaFailure(
            "util.TraceHull({ mins = Vector(-1, -1, -1) })",
            contains: "requires Vector field 'maxs'",
            runtime: runtime
        )
        try assertLuaFailure(
            "util.TraceHull({ mins = Vector(2, 0, 0), maxs = Vector(1, 1, 1) })",
            contains: "must not exceed 'maxs'",
            runtime: runtime
        )

        try runtime.execute(
            """
            local tr = util.TraceHull({
                start = Vector(4, 5, 6),
                endpos = Vector(4, 5, -94),
                mins = Vector(-16, -16, 0),
                maxs = Vector(16, 16, 72)
            })
            assert(tr.StartPos == Vector(4, 5, 6))
            assert(tr.HitPos == Vector(4, 5, 6))
            assert(tr.Normal == Vector(0, 0, 0))
            assert(tr.Hit and tr.HitWorld)
            assert(tr.StartSolid and tr.AllSolid)
            assert(tr.Fraction == 0 and tr.FractionLeftSolid == 0.75)
            assert(tr.Entity == Entity(0))
            """,
            sourceName: "@GMLuaUtilTraceHull.lua"
        )

        let request = try XCTUnwrap(provider.lastRequest)
        XCTAssertEqual(request.kind, .hull)
        XCTAssertFalse(request.ray.isRay)
        XCTAssertEqual(request.ray.extents, SourceVector3(16, 16, 36))
        XCTAssertEqual(request.ray.actualStart, SourceVector3(4, 5, 6))

        let leavesSolid = SyntheticWorldTraceProvider(mode: .startSolid(allSolid: false))
        let (secondRuntime, secondAdapter) = try runtimeWithWorld(provider: leavesSolid)
        _ = secondAdapter
        try secondRuntime.execute(
            """
            local tr = util.TraceHull({
                mins = Vector(-1, -1, -1),
                maxs = Vector(1, 1, 1)
            })
            assert(tr.StartSolid and not tr.AllSolid)
            assert(tr.FractionLeftSolid == 0.75)
            """,
            sourceName: "@GMLuaUtilTraceLeavesSolid.lua"
        )
    }

    func testProviderAndWorldReadinessFailExplicitlyAndBridgeCanConnectLater() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: runtime)
        _ = try adapter.spawnNetworkableEntity(SourceEntity(className: "worldspawn"), at: 0)

        try assertLuaFailure(
            "util.TraceLine({})",
            contains: "no world trace provider is connected",
            runtime: runtime
        )

        let notReady = SyntheticWorldTraceProvider(mode: .miss, isWorldReady: false)
        runtime.traceBridge?.connect(provider: notReady)
        try assertLuaFailure(
            "util.TraceLine({})",
            contains: "world is not ready",
            runtime: runtime
        )

        let ready = SyntheticWorldTraceProvider(mode: .miss)
        runtime.traceBridge?.connect(provider: ready)
        try runtime.execute("assert(util.TraceLine({}).Fraction == 1)")
        runtime.traceBridge?.disconnectProvider()
        XCTAssertFalse(try XCTUnwrap(runtime.traceBridge).hasProvider)

        let runtimeWithoutWorld = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            traceProvider: ready
        )
        try assertLuaFailure(
            "util.TraceLine({})",
            contains: "canonical Source Entity(0) world mirror is unavailable",
            runtime: runtimeWithoutWorld
        )
    }

    func testRejectsUnsupportedDynamicAndNonDefaultInputsInsteadOfIgnoringThem() throws {
        let provider = SyntheticWorldTraceProvider(mode: .miss)
        let (runtime, adapter) = try runtimeWithWorld(provider: provider)
        _ = adapter

        let cases = [
            ("util.TraceLine()", "table expected"),
            ("util.TraceLine({ start = 1 })", "Vector expected"),
            ("util.TraceLine({ filter = Entity(0) })", "filter"),
            ("util.TraceLine({ collisiongroup = 1 })", "COLLISION_GROUP_NONE"),
            ("util.TraceLine({ ignoreworld = true })", "ignoreworld"),
            ("util.TraceLine({ whitelist = true })", "whitelist"),
            ("util.TraceLine({ hitclientonly = true })", "hitclientonly"),
            ("util.TraceLine({ output = 1 })", "output"),
            ("util.TraceLine({ ignoreworld = 0 })", "must be a boolean"),
        ]
        for (expression, fragment) in cases {
            try assertLuaFailure(expression, contains: fragment, runtime: runtime)
        }
    }

    func testClientTraceResolvesItsOwnWorldUserdataFromAValueOnlyProviderRequest() throws {
        let provider = SyntheticWorldTraceProvider(mode: .hit)
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport,
            traceProvider: provider
        )
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        let identity = try adapter.spawnNetworkableEntity(
            SourceEntity(className: "worldspawn"),
            at: 0
        )
        try adapter.attach(client: client)

        try client.execute(
            """
            local tr = util.TraceLine({
                start = Vector(0, 0, 10),
                endpos = Vector(0, 0, -10)
            })
            assert(tr.Hit and tr.HitWorld)
            assert(tr.Entity == Entity(0) and tr.Entity ~= NULL)
            assert(not tr.Entity:IsValid() and tr.Entity:GetClass() == "worldspawn")
            """,
            sourceName: "@GMLuaUtilTraceClientRealm.lua"
        )

        XCTAssertEqual(provider.lastRequest?.worldIdentity, identity)
        guard case let .userdata(serverWorld) = try XCTUnwrap(server.entityRegistry).entity(at: 0),
              case let .userdata(clientWorld) = try XCTUnwrap(client.entityRegistry).entity(at: 0) else {
            XCTFail("missing realm-local world userdata")
            return
        }
        XCTAssertFalse(serverWorld === clientWorld)
    }

    func testFiniteFloatBoundariesAndMaskAllAreCheckedWithoutTraps() throws {
        let provider = SyntheticWorldTraceProvider(mode: .miss)
        let (runtime, adapter) = try runtimeWithWorld(provider: provider)
        _ = adapter

        try runtime.execute(
            "assert(util.TraceLine({ mask = MASK_ALL }).Fraction == 1)",
            sourceName: "@GMLuaUtilTraceMaskAll.lua"
        )
        XCTAssertEqual(provider.lastRequest?.mask.rawValue, UInt32.max)

        let cases = [
            ("util.TraceLine({ start = Vector(math.huge, 0, 0) })", "finite Source Float"),
            ("util.TraceLine({ start = Vector(0/0, 0, 0) })", "finite Source Float"),
            ("util.TraceLine({ start = Vector(3.4e38, 0, 0), endpos = Vector(-3.4e38, 0, 0) })", "delta exceeds"),
            ("util.TraceLine({ endpos = Vector(1e20, 0, 0) })", "delta exceeds"),
            ("util.TraceLine({ mask = 1.5 })", "32-bit integer"),
            ("util.TraceLine({ mask = math.huge })", "32-bit integer"),
        ]
        for (expression, fragment) in cases {
            try assertLuaFailure(expression, contains: fragment, runtime: runtime)
        }
    }

    func testStaleNonWorldAndNonFiniteProviderResultsCannotEscape() throws {
        for (mode, fragment) in [
            (SyntheticWorldTraceProvider.Mode.staleWorld, "stale Entity(0) generation"),
            (.nonWorld, "dynamic entity trace hit"),
            (.nonFinite, "non-finite Fraction"),
        ] {
            let provider = SyntheticWorldTraceProvider(mode: mode)
            let (runtime, adapter) = try runtimeWithWorld(provider: provider)
            _ = adapter
            try assertLuaFailure(
                "util.TraceLine({ start = Vector(0, 0, 1), endpos = Vector(0, 0, -1) })",
                contains: fragment,
                runtime: runtime
            )
        }
    }

    func testBundledConstructAndFlatgrassTraceThroughLuaAgainstExactWorldEntity() throws {
        for map in GModBundledMap.allCases {
            let data = try GModGameAssets.data(for: map, kind: .bsp)
            let bsp = try SourceBSP(data: data)
            let provider = GMLuaSourceBSPTraceProvider(bsp: bsp)
            let (runtime, adapter) = try runtimeWithWorld(provider: provider)
            _ = adapter

            let text = try XCTUnwrap(bsp.entities.text)
            let spawn = try XCTUnwrap(try parsePlayerStarts(text).first)
            let start = SourceVector3(spawn.x, spawn.y, spawn.z + 512)
            let end = SourceVector3(spawn.x, spawn.y, spawn.z - 4_096)
            let typeSystem = try XCTUnwrap(runtime.typeSystem)
            runtime.state.setGlobal(
                "TRACE_START",
                value: try luaVector(start, typeSystem: typeSystem)
            )
            runtime.state.setGlobal(
                "TRACE_END",
                value: try luaVector(end, typeSystem: typeSystem)
            )

            let values = try runtime.executeReturningValues(
                """
                local line = util.TraceLine({
                    start = TRACE_START,
                    endpos = TRACE_END,
                    mask = MASK_PLAYERSOLID_BRUSHONLY
                })
                local hull = util.TraceHull({
                    start = TRACE_START,
                    endpos = TRACE_END,
                    mins = Vector(-16, -16, 0),
                    maxs = Vector(16, 16, 72),
                    mask = MASK_PLAYERSOLID_BRUSHONLY
                })
                assert(line.Hit and line.HitWorld and not line.HitNonWorld)
                assert(hull.Hit and hull.HitWorld and not hull.HitNonWorld)
                assert(not line.StartSolid and not hull.StartSolid)
                assert(line.Entity == Entity(0) and hull.Entity == Entity(0))
                assert(Entity(0) ~= NULL and not Entity(0):IsValid())
                assert(Entity(0):GetClass() == "worldspawn")
                assert(line.StartPos == TRACE_START and hull.StartPos == TRACE_START)
                assert(line.Normal == Vector(0, 0, -1))
                assert(hull.Normal == Vector(0, 0, -1))
                assert(line.HitNormal.z > 0.9 and hull.HitNormal.z > 0.9)
                assert(line.HitTexture == nil and line.SurfaceProps == nil and line.MatType == nil)
                return line.Fraction, line.HitPos.z, hull.Fraction, hull.HitPos.z
                """,
                sourceName: "@GMLuaUtilTrace_\(map.rawValue).lua"
            )
            XCTAssertEqual(try number(values, 0), 0.111_321_345, accuracy: 0.000_000_1)
            XCTAssertEqual(try number(values, 1), Double(spawn.z - 0.968_75), accuracy: 0.001)
            XCTAssertEqual(try number(values, 2), 0.111_321_345, accuracy: 0.000_000_1)
            XCTAssertEqual(try number(values, 3), Double(spawn.z - 0.968_75), accuracy: 0.001)
        }
    }

    private func runtimeWithWorld(
        provider: any GMLuaTraceProvider
    ) throws -> (GMLuaRuntime, GMLuaSourceRuntimeAdapter) {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            traceProvider: provider
        )
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: runtime)
        _ = try adapter.spawnNetworkableEntity(
            SourceEntity(className: "worldspawn"),
            at: 0
        )
        return (runtime, adapter)
    }

    private func assertLuaFailure(
        _ expression: String,
        contains fragment: String,
        runtime: GMLuaRuntime,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let values = try runtime.executeReturningValues(
            """
            local ok, message = pcall(function() \(expression) end)
            return ok, tostring(message)
            """,
            sourceName: "@GMLuaUtilTraceExpectedFailure.lua"
        )
        guard values.count == 2,
              case let .boolean(ok) = values[0],
              case let .string(message) = values[1] else {
            XCTFail("unexpected pcall result", file: file, line: line)
            return
        }
        XCTAssertFalse(ok, file: file, line: line)
        XCTAssertTrue(
            message.utf8String.contains(fragment),
            "expected '\(fragment)' in '\(message.utf8String)'",
            file: file,
            line: line
        )
    }

    private func luaVector(
        _ value: SourceVector3,
        typeSystem: GMLuaTypeSystem
    ) throws -> LuaValue {
        try GMLuaVectorAngle.makeNetworkVector(
            Double(value.x),
            Double(value.y),
            Double(value.z),
            typeSystem: typeSystem
        )
    }

    private func number(_ values: [LuaValue], _ index: Int) throws -> Double {
        guard values.indices.contains(index), case let .number(number) = values[index] else {
            throw LuaError.runtime("missing numeric trace result at index \(index)")
        }
        return number
    }

    private func parsePlayerStarts(_ text: String) throws -> [SourceVector3] {
        let expression = try NSRegularExpression(pattern: #"\"([^\"]+)\"\s+\"([^\"]*)\""#)
        var starts: [SourceVector3] = []
        for block in text.split(separator: "}", omittingEmptySubsequences: true) {
            let string = String(block)
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            var values: [String: String] = [:]
            for match in expression.matches(in: string, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: string),
                      let valueRange = Range(match.range(at: 2), in: string) else { continue }
                values[String(string[keyRange])] = String(string[valueRange])
            }
            guard values["classname"] == "info_player_start",
                  let origin = values["origin"] else { continue }
            let components = origin.split(whereSeparator: \.isWhitespace)
            guard components.count == 3,
                  let x = Float(components[0]),
                  let y = Float(components[1]),
                  let z = Float(components[2]) else { continue }
            starts.append(SourceVector3(x, y, z))
        }
        return starts
    }
}
