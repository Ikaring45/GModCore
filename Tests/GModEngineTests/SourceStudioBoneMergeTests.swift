import XCTest
import GModEngine

final class SourceStudioBoneMergeTests: XCTestCase {
    private func translation(_ x: Float, _ y: Float = 0) -> SourceStudioMatrix3x4 {
        .init(1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, 0)
    }

    func testNamedMergeUsesFollowedOrderAndRebuildsUnmatchedDescendants() throws {
        let bones: [SourceStudioBoneMergeBone] = [
            .init(name: "Root", parent: -1, flags: 1),
            .init(name: "Hand", parent: 0, flags: 1),
            .init(name: "Finger", parent: 1, flags: 1)
        ]
        let result = try SourceStudioBoneMerge.modelTransforms(ownerBones: bones,
            ownerLocalTransforms: [translation(1), translation(2), translation(3)],
            following: .init(followedBones: [
                .init(name: "HAND", parent: -1, flags: 0),
                .init(name: "root", parent: -1, flags: 0)
            ], followedTransforms: [translation(20, 4), translation(10)], boneMask: 1))
        XCTAssertEqual(result.map(\.position), [.init(10, 0, 0), .init(20, 4, 0), .init(23, 4, 0)])
    }

    func testMaskDisabledAndUnmatchedBonesUseActualLocalPose() throws {
        let result = try SourceStudioBoneMerge.modelTransforms(ownerBones: [
            .init(name: "Root", parent: -1, flags: 2),
            .init(name: "Unmatched", parent: 0, flags: 1)
        ], ownerLocalTransforms: [translation(1), translation(2)],
            following: .init(followedBones: [.init(name: "root", parent: -1, flags: 0)],
                followedTransforms: [translation(99)], boneMask: 1),
            ownerRootTransform: translation(5))
        XCTAssertEqual(result.map(\.position), [.init(6, 0, 0), .init(8, 0, 0)])
    }

    func testMalformedPalettesFailWithoutPartialPublication() throws {
        let bone = SourceStudioBoneMergeBone(name: "Root", parent: -1, flags: 1)
        let empty = SourceStudioBoneMergeInput(followedBones: [], followedTransforms: [], boneMask: 1)
        XCTAssertThrowsError(try SourceStudioBoneMerge.modelTransforms(ownerBones: [bone], ownerLocalTransforms: [], following: empty))
        XCTAssertThrowsError(try SourceStudioBoneMerge.modelTransforms(ownerBones: [.init(name: "bad", parent: 0, flags: 1)], ownerLocalTransforms: [.identity], following: empty))
        XCTAssertThrowsError(try SourceStudioBoneMerge.modelTransforms(ownerBones: [bone], ownerLocalTransforms: [translation(.nan)], following: empty))
        XCTAssertThrowsError(try SourceStudioBoneMerge.modelTransforms(ownerBones: [bone], ownerLocalTransforms: [.identity], following: .init(
            followedBones: [bone, .init(name: "ROOT", parent: -1, flags: 1)], followedTransforms: [.identity, .identity], boneMask: 1)))
    }
}
