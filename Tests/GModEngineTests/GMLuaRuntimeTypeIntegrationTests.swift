import Foundation
import XCTest
@testable import GModEngine
import GModLua

final class GMLuaRuntimeTypeIntegrationTests: XCTestCase {
    func testRuntimeInstallsNativeTypeABIBeforeSyntheticUtilityCapture() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })

        try runtime.execute(
            """
            assert(type(FindMetaTable) == "function")
            assert(type(RegisterMetaTable) == "function")
            assert(FindMetaTable("Entity").MetaID == TYPE_ENTITY)
            assert(FindMetaTable("Player").MetaBaseClass == FindMetaTable("Entity"))
            assert(type(NULL) == "userdata")
            assert(TypeID == nil and isentity == nil)
            assert(type(Vector) == "function" and type(Angle) == "function")
            assert(type(CreateConVar) == "function")
            """,
            sourceName: "=(runtime native type ABI preflight)"
        )

        for (name, expected) in GMLuaTypeID.constants {
            guard case let .number(actual) = runtime.state.getGlobal(name) else {
                return XCTFail("missing runtime type constant \(name)")
            }
            XCTAssertEqual(actual, Double(expected), name)
        }

        let typeSystem = try XCTUnwrap(runtime.typeSystem)
        let nullObject = try XCTUnwrap(
            GMLuaTypeSystem.typedObject(from: runtime.state.getGlobal("NULL"))
        )
        XCTAssertEqual(nullObject.metaName, "Entity")
        XCTAssertFalse(nullObject.isValid)

        let player = try typeSystem.makeObject(metaName: "Player")
        runtime.state.setGlobal("TEST_PLAYER", value: player)
        try runtime.execute("assert(type(TEST_PLAYER) == 'userdata')")

        try runtime.execute(
            try syntheticCaptureSource(),
            sourceName: "@SyntheticTypeCapture.lua"
        )
        try runtime.execute(
            """
            local name, base = SyntheticCapturedUserdataDescriptor(TEST_PLAYER)
            assert(name == "Player" and base == "Entity")
            """
        )

        // The standalone fallback represents the post-capture public utility
        // behavior without embedding any proprietary game source.
        try typeSystem.installFallbackUtilities()
        try runtime.execute(
            """
            assert(type(TEST_PLAYER) == "Player")
            assert(TypeID(TEST_PLAYER) == TYPE_ENTITY)
            assert(isentity(TEST_PLAYER) and IsEntity(TEST_PLAYER))
            assert(IsValid(TEST_PLAYER))
            """
        )
    }

    func testDiscoveryModeReusesNativeMetatablesAndCanonicalNULL() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .discovery
        )

        try runtime.execute(
            """
            assert(FindMetaTable("Entity").MetaID == TYPE_ENTITY)
            assert(FindMetaTable("Vector").MetaID == TYPE_VECTOR)
            assert(type(NULL) == "userdata")
            assert(type(Entity(0)) == "userdata")
            assert(Entity(0) == NULL and not Entity(0):IsValid())
            assert(type(Vector) == "function" and type(Angle) == "function")
            """,
            sourceName: "=(discovery type ABI preflight)"
        )
        let nullObject = try XCTUnwrap(
            GMLuaTypeSystem.typedObject(from: runtime.state.getGlobal("NULL"))
        )
        XCTAssertEqual(nullObject.metaName, "Entity")
        XCTAssertFalse(nullObject.isValid)
    }

    func testTypeInstallerFailureSurfacesAtEveryExecutionBoundary() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            typeSystemInstaller: { _ in throw InjectedInstallationError.sentinel }
        )

        XCTAssertThrowsError(try runtime.execute("RAN = true")) { error in
            guard case InjectedInstallationError.sentinel = error else {
                return XCTFail("unexpected bootstrap error: \(error)")
            }
        }
        XCTAssertThrowsError(try runtime.executeReturningValues("return 1")) { error in
            guard case InjectedInstallationError.sentinel = error else {
                return XCTFail("unexpected bootstrap error: \(error)")
            }
        }
        XCTAssertThrowsError(try runtime.loadFile("anything.lua")) { error in
            guard case InjectedInstallationError.sentinel = error else {
                return XCTFail("unexpected bootstrap error: \(error)")
            }
        }
        guard case .nilValue = runtime.state.getGlobal("RAN") else {
            return XCTFail("Lua executed despite a failed type-system bootstrap")
        }
    }

    private func syntheticCaptureSource() throws -> String {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaSyntheticTypeCapture",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaSyntheticTypeCapture",
                withExtension: "lua"
            )
        )
        return try String(contentsOf: fixtureURL, encoding: .utf8)
    }
}

private enum InjectedInstallationError: Error {
    case sentinel
}
