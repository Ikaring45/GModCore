import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaResourceHandleTests: XCTestCase {
    func testTypedCachedUnresolvedResourceDescriptors() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaResourceHandleRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaResourceHandleRegression",
                withExtension: "lua"
            )
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaResources.install(
            into: state,
            typeSystem: typeSystem,
            realm: .client
        )

        try state.execute(source, sourceName: "@GLuaResourceHandleRegression.lua")
        XCTAssertEqual(registry.materialCount, 3)
        XCTAssertEqual(registry.textureCount, 2)
        XCTAssertEqual(registry.precachedSoundNames, ["ui/synthetic.wav"])
        XCTAssertEqual(registry.precachedModelNames, [])
        XCTAssertEqual(registry.precachedParticleSystemNames, ["synthetic_particle"])

        let material = try XCTUnwrap(
            registry.materialDescriptor(path: "pp/copy")
        )
        XCTAssertEqual(material.resolution, .unresolved)
        XCTAssertFalse(material.hasGPUBacking)

        let texture = try XCTUnwrap(
            registry.screenEffectTextureDescriptor(index: 0)
        )
        XCTAssertEqual(texture.name, "_rt_fullframefb")
        XCTAssertEqual(texture.kind, .screenEffect(index: 0))
        XCTAssertEqual(texture.resolution, .unresolved)
        XCTAssertFalse(texture.hasGPUBacking)
        guard case .boolean(true) = state.getGlobal("GLUA_RESOURCE_HANDLE_REGRESSION_OK") else {
            return XCTFail("resource fixture did not reach its success sentinel")
        }
    }

    func testRegistriesAndUserdataIdentityAreStateLocal() throws {
        func makeState() throws -> (LuaState, GMLuaResourceRegistry) {
            let state = LuaState(output: { _ in })
            let typeSystem = try GMLuaTypeSystem.install(
                into: state,
                utilityLayer: .bundledFallback
            )
            let registry = try GMLuaResources.install(
                into: state,
                typeSystem: typeSystem,
                realm: .client
            )
            return (state, registry)
        }

        let (first, firstRegistry) = try makeState()
        let (second, secondRegistry) = try makeState()
        try first.execute("FIRST = Material('pp/add')")
        try second.execute("SECOND = Material('pp/add')")

        XCTAssertEqual(firstRegistry.materialCount, 1)
        XCTAssertEqual(secondRegistry.materialCount, 1)
        guard case let .userdata(firstValue) = first.getGlobal("FIRST"),
              case let .userdata(secondValue) = second.getGlobal("SECOND") else {
            return XCTFail("Material did not return userdata")
        }
        XCTAssertFalse(firstValue === secondValue)
    }

    func testRuntimeRealmSurfaceMatchesDocumentedBoundary() throws {
        for realm in [GMLuaRealm.client, .menu] {
            let runtime = GMLuaRuntime(
                realm: realm,
                logger: { _ in },
                bootstrapMode: .strict
            )
            try runtime.execute(
                """
                local material = Material("pp/sub")
                assert(getmetatable(material).MetaName == "IMaterial")
                local texture = render.GetScreenEffectTexture(1)
                assert(getmetatable(texture).MetaName == "ITexture")
                assert(texture:GetName() == "_rt_fullframefb1")
                """,
                sourceName: "@GMLuaResourceRealmBootstrap.lua"
            )
            XCTAssertNotNil(runtime.resourceRegistry)
        }

        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try server.execute(
            """
            assert(getmetatable(Material("pp/copy")).MetaName == "IMaterial")
            assert(render == nil)
            """,
            sourceName: "@GMLuaResourceServerBootstrap.lua"
        )
        XCTAssertNotNil(server.resourceRegistry)
        try server.execute(
            """
            util.PrecacheSound("server/synthetic.wav")
            util.PrecacheModel("models/server_synthetic.mdl")
            PrecacheParticleSystem("server_synthetic_particle")
            """,
            sourceName: "@GMLuaServerPrecache.lua"
        )
        XCTAssertEqual(server.resourceRegistry?.precachedSoundNames, ["server/synthetic.wav"])
        XCTAssertEqual(
            server.resourceRegistry?.precachedModelNames,
            ["models/server_synthetic.mdl"]
        )
        XCTAssertEqual(
            server.resourceRegistry?.precachedParticleSystemNames,
            ["server_synthetic_particle"]
        )
    }
}
