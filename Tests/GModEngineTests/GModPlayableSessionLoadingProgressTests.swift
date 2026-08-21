import XCTest
import GModEngine
@testable import GModGameSession

private final class PlayableLoadingProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GModPlayableSessionLoadingProgress] = []

    func append(_ progress: GModPlayableSessionLoadingProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }

    var values: [GModPlayableSessionLoadingProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class GModPlayableSessionLoadingProgressTests: XCTestCase {
    func testRealSessionBoundariesAreDeterministicAndMonotonic() throws {
        let recorder = PlayableLoadingProgressRecorder()
        let session = try GModPlayableSession(
            configuration: .init(map: .construct),
            progress: { recorder.append($0) }
        )
        defer { _ = try? session.close() }

        let progress = recorder.values
        XCTAssertEqual(progress.map(\.stage), [
            .readingBSP,
            .parsingWorld,
            .buildingWorldGeometry,
            .preparingCollision,
            .startingServerLua,
            .loadingServerSandbox,
            .startingClientLua,
            .loadingClientSandbox,
            .preparingMaterials,
        ])
        XCTAssertEqual(
            progress.map(\.completedUnitCount),
            Array(0...8)
        )
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy {
            $0.completedUnitCount < $1.completedUnitCount
        })
        XCTAssertEqual(progress.last?.percentComplete, 80)
        XCTAssertNotEqual(progress.last?.stage, .complete)
    }

    func testOneHundredPercentRequiresResourcesThenFirstMetalFrame() {
        var state = GModPlayableSessionLoadingState()

        XCTAssertTrue(state.record(.init(stage: .preparingMaterials)))
        XCTAssertEqual(state.progress.percentComplete, 80)
        XCTAssertFalse(state.record(.init(stage: .complete)))
        XCTAssertEqual(state.progress.percentComplete, 80)

        XCTAssertTrue(state.record(.init(stage: .awaitingFirstMetalFrame)))
        XCTAssertEqual(state.progress.percentComplete, 90)
        XCTAssertFalse(state.record(.init(stage: .awaitingFirstMetalFrame)))
        XCTAssertTrue(state.record(.init(stage: .complete)))
        XCTAssertEqual(state.progress.percentComplete, 100)
        XCTAssertEqual(state.progress.fractionCompleted, 1)
        XCTAssertFalse(state.record(.init(stage: .complete)))
    }

    func testFailureRetainsLastCompletedRealStage() {
        var state = GModPlayableSessionLoadingState()
        XCTAssertTrue(state.record(.init(stage: .loadingServerSandbox)))
        let lastRealProgress = state.progress

        state.fail("sandbox fixture failed")
        XCTAssertEqual(state.failureDescription, "sandbox fixture failed")
        XCTAssertEqual(state.progress, lastRealProgress)
        XCTAssertFalse(state.record(.init(stage: .startingClientLua)))
        XCTAssertEqual(state.progress, lastRealProgress)

        state.fail("later callback must not replace the first failure")
        XCTAssertEqual(state.failureDescription, "sandbox fixture failed")
    }

    func testFirstFrameSubprogressUsesOnlyRealTextureCompletions() {
        var state = GModPlayableSessionLoadingState()
        XCTAssertTrue(state.record(.init(stage: .preparingMaterials)))
        XCTAssertTrue(state.record(.init(
            stage: .awaitingFirstMetalFrame,
            completedSubunitCount: 0,
            totalSubunitCount: 4
        )))
        XCTAssertEqual(state.progress.percentComplete, 90)

        XCTAssertTrue(state.record(.init(
            stage: .awaitingFirstMetalFrame,
            completedSubunitCount: 2,
            totalSubunitCount: 4
        )))
        XCTAssertEqual(state.progress.completedSubunitCount, 2)
        XCTAssertEqual(state.progress.totalSubunitCount, 4)
        XCTAssertEqual(state.progress.percentComplete, 95)

        XCTAssertFalse(state.record(.init(
            stage: .awaitingFirstMetalFrame,
            completedSubunitCount: 1,
            totalSubunitCount: 4
        )))
        XCTAssertTrue(state.record(.init(
            stage: .awaitingFirstMetalFrame,
            completedSubunitCount: 4,
            totalSubunitCount: 4
        )))
        XCTAssertEqual(state.progress.percentComplete, 99)
        XCTAssertLessThan(state.progress.fractionCompleted, 1)

        XCTAssertTrue(state.record(.init(stage: .complete)))
        XCTAssertEqual(state.progress.percentComplete, 100)
    }

    func testClientLanguageConfigurationPropagatesIntoRuntime() throws {
        let session = try GModPlayableSession(configuration: .init(
            map: .construct,
            languageCode: "ja",
            languagePhrases: ["garryspad.test.phrase": "日本語"]
        ))
        defer { _ = try? session.close() }

        XCTAssertEqual(
            session.clientRuntime.engineConVarCatalog?.currentValue(
                for: "gmod_language"
            ),
            "ja"
        )
        try session.clientRuntime.execute(
            "assert(GetConVar('gmod_language'):GetString() == 'ja'); " +
                "assert(language.GetPhrase('garryspad.test.phrase') == '日本語')",
            sourceName: "=(playable language propagation)"
        )
    }

    func testInvalidLanguageCodeStopsBeforeLoadingBoundaries() {
        let recorder = PlayableLoadingProgressRecorder()
        XCTAssertThrowsError(try GModPlayableSession(
            configuration: .init(languageCode: "ja/../../bad"),
            progress: { recorder.append($0) }
        )) { error in
            XCTAssertEqual(
                error as? GModPlayableSessionError,
                .invalidLanguageCode("ja/../../bad")
            )
        }
        XCTAssertEqual(recorder.values, [])
    }
}
