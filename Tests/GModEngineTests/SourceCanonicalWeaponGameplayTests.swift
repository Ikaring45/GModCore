import XCTest
import GModLua
@testable import GModEngine
@testable import GModGameSession

final class SourceCanonicalWeaponGameplayTests: XCTestCase {
    func testScriptedWeaponLifecycleInputSelectionDropAndReplication() throws {
        do {
        let harness = try makeHarness()
        defer { _ = try? harness.session.close() }
        let session = harness.session
        let player = try canonicalPlayer(in: session)

        try session.serverRuntime.execute(
            """
            WEAPON_EVENTS = {}
            local function push(name)
                WEAPON_EVENTS[#WEAPON_EVENTS + 1] = name
            end
            local function register_test_weapon(class, marker)
                weapons.Register({
                    Base = "weapon_base",
                    Primary = { Automatic = false },
                    Secondary = { Automatic = false },
                    SetupDataTables = function(self)
                        push(marker .. ":SetupDataTables")
                        self:NetworkVar("Entity", 0, "TrackedEntity")
                    end,
                    Initialize = function(self)
                        push(marker .. ":Initialize")
                        assert(self:GetOwner() == Player(\(session.configuration.playerUserID)))
                        self:SetTrackedEntity(self:GetOwner())
                    end,
                    Equip = function(self, owner)
                        push(marker .. ":Equip")
                        assert(owner == self:GetOwner())
                    end,
                    Holster = function(self)
                        push(marker .. ":Holster")
                        return true
                    end,
                    Deploy = function(self)
                        push(marker .. ":Deploy")
                        return true
                    end,
                    Think = function(self) push(marker .. ":Think") end,
                    PrimaryAttack = function(self) push(marker .. ":PrimaryAttack") end,
                    SecondaryAttack = function(self) push(marker .. ":SecondaryAttack") end,
                    Reload = function(self)
                        assert(self:GetOwner():KeyPressed(IN_RELOAD))
                        push(marker .. ":Reload")
                    end,
                    OnDrop = function(self)
                        assert(not IsValid(self:GetOwner()))
                        push(marker .. ":OnDrop")
                    end
                }, class)
            end
            register_test_weapon("weapon_vertical_a", "a")
            register_test_weapon("weapon_vertical_b", "b")
            local ply = Player(\(session.configuration.playerUserID))
            ply:Give("weapon_vertical_a")
            ply:SelectWeapon("weapon_vertical_a")
            """,
            sourceName: "=(register canonical weapon gameplay fixture)"
        )

        let initial = try runWeaponTick(
            harness,
            player: player.identity,
            buttons: []
        )
        XCTAssertEqual(initial.failures, [])
        XCTAssertEqual(initial.newlyInitializedWeapons.count, 1)
        XCTAssertEqual(initial.selectionTransitionCount, 1)
        XCTAssertTrue(initial.invocations.contains(where: {
            $0.invocation == .setupDataTables
        }))
        XCTAssertTrue(initial.invocations.contains(where: {
            $0.invocation == .initialize
        }))
        XCTAssertTrue(initial.invocations.contains(where: {
            $0.invocation == .deploy
        }))

        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            assert(ply:GetActiveWeapon():GetOwner() == ply)
            assert(ply:GetActiveWeapon():GetTrackedEntity() == ply)
            """,
            sourceName: "=(canonical Weapon owner and Entity NetworkVar)"
        )
        let serverA = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.className == "weapon_vertical_a"
            }
        )
        XCTAssertEqual(serverA.weaponEntityNetworkVariables, [player.identity])
        let clientA = try XCTUnwrap(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == serverA.identity
            }
        )
        XCTAssertEqual(clientA.weaponEntityNetworkVariables, [player.identity])

        let primary = try runWeaponTick(
            harness,
            player: player.identity,
            buttons: [.attack]
        )
        XCTAssertEqual(primary.failures, [])
        XCTAssertEqual(primary.invocations.filter {
            $0.invocation == .primaryAttack
        }.count, 1)
        let heldPrimary = try runWeaponTick(
            harness,
            player: player.identity,
            buttons: [.attack]
        )
        XCTAssertFalse(heldPrimary.invocations.contains(where: {
            $0.invocation == .primaryAttack
        }))
        _ = try runWeaponTick(harness, player: player.identity, buttons: [])
        let secondary = try runWeaponTick(
            harness,
            player: player.identity,
            buttons: [.attack2]
        )
        XCTAssertEqual(secondary.failures, [])
        XCTAssertTrue(secondary.invocations.contains(where: {
            $0.invocation == .secondaryAttack
        }))
        _ = try runWeaponTick(harness, player: player.identity, buttons: [])
        let reload = try runWeaponTick(
            harness,
            player: player.identity,
            buttons: [.reload]
        )
        XCTAssertEqual(reload.failures, [])
        XCTAssertTrue(reload.invocations.contains(where: {
            $0.invocation == .reload
        }))

        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            ply:Give("weapon_vertical_b")
            ply:SelectWeapon("weapon_vertical_b")
            """,
            sourceName: "=(canonical Weapon switch fixture)"
        )
        let switched = try runWeaponTick(
            harness,
            player: player.identity,
            buttons: []
        )
        XCTAssertEqual(switched.failures, [])
        XCTAssertEqual(switched.newlyInitializedWeapons.count, 1)
        XCTAssertEqual(switched.selectionTransitionCount, 1)
        XCTAssertTrue(switched.invocations.contains(where: {
            $0.className == "weapon_vertical_a" && $0.invocation == .holster
        }))
        XCTAssertTrue(switched.invocations.contains(where: {
            $0.className == "weapon_vertical_b" && $0.invocation == .deploy
        }))

        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            local weapon = ply:GetActiveWeapon()
            assert(weapon:GetClass() == "weapon_vertical_b")
            ply:DropWeapon(weapon, Vector(100, 200, 300), Vector(4, 5, 6))
            assert(not ply:HasWeapon("weapon_vertical_b"))
            assert(not IsValid(weapon:GetOwner()))
            """,
            sourceName: "=(canonical Player DropWeapon)"
        )
        let afterDrop = try runWeaponTick(
            harness,
            player: player.identity,
            buttons: []
        )
        XCTAssertEqual(afterDrop.failures, [])

        let droppedServer = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.className == "weapon_vertical_b"
            }
        )
        XCTAssertEqual(droppedServer.transform.origin, SourceVector3(100, 200, 300))
        XCTAssertEqual(droppedServer.motion.linearVelocity, SourceVector3(4, 5, 6))
        let serverPlayerAfterDrop = try canonicalPlayer(in: session)
        XCTAssertNil(serverPlayerAfterDrop.weaponInventory.weapon(
            className: "weapon_vertical_b"
        ))
        XCTAssertEqual(
            serverPlayerAfterDrop.weaponInventory.activeWeapon,
            serverA.identity
        )
        let droppedClient = try XCTUnwrap(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == droppedServer.identity
            }
        )
        XCTAssertEqual(droppedClient, droppedServer)
        try session.clientRuntime.execute(
            """
            local ply = LocalPlayer()
            assert(not ply:HasWeapon("weapon_vertical_b"))
            """,
            sourceName: "=(CLIENT replicated canonical DropWeapon)"
        )
        try session.serverRuntime.execute(
            """
            local expected = {
                "a:SetupDataTables", "a:Initialize", "a:Equip", "a:Deploy",
                "a:Think", "a:Think", "a:PrimaryAttack", "a:Think", "a:Think",
                "a:Think", "a:SecondaryAttack", "a:Think", "a:Think", "a:Reload",
                "b:SetupDataTables", "b:Initialize", "b:Equip", "a:Holster",
                "b:Deploy", "b:Think", "b:OnDrop", "b:Holster", "a:Deploy",
                "a:Think"
            }
            assert(#WEAPON_EVENTS == #expected,
                "count " .. #WEAPON_EVENTS .. " != " .. #expected .. ": " ..
                table.concat(WEAPON_EVENTS, " | "))
            for index, value in ipairs(expected) do
                assert(WEAPON_EVENTS[index] == value,
                    index .. ": " .. tostring(WEAPON_EVENTS[index]) .. " != " .. value)
            end
            """,
            sourceName: "=(canonical Weapon lifecycle event order)"
        )
        } catch let raised as LuaRaisedError {
            XCTFail("canonical Weapon lifecycle Lua stop: \(raised.value.printable)")
        }
    }

    func testOriginalToolgunRunsStockRemoverPrimarySecondaryReloadPath() throws {
        let harness = try makeHarness()
        defer { _ = try? harness.session.close() }
        let session = harness.session
        let player = try canonicalPlayer(in: session)

        try session.clientRuntime.execute(
            "RunConsoleCommand('gmod_toolmode', 'remover')",
            sourceName: "=(select stock remover tool)"
        )
        XCTAssertEqual(
            session.clientRuntime.conVarRegistry?.stringValue(for: "gmod_toolmode"),
            "remover"
        )
        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            ply:Give("gmod_tool")
            ply:SelectWeapon("gmod_tool")
            """,
            sourceName: "=(give original stock gmod_tool)"
        )

        let primary = try runWeaponTick(
            harness,
            player: player.identity,
            buttons: [.attack]
        )
        XCTAssertEqual(primary.failures, [])
        XCTAssertTrue(primary.invocations.contains(where: {
            $0.className == "gmod_tool" && $0.invocation == .setupDataTables
        }))
        XCTAssertTrue(primary.invocations.contains(where: {
            $0.className == "gmod_tool" && $0.invocation == .initialize
        }))
        XCTAssertTrue(primary.invocations.contains(where: {
            $0.className == "gmod_tool" && $0.invocation == .think
        }))
        XCTAssertTrue(primary.invocations.contains(where: {
            $0.className == "gmod_tool" && $0.invocation == .primaryAttack
        }))

        _ = try runWeaponTick(harness, player: player.identity, buttons: [])
        let secondary = try runWeaponTick(
            harness,
            player: player.identity,
            buttons: [.attack2]
        )
        XCTAssertEqual(secondary.failures, [])
        XCTAssertTrue(secondary.invocations.contains(where: {
            $0.invocation == .secondaryAttack
        }))
        _ = try runWeaponTick(harness, player: player.identity, buttons: [])
        let reload = try runWeaponTick(
            harness,
            player: player.identity,
            buttons: [.reload]
        )
        XCTAssertEqual(reload.failures, [])
        XCTAssertTrue(reload.invocations.contains(where: {
            $0.invocation == .reload
        }))
    }

    func testInitializationAssignsOnlyValidatorAcceptedSWEPWorldModel() throws {
        let probe = CanonicalWeaponModelValidationProbe()
        let harness = try makeHarness(modelValidator: { model, kind in
            probe.validate(model, kind: kind)
        })
        defer { _ = try? harness.session.close() }
        let session = harness.session
        let player = try canonicalPlayer(in: session)

        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            ply:Give("gmod_tool")
            ply:SelectWeapon("gmod_tool")
            """,
            sourceName: "=(give validated WorldModel fixture)"
        )
        let report = try runWeaponTick(
            harness,
            player: player.identity,
            buttons: []
        )

        XCTAssertEqual(report.failures, [])
        let serverWeapon = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.className == "gmod_tool"
            }
        )
        XCTAssertEqual(
            serverWeapon.model,
            SourceEntityModelReference("models/weapons/w_toolgun.mdl")
        )
        XCTAssertTrue(probe.requests.contains(CanonicalWeaponModelValidationProbe
            .Request(
                path: "models/weapons/w_toolgun.mdl",
                kind: .weapon
            )))
        XCTAssertEqual(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == serverWeapon.identity
            }?.model,
            serverWeapon.model
        )
    }

    private struct Harness {
        let session: GModPlayableSession
    }

    private func makeHarness(
        modelValidator: SourceCanonicalModelValidator? = nil
    ) throws -> Harness {
        let session = try GModPlayableSession(
            configuration: .init(),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil,
            canonicalModelValidator: modelValidator
        )
        return Harness(session: session)
    }

    private func canonicalPlayer(
        in session: GModPlayableSession
    ) throws -> SourceCanonicalEntitySnapshot {
        try XCTUnwrap(session.sourceAdapter.canonicalEntitySnapshots.first {
            $0.kind == .player
        })
    }

    private func runWeaponTick(
        _ harness: Harness,
        player _: SourceCanonicalEntityIdentity,
        buttons: SourceInputButtons
    ) throws -> SourceCanonicalWeaponGameplayTickReport {
        let sessionReport = try harness.session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: buttons)
        )
        XCTAssertEqual(sessionReport.actionFailures, [])
        return sessionReport.weaponGameplay
    }
}

private final class CanonicalWeaponModelValidationProbe: @unchecked Sendable {
    struct Request: Equatable {
        let path: String
        let kind: SourceCanonicalEntityKind
    }

    private let lock = NSLock()
    private var requestsStorage: [Request] = []

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStorage
    }

    func validate(
        _ model: SourceEntityModelReference,
        kind: SourceCanonicalEntityKind
    ) -> SourceCanonicalModelValidation {
        lock.lock()
        requestsStorage.append(Request(path: model.path, kind: kind))
        lock.unlock()
        return model.path == "models/weapons/w_toolgun.mdl" && kind == .weapon
            ? .valid
            : .invalid
    }
}
