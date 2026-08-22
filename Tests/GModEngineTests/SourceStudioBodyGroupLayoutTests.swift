import XCTest
@testable import GModEngine

final class SourceStudioBodyGroupLayoutTests: XCTestCase {
    func testQueriesAndSingleGroupMutationUseStudioBases() throws {
        let layout = try SourceStudioBodyGroupLayout(bodyParts: [
            .init(modelSelectionBase: 1, modelCount: 2),
            .init(modelSelectionBase: 2, modelCount: 3),
            .init(modelSelectionBase: 6, modelCount: 1),
        ])

        XCTAssertEqual(layout.bodyGroupCount, 3)
        XCTAssertEqual(
            try layout.selection(forBodyGroupID: 0, bodyValue: 5),
            1
        )
        XCTAssertEqual(
            try layout.selection(forBodyGroupID: 1, bodyValue: 5),
            2
        )
        XCTAssertEqual(
            try layout.selection(forBodyGroupID: 2, bodyValue: 5),
            0
        )
        XCTAssertEqual(
            try layout.selection(forBodyGroupID: -1, bodyValue: 5),
            0
        )
        XCTAssertEqual(
            try layout.selection(forBodyGroupID: 8, bodyValue: 5),
            0
        )

        XCTAssertEqual(
            try layout.bodyValue(
                settingBodyGroupID: 0,
                to: 0,
                currentBodyValue: 5
            ),
            4
        )
        XCTAssertEqual(
            try layout.bodyValue(
                settingBodyGroupID: 1,
                to: 1,
                currentBodyValue: 5
            ),
            3
        )
        XCTAssertEqual(
            try layout.bodyValue(
                settingBodyGroupID: 9,
                to: 1,
                currentBodyValue: 5
            ),
            5
        )
        XCTAssertEqual(
            try layout.bodyValue(
                settingBodyGroupID: 1,
                to: 3,
                currentBodyValue: 5
            ),
            5
        )
    }

    func testInvalidMetadataAndNegativeValuesFailClosed() throws {
        XCTAssertThrowsError(
            try SourceStudioBodyGroupLayout(bodyParts: [
                .init(modelSelectionBase: 1, modelCount: 0),
            ])
        ) { error in
            XCTAssertEqual(
                error as? SourceStudioBodyGroupLayoutError,
                .invalidModelCount(bodyGroupID: 0, value: 0)
            )
        }
        XCTAssertThrowsError(
            try SourceStudioBodyGroupLayout(bodyParts: [
                .init(modelSelectionBase: 0, modelCount: 2),
            ])
        ) { error in
            XCTAssertEqual(
                error as? SourceStudioBodyGroupLayoutError,
                .invalidModelSelectionBase(bodyGroupID: 0, value: 0)
            )
        }

        let layout = try SourceStudioBodyGroupLayout(bodyParts: [
            .init(modelSelectionBase: 1, modelCount: 2),
        ])
        XCTAssertThrowsError(
            try layout.selection(forBodyGroupID: 0, bodyValue: -1)
        )
        XCTAssertThrowsError(
            try layout.bodyValue(
                settingBodyGroupID: 0,
                to: -1,
                currentBodyValue: 0
            )
        )
    }
}
