import Foundation
import XCTest
@testable import GModApp

final class GModPlaygroundContentTests: XCTestCase {
    @MainActor
    func testResourceFreeLaunchRequestsExternalSelection() {
        let suiteName = "GModPlaygroundContentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = GModPlaygroundContentModel(
            runtimeFactory: GModAppRuntimeFactory(),
            defaults: defaults
        )

        guard case .missing = model.state else {
            return XCTFail("resource-free launch did not enter the ZIP selection state")
        }
        XCTAssertNil(model.assetSource)
        XCTAssertNil(model.persistenceWarning)
    }

    @MainActor
    func testInvalidSavedBookmarkFailsClosedAndIsCleared() {
        let suiteName = "GModPlaygroundContentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "GarrysPAD.ContentPack.SecurityScopedBookmark.v1"
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: key)

        let model = GModPlaygroundContentModel(
            runtimeFactory: GModAppRuntimeFactory(),
            defaults: defaults
        )

        guard case let .failed(message) = model.state else {
            return XCTFail("invalid bookmark did not fail closed")
        }
        XCTAssertTrue(message.contains("Choose the content ZIP again"))
        XCTAssertNil(defaults.data(forKey: key))
    }
}
