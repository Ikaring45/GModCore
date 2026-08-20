import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaResourceHandleTests: XCTestCase {
    func testPNGPixelResolverBacksMaterialAndBaseTextureWithoutFallbackColors() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        try state.execute(
            """
            local colorMeta = {}
            function Color(r, g, b, a)
                return setmetatable({ r = r, g = g, b = b, a = a or 255 }, colorMeta)
            end
            function IsColor(value)
                return type(value) == "table" and getmetatable(value) == colorMeta
            end
            """,
            sourceName: "=[synthetic Color contract]"
        )
        let registry = try GMLuaResources.install(
            into: state,
            typeSystem: typeSystem,
            realm: .client
        )

        XCTAssertFalse(registry.hasMaterialPixelResolver)
        try state.execute(
            """
            local unresolved = Material("synthetic/atlas.png", "smooth")
            assert(unresolved:GetShader() == "shader_error")
            assert(unresolved:GetTexture("$basetexture") == nil)
            assert(Material("synthetic/unparsed_vmt"):GetShader() == "shader_error")
            assert(Material("synthetic/unparsed_vmt"):GetTexture("$basetexture") == nil)
            local statusOK, statusMessage = pcall(function() return unresolved:IsError() end)
            assert(not statusOK)
            assert(string.find(statusMessage, "without authoritative asset resolution", 1, true))
            local ok, message = pcall(function() return unresolved:GetColor(0, 0) end)
            assert(not ok and string.find(message, "requires decoded image backing", 1, true))
            """,
            sourceName: "@GMLuaUnresolvedMaterialPixel.lua"
        )

        registry.setMaterialPixelResolver(SyntheticMaterialPixelResolver())
        XCTAssertTrue(registry.hasMaterialPixelResolver)
        try state.execute(
            """
            local material = Material("synthetic/atlas.png", "smooth")
            assert(not material:IsError())
            assert(material:GetShader() == "UnlitGeneric")
            assert(Material(
                "synthetic/atlas.png", "vertexlitgeneric smooth"
            ):GetShader() == "VertexLitGeneric")
            assert(material:Width() == 3 and material:Height() == 2)

            local color = material:GetColor(1.9, 1.8)
            assert(IsColor(color))
            assert(color.r == 41 and color.g == 42 and color.b == 43 and color.a == 44)

            local texture = material:GetTexture("$basetexture")
            assert(type(texture) == "ITexture")
            assert(texture == material:GetTexture("$BASETEXTURE"))
            assert(texture:GetName() == "synthetic/atlas.png")
            assert(texture:Width() == 3 and texture:Height() == 2)
            local fromTexture = texture:GetColor(2, 0)
            assert(fromTexture.r == 21 and fromTexture.g == 22)
            assert(material:GetTexture("$bumpmap") == nil)

            local ok, message = pcall(function() return material:GetColor(3, 0) end)
            assert(not ok and string.find(message, "outside 3x2", 1, true))
            """,
            sourceName: "@GMLuaResolvedMaterialPixel.lua"
        )
        XCTAssertEqual(registry.materialCount, 3)
        XCTAssertEqual(registry.textureCount, 1)

        registry.setMaterialPixelResolver(nil)
        XCTAssertFalse(registry.hasMaterialPixelResolver)
        try state.execute(
            """
            local ok, message = pcall(function()
                return Material('synthetic/atlas.png', 'smooth'):IsError()
            end)
            assert(not ok)
            assert(string.find(message, "without authoritative asset resolution", 1, true))
            """,
            sourceName: "@GMLuaDetachedMaterialPixelResolver.lua"
        )
    }

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

    func testMaterialTextureBindingsAndLogicalRenderTargetsPreserveIdentity() throws {
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

        try state.execute(
            """
            local material = Material("pp/downsample")
            assert(RT_SIZE_FULL_FRAME_BUFFER == 4)
            assert(MATERIAL_RT_DEPTH_NONE == 2)
            assert(IMAGE_FORMAT_DEFAULT == -1)
            local screen = render.GetScreenEffectTexture()
            assert(material:SetTexture("$FBTexture", screen) == nil)
            assert(material:GetTexture("$fbtexture") == screen)

            local bloom0 = render.GetBloomTex0()
            assert(type(bloom0) == "ITexture")
            assert(bloom0 == render.GetBloomTex0())
            assert(bloom0 ~= render.GetBloomTex1())
            assert(render.GetMoBlurTex0() == render.GetMoBlurTex0())
            assert(render.GetMoBlurTex0() ~= render.GetMoBlurTex1())
            assert(render.GetSuperFPTex() ~= render.GetSuperFPTex2())

            local first = GetRenderTargetEx("synthetic/history.1", 256, 128, 0, 1, 2, 3, -1)
            local second = GetRenderTargetEx("synthetic/history.2", 1024, 512, 7, 6, 5, 4, 3)
            assert(type(first) == "ITexture")
            assert(first == second)
            assert(first:GetName() == "synthetic/history")

            assert(RT_SIZE_NO_CHANGE == 0)
            assert(MATERIAL_RT_DEPTH_SEPARATE == 1)
            assert(IMAGE_FORMAT_BGRA8888 == 12)
            local simple = GetRenderTarget("GModToolgunScreen", 256, 128)
            assert(type(simple) == "ITexture")
            assert(simple == GetRenderTarget("GModToolgunScreen", 1024, 512))
            assert(simple:GetName() == "GModToolgunScreen")

            local ok, message = pcall(function()
                material:SetTexture("$detail", "not a texture")
            end)
            assert(not ok and string.find(message, "ITexture expected", 1, true))
            """,
            sourceName: "@GMLuaLogicalRenderTargets.lua"
        )

        let custom = try XCTUnwrap(
            registry.namedTextureDescriptor(name: "synthetic/history")
        )
        guard case let .renderTarget(request) = custom.kind else {
            return XCTFail("custom target did not retain its creation request")
        }
        XCTAssertEqual(request.name, "synthetic/history")
        XCTAssertEqual(request.width, 256)
        XCTAssertEqual(request.height, 128)
        XCTAssertEqual(request.sizeMode, 0)
        XCTAssertEqual(request.depthMode, 1)
        XCTAssertEqual(request.textureFlags, 2)
        XCTAssertEqual(request.renderTargetFlags, 3)
        XCTAssertEqual(request.imageFormat, -1)
        let simple = try XCTUnwrap(
            registry.namedTextureDescriptor(name: "GModToolgunScreen")
        )
        guard case let .renderTarget(simpleRequest) = simple.kind else {
            return XCTFail("GetRenderTarget did not retain its fixed-policy request")
        }
        XCTAssertEqual(simpleRequest.width, 256)
        XCTAssertEqual(simpleRequest.height, 128)
        XCTAssertEqual(simpleRequest.sizeMode, 0)
        XCTAssertEqual(simpleRequest.depthMode, 1)
        XCTAssertEqual(simpleRequest.textureFlags, 258)
        XCTAssertEqual(simpleRequest.renderTargetFlags, 0)
        XCTAssertEqual(simpleRequest.imageFormat, 12)
        XCTAssertEqual(
            registry.namedTextureDescriptor(name: "_RT_SMALLFB0")?.kind,
            .engineRenderTarget(name: "_rt_SmallFB0")
        )
        XCTAssertEqual(registry.materialCount, 1)
        XCTAssertEqual(registry.textureCount, 9)
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

    func testMaterialGetTextureReturnsNothingForAbsentOrUnresolvedBaseTexture() throws {
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
        let sourceFiles: [String: Data] = [
            "materials/synthetic/no_base.vmt": Data(
                "UnlitGeneric { \"$vertexcolor\" \"1\" }".utf8
            ),
            "materials/synthetic/missing_base.vmt": Data(
                "UnlitGeneric { \"$basetexture\" \"synthetic/not_installed\" }".utf8
            ),
        ]
        registry.setMaterialPixelResolver(GMLuaSourceMaterialResolver { logicalPath in
            sourceFiles[logicalPath]
        })

        try state.execute(
            """
            assert(Material("synthetic/not_installed"):GetTexture("$basetexture") == nil)
            assert(Material("synthetic/no_base"):GetTexture("$basetexture") == nil)
            assert(Material("synthetic/missing_base"):GetTexture("$basetexture") == nil)
            assert(Material("synthetic/missing_base"):GetTexture("$detail") == nil)
            """,
            sourceName: "@GMLuaMaterialGetTextureMissing.lua"
        )
        XCTAssertEqual(registry.textureCount, 0)
    }

    func testGameAddParticlesRetainsOrderedByteExactPCFRequestsInBothRealms() throws {
        for realm in [GMLuaRealm.server, .client] {
            let state = LuaState(output: { _ in })
            let typeSystem = try GMLuaTypeSystem.install(
                into: state,
                utilityLayer: .bundledFallback
            )
            let registry = try GMLuaResources.install(
                into: state,
                typeSystem: typeSystem,
                realm: realm
            )

            try state.execute(
                """
                assert(game.AddParticles("particles/hunter_flechette.pcf") == nil)
                game.AddParticles("particles/hunter_projectile.pcf")
                game.AddParticles("particles/hunter_flechette.pcf")
                game.AddParticles(string.char(255) .. ".pcf")
                """,
                sourceName: "@GameAddParticlesSourceShape.lua"
            )

            XCTAssertEqual(
                registry.particleManifestRequests.map(\.path),
                [
                    "particles/hunter_flechette.pcf",
                    "particles/hunter_projectile.pcf",
                    LuaString(bytes: [255, 46, 112, 99, 102]),
                ],
                realm.rawValue
            )
            XCTAssertTrue(
                registry.particleManifestRequests.allSatisfy { !$0.hasAssetBacking },
                realm.rawValue
            )
        }

        let menu = LuaState(output: { _ in })
        let menuTypes = try GMLuaTypeSystem.install(
            into: menu,
            utilityLayer: .bundledFallback
        )
        _ = try GMLuaResources.install(
            into: menu,
            typeSystem: menuTypes,
            realm: .menu
        )
        try menu.execute(
            "assert(game.AddParticles == nil and PrecacheParticleSystem == nil)"
        )
    }

    func testGameAddDecalRetainsFirstByteExactRegistrationInGameRealms() throws {
        for realm in [GMLuaRealm.server, .client] {
            let state = LuaState(output: { _ in })
            let typeSystem = try GMLuaTypeSystem.install(
                into: state,
                utilityLayer: .bundledFallback
            )
            let registry = try GMLuaResources.install(
                into: state,
                typeSystem: typeSystem,
                realm: realm
            )

            try state.execute(
                """
                assert(game.AddDecal("Eye", "decals/eye") == nil)
                game.AddDecal("Dark", "decals/dark")
                game.AddDecal("Eye", "decals/replacement-must-not-be-invented")
                game.AddDecal(string.char(255), string.char(254))
                """,
                sourceName: "@GameAddDecalSourceShape.lua"
            )

            XCTAssertEqual(
                registry.decalRegistrations.map(\.name),
                ["Eye", "Dark", LuaString(bytes: [255])],
                realm.rawValue
            )
            XCTAssertEqual(
                registry.decalRegistrations.map(\.material),
                ["decals/eye", "decals/dark", LuaString(bytes: [254])],
                realm.rawValue
            )
            XCTAssertTrue(
                registry.decalRegistrations.allSatisfy { !$0.hasAssetBacking },
                realm.rawValue
            )
        }

        let menu = LuaState(output: { _ in })
        let menuTypes = try GMLuaTypeSystem.install(
            into: menu,
            utilityLayer: .bundledFallback
        )
        _ = try GMLuaResources.install(
            into: menu,
            typeSystem: menuTypes,
            realm: .menu
        )
        try menu.execute("assert(game.AddDecal == nil)")
    }
}

private struct SyntheticMaterialPixelResolver: GMLuaMaterialPixelResolver {
    func dimensions(
        materialPath: LuaString,
        encodedParameters: LuaString?
    ) throws -> GMLuaImageDimensions? {
        guard materialPath == "synthetic/atlas.png",
              encodedParameters == "smooth" ||
                encodedParameters == "vertexlitgeneric smooth" else { return nil }
        return GMLuaImageDimensions(width: 3, height: 2)
    }

    func pixel(
        materialPath: LuaString,
        encodedParameters: LuaString?,
        x: Int,
        y: Int
    ) throws -> GMLuaRGBA8? {
        guard try dimensions(
            materialPath: materialPath,
            encodedParameters: encodedParameters
        ) != nil else { return nil }
        let base = UInt8(y * 30 + x * 10)
        return GMLuaRGBA8(
            red: base + 1,
            green: base + 2,
            blue: base + 3,
            alpha: base + 4
        )
    }
}
