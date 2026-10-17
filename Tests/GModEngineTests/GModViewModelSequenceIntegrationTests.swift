import XCTest
@testable import GModEngine
@testable import GModGameSession

final class GModViewModelSequenceIntegrationTests: XCTestCase {
    func testResolvedLookupDrivesCanonicalSequenceDurationAndClientFIFO() throws {
        let session = try GModPlayableSession(configuration: .init(), logger: { _, _ in })
        defer { _ = try? session.close() }
        session.serverRuntime.viewModelSequenceResolver = { model, query in
            guard model.path == "models/weapons/c_sequence_probe.mdl" else { return nil }
            switch query {
            case .name("draw"), .index(3):
                return .init(index: 3, name: "draw", duration: 0.75)
            default: return nil
            }
        }
        try session.serverRuntime.execute("""
            weapons.Register({ Base = 'weapon_base', ViewModel = 'models/weapons/c_sequence_probe.mdl',
                WorldModel = '', ViewModelFOV = 62 }, 'weapon_sequence_probe')
            local ply = Player(1)
            assert(IsValid(ply:Give('weapon_sequence_probe')))
            ply:SelectWeapon('weapon_sequence_probe')
            """)
        _ = try session.runFixedTick()
        try session.serverRuntime.execute("""
            local vm = Player(1):GetViewModel()
            local index, duration = vm:LookupSequence('draw')
            assert(index == 3 and duration == 0.75)
            vm:SendViewModelMatchingSequence(index)
            assert(vm:GetSequence() == 3)
            assert(vm:SequenceDuration() == 0.75)
            assert(Player(1):GetActiveWeapon():GetSequenceName(3) == 'draw')
            local missing, missingDuration = vm:LookupSequence('not_authored')
            assert(missing == -1 and missingDuration == 0)
            """)
        try session.clientRuntime.execute("assert(LocalPlayer():GetViewModel():GetSequence() ~= 3)")
        _ = try session.runFixedTick()
        try session.clientRuntime.execute("""
            local vm = LocalPlayer():GetViewModel()
            assert(vm:GetSequence() == 3)
            assert(vm:SequenceDuration() == 0.75)
            assert(not pcall(vm.SendViewModelMatchingSequence, vm, 3))
            """)
        _ = try session.close()
        XCTAssertNil(session.serverRuntime.viewModelSequenceResolver)
        XCTAssertNil(session.clientRuntime.viewModelSequenceResolver)
    }
}
