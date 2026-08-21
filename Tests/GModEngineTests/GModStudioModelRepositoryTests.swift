import Foundation
import XCTest
@testable import GModGameSession
import GModEngine

final class GModStudioModelRepositoryTests: XCTestCase {
    func testExplicitDX90PathsAreCachedAndMissingModelIsInvalid() {
        let recorder = LoadRecorder(outcome: .unavailable(.missing(
            kind: .mdl,
            path: "models/props/test.mdl"
        )))
        let repository = GModStudioModelRepository { [recorder] paths, requirement in
            recorder.load(paths: paths, requirement: requirement)
        }
        let model = SourceEntityModelReference("models/props/test.mdl")

        XCTAssertEqual(repository.validation(for: model, kind: .propPhysics), .invalid)
        XCTAssertEqual(repository.validation(for: model, kind: .propPhysics), .invalid)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.paths.mdl, "models/props/test.mdl")
        XCTAssertEqual(recorder.requests.first?.paths.vvd, "models/props/test.vvd")
        XCTAssertEqual(recorder.requests.first?.paths.vtx, "models/props/test.dx90.vtx")
        XCTAssertNil(recorder.requests.first?.paths.phy)
        XCTAssertEqual(recorder.requests.first?.requirement, .render)
    }

    func testOpaquePHYRequestUsesSeparateCacheAndDoesNotBecomePropVerdict() {
        let recorder = LoadRecorder(outcome: .unavailable(.readFailed(
            kind: .phy,
            path: "models/props/test.phy",
            reason: "injected I/O failure"
        )))
        let repository = GModStudioModelRepository { [recorder] paths, requirement in
            recorder.load(paths: paths, requirement: requirement)
        }
        let model = SourceEntityModelReference("models/props/test.mdl")

        _ = repository.renderAssetWithOpaquePHY(for: model)
        _ = repository.renderAssetWithOpaquePHY(for: model)

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.paths.phy, "models/props/test.phy")
        XCTAssertEqual(
            recorder.requests.first?.requirement,
            .renderWithOpaquePHYCompanion
        )
    }

    func testReadFailureIsUnavailableAndInvalidPathDoesNotReachLoader() {
        let recorder = LoadRecorder(outcome: .unavailable(.readFailed(
            kind: .mdl,
            path: "models/props/test.mdl",
            reason: "injected"
        )))
        let repository = GModStudioModelRepository { [recorder] paths, requirement in
            recorder.load(paths: paths, requirement: requirement)
        }

        XCTAssertEqual(
            repository.validation(
                for: SourceEntityModelReference("models/props/test.mdl"),
                kind: .propPhysics
            ),
            .unavailable
        )
        _ = repository.renderAsset(for: SourceEntityModelReference("../outside.mdl"))
        XCTAssertEqual(recorder.requests.count, 1)
    }
}

private final class LoadRecorder: @unchecked Sendable {
    struct Request {
        let paths: SourceStudioModelAssetPaths
        let requirement: SourceStudioModelAssetRequirement
    }

    private let lock = NSLock()
    private let outcome: SourceStudioModelAssetLoadOutcome
    private var requestsStorage: [Request] = []

    init(outcome: SourceStudioModelAssetLoadOutcome) {
        self.outcome = outcome
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStorage
    }

    func load(
        paths: SourceStudioModelAssetPaths,
        requirement: SourceStudioModelAssetRequirement
    ) -> SourceStudioModelAssetLoadOutcome {
        lock.lock()
        requestsStorage.append(Request(paths: paths, requirement: requirement))
        lock.unlock()
        return outcome
    }
}
