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
                return .init(index: 3, name: "draw", duration: 0.75, frameCount: 31)
            default: return nil
            }
        }
        // This synthetic SWEP is registered in both realms, like a shipped
        // shared weapon file. SERVER dynamic registration is not a Lua-file
        // transport and must not silently install CLIENT definitions.
        try session.clientRuntime.execute("""
            weapons.Register({ Base = 'weapon_base', ViewModel = 'models/weapons/c_sequence_probe.mdl',
                WorldModel = '', ViewModelFOV = 62 }, 'weapon_sequence_probe')
            """)
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
            assert(vm:GetCycle() > 0 and vm:GetCycle() < 1)
            """)
        let renderFrame = try XCTUnwrap(session.clientFirstPersonRenderFrame())
        let beforePause = try XCTUnwrap(renderFrame.animation)
        XCTAssertEqual(beforePause.animationFrameCount, 31)
        let sample = try XCTUnwrap(renderFrame.viewModelAnimationSelection())
        XCTAssertEqual(sample.sequenceIndex, 3)
        XCTAssertEqual(Float(sample.frame) + sample.fraction.value,
                       beforePause.animationCycle * 30, accuracy: 0.00001)
        try session.serverRuntime.execute("Player(1):GetViewModel():SetPlaybackRate(0)")
        _ = try session.runFixedTick()
        _ = try session.runFixedTick()
        let paused = try XCTUnwrap(session.clientFirstPersonRenderFrame()?.animation)
        XCTAssertEqual(paused.animationCycle, beforePause.animationCycle)
        try session.serverRuntime.execute("Player(1):GetViewModel():SetPlaybackRate(2)")
        _ = try session.runFixedTick()
        let resumed = try XCTUnwrap(session.clientFirstPersonRenderFrame()?.animation)
        XCTAssertGreaterThan(resumed.animationCycle, paused.animationCycle)
        try session.serverRuntime.execute("Player(1):GetViewModel():SendViewModelMatchingSequence(3)")
        _ = try session.runFixedTick()
        let restarted = try XCTUnwrap(session.clientFirstPersonRenderFrame()?.animation)
        XCTAssertLessThan(restarted.animationCycle, resumed.animationCycle)
        _ = try session.close()
        XCTAssertNil(session.serverRuntime.viewModelSequenceResolver)
        XCTAssertNil(session.clientRuntime.viewModelSequenceResolver)
    }
}
