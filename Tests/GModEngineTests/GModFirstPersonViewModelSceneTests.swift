import Foundation
import GModEngine
@testable import GModGameSession
import XCTest

final class GModFirstPersonViewModelSceneTests: XCTestCase {
    func testProjectsCanonicalActiveWeaponUsingExactSWEPViewModel() throws {
        let resolver = ViewModelResolverProbe()
        let projector = GModFirstPersonViewModelSceneProjector(
            resolver: resolver
        )
        let weapon = weaponSnapshot(index: 18, revision: 4)
        let player = playerSnapshot(index: 1, activeWeapon: weapon)
        let definition = GMLuaScriptedWeaponRenderDefinition(
            className: "gmod_tool",
            viewModel: SourceEntityModelReference(
                "models/weapons/c_toolgun.mdl"
            ),
            worldModel: SourceEntityModelReference(
                "models/weapons/w_toolgun.mdl"
            ),
            viewModelFieldOfViewDegrees: 62
        )

        XCTAssertTrue(try projector.update(
            clientEntities: [player, weapon],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 7),
            definitionResolver: { className in
                XCTAssertEqual(className, "gmod_tool")
                return definition
            }
        ))

        let scene = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        XCTAssertEqual(scene.status, .available)
        let projection = try XCTUnwrap(scene.projection)
        XCTAssertEqual(projection.playerIdentity, player.identity)
        XCTAssertEqual(projection.weaponIdentity, weapon.identity)
        XCTAssertEqual(projection.sourceWeaponRevision, 4)
        XCTAssertEqual(projection.viewModel, definition.viewModel)
        XCTAssertEqual(projection.worldModel, definition.worldModel)
        XCTAssertEqual(projection.viewModelFieldOfViewDegrees, 62)
        XCTAssertEqual(
            projection.resource.id.normalizedModelPath,
            "models/weapons/c_toolgun.mdl"
        )
        XCTAssertEqual(resolver.requests, [ViewModelResolverProbe.Request(
            model: "models/weapons/c_toolgun.mdl",
            bodyValue: 0,
            skinFamilyIndex: 0
        )])
    }

    func testNoActiveWeaponPublishesClearWithoutResolvingDefinitionOrModel() throws {
        let resolver = ViewModelResolverProbe()
        let projector = GModFirstPersonViewModelSceneProjector(
            resolver: resolver
        )
        let weapon = weaponSnapshot(index: 18, revision: 1)
        let activePlayer = playerSnapshot(index: 1, activeWeapon: weapon)
        _ = try projector.update(
            clientEntities: [activePlayer, weapon],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 1),
            definitionResolver: { _ in self.definition() }
        )
        let first = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        var definitionCalls = 0

        XCTAssertTrue(try projector.update(
            clientEntities: [playerSnapshot(index: 1, activeWeapon: nil)],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 2),
            definitionResolver: { _ in
                definitionCalls += 1
                return self.definition()
            }
        ))
        let cleared = try XCTUnwrap(projector.snapshot(
            ifChangedFrom: first.revision
        ))
        XCTAssertNil(cleared.projection)
        XCTAssertEqual(
            cleared.status,
            .unavailableNoActiveWeapon(activePlayer.identity)
        )
        XCTAssertEqual(definitionCalls, 0)
        XCTAssertEqual(resolver.requests.count, 1)
    }

    func testStudioFailureNeverCreatesPlaceholderProjection() throws {
        let failure = GModStudioRenderableModelResolutionFailure.cache(
            .invalidModelPath("models/weapons/c_missing.mdl")
        )
        let resolver = ViewModelResolverProbe(failure: failure)
        let projector = GModFirstPersonViewModelSceneProjector(
            resolver: resolver
        )
        let weapon = weaponSnapshot(index: 22, revision: 1)
        let player = playerSnapshot(index: 1, activeWeapon: weapon)

        XCTAssertTrue(try projector.update(
            clientEntities: [player, weapon],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 1),
            definitionResolver: { _ in
                GMLuaScriptedWeaponRenderDefinition(
                    className: "gmod_tool",
                    viewModel: SourceEntityModelReference(
                        "models/weapons/c_missing.mdl"
                    ),
                    worldModel: nil,
                    viewModelFieldOfViewDegrees: 62
                )
            }
        ))
        let scene = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        XCTAssertNil(scene.projection)
        XCTAssertEqual(
            scene.status,
            .unavailableStudio(
                model: SourceEntityModelReference(
                    "models/weapons/c_missing.mdl"
                ),
                failure: failure
            )
        )
    }

    func testFullEHANDLEMismatchDoesNotSelectRecycledWeaponIndex() throws {
        let resolver = ViewModelResolverProbe()
        let projector = GModFirstPersonViewModelSceneProjector(
            resolver: resolver
        )
        let owned = weaponSnapshot(index: 18, serial: 2, revision: 1)
        let recycled = weaponSnapshot(index: 18, serial: 3, revision: 1)
        let player = playerSnapshot(index: 1, activeWeapon: owned)

        _ = try projector.update(
            clientEntities: [player, recycled],
            localPlayerEntryIndex: 1,
            cursor: cursor(sequence: 1),
            definitionResolver: { _ in self.definition() }
        )
        let scene = try XCTUnwrap(projector.snapshot(ifChangedFrom: nil))
        XCTAssertNil(scene.projection)
        XCTAssertEqual(
            scene.status,
            .unavailableActiveWeaponSnapshot(owned.identity)
        )
        XCTAssertEqual(resolver.requests, [])
    }

    private func definition() -> GMLuaScriptedWeaponRenderDefinition {
        GMLuaScriptedWeaponRenderDefinition(
            className: "gmod_tool",
            viewModel: SourceEntityModelReference(
                "models/weapons/c_toolgun.mdl"
            ),
            worldModel: SourceEntityModelReference(
                "models/weapons/w_toolgun.mdl"
            ),
            viewModelFieldOfViewDegrees: 62
        )
    }

    private func cursor(sequence: UInt64) -> SourceEntityReplicationCursor {
        SourceEntityReplicationCursor(
            connectionGeneration: SourceEntityReplicationConnectionGeneration(
                rawValue: 1
            ),
            sequence: sequence
        )
    }

    private func playerSnapshot(
        index: Int,
        activeWeapon: SourceCanonicalEntitySnapshot?
    ) -> SourceCanonicalEntitySnapshot {
        let inventory: SourceCanonicalWeaponInventory
        if let activeWeapon {
            inventory = SourceCanonicalWeaponInventory(
                weapons: [SourceCanonicalWeaponRecord(
                    identity: activeWeapon.identity,
                    className: activeWeapon.className
                )],
                activeWeapon: activeWeapon.identity
            )
        } else {
            inventory = SourceCanonicalWeaponInventory()
        }
        return SourceCanonicalEntitySnapshot(
            identity: identity(index: index, serial: 1),
            kind: .player,
            className: SourceCanonicalEntityKind.player.className,
            transform: .identity,
            motion: SourceEntityMotionState(),
            model: nil,
            solidType: .boundingBox,
            moveType: .walk,
            lifecycle: .active,
            isNetworkable: true,
            revision: 1,
            weaponInventory: inventory
        )
    }

    private func weaponSnapshot(
        index: Int,
        serial: Int = 1,
        revision: UInt64
    ) -> SourceCanonicalEntitySnapshot {
        SourceCanonicalEntitySnapshot(
            identity: identity(index: index, serial: serial),
            kind: .weapon,
            className: "gmod_tool",
            transform: .identity,
            motion: SourceEntityMotionState(),
            model: SourceEntityModelReference(
                "models/weapons/w_toolgun.mdl"
            ),
            solidType: .none,
            moveType: .none,
            lifecycle: .active,
            isNetworkable: true,
            revision: revision
        )
    }

    private func identity(
        index: Int,
        serial: Int
    ) -> SourceCanonicalEntityIdentity {
        SourceCanonicalEntityIdentity(handle: SourceBaseHandle(
            entryIndex: index,
            serialNumber: serial
        ))
    }
}

private final class ViewModelResolverProbe:
    GModStudioRenderableModelResolving,
    @unchecked Sendable
{
    struct Request: Equatable {
        let model: String
        let bodyValue: Int
        let skinFamilyIndex: Int
    }

    private let lock = NSLock()
    private let failure: GModStudioRenderableModelResolutionFailure?
    private var requestsStorage: [Request] = []

    init(failure: GModStudioRenderableModelResolutionFailure? = nil) {
        self.failure = failure
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStorage
    }

    func resolve(
        model: SourceEntityModelReference,
        bodyValue: Int,
        skinFamilyIndex: Int
    ) -> GModStudioRenderableModelResolution {
        lock.lock()
        requestsStorage.append(Request(
            model: model.path,
            bodyValue: bodyValue,
            skinFamilyIndex: skinFamilyIndex
        ))
        lock.unlock()
        if let failure { return .failed(failure) }
        let normalized = model.path.lowercased()
        let checksum: Int32 = 0x1020_3040
        return .resolved(GModStudioRenderableModelResource(
            id: GModStudioRenderableModelResourceID(
                normalizedModelPath: normalized,
                checksum: checksum,
                bodyValue: bodyValue,
                skinFamilyIndex: skinFamilyIndex
            ),
            model: GModStudioRenderableModelSnapshot(
                checksum: checksum,
                modelName: normalized,
                lodIndex: 0,
                bodyValue: bodyValue,
                skinFamilyIndex: skinFamilyIndex,
                vertices: [
                    GModDynamicModelVertex(
                        position: SourceVector3(0, 0, 0),
                        normal: SourceVector3(0, 0, 1),
                        textureCoordinate: SourceStudioTextureCoordinate(
                            u: 0,
                            v: 0
                        )
                    ),
                ],
                indices: [],
                drawRanges: []
            )
        ))
    }
}
