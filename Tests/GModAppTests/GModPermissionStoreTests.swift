import Foundation
import XCTest
@testable import GModApp

final class GModPermissionStoreTests: XCTestCase {
    @MainActor
    func testTemporaryAndPermanentPermissionsAreIsolatedPerServer() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }

        XCTAssertTrue(try fixture.store.grant(
            "connect",
            for: "alpha.example:27015",
            lifetime: .temporary
        ))
        XCTAssertTrue(try fixture.store.grant(
            "https://example.invalid/docs",
            for: "alpha.example:27015",
            lifetime: .permanent
        ))
        XCTAssertTrue(try fixture.store.grant(
            "connect",
            for: "beta.example:27015",
            lifetime: .permanent
        ))

        XCTAssertTrue(try fixture.store.isGranted(
            "connect",
            for: "alpha.example:27015"
        ))
        XCTAssertFalse(try fixture.store.isGranted(
            "https://example.invalid/docs",
            for: "beta.example:27015"
        ))
        XCTAssertEqual(
            fixture.store.getAll(),
            GModPermissionCollection(
                temporary: ["alpha.example:27015": ["connect"]],
                permanent: [
                    "alpha.example:27015": ["https://example.invalid/docs"],
                    "beta.example:27015": ["connect"],
                ]
            )
        )
        XCTAssertEqual(fixture.store.getAll().grants.map(\.id), [
            "alpha.example:27015|temporary|connect",
            "alpha.example:27015|permanent|https://example.invalid/docs",
            "beta.example:27015|permanent|connect",
        ])
    }

    @MainActor
    func testOnlyPermanentPermissionsPersistAndSessionBoundaryClearsTemporary()
        throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }

        try fixture.store.grant(
            "temporary-action",
            for: "server-a",
            lifetime: .temporary
        )
        try fixture.store.grant(
            "permanent-action",
            for: "server-a",
            lifetime: .permanent
        )

        let restored = GModPermissionStore(
            defaults: fixture.defaults,
            notificationCenter: fixture.notificationCenter
        )
        XCTAssertEqual(restored.collection.temporary, [:])
        XCTAssertEqual(
            restored.collection.permanent,
            ["server-a": ["permanent-action"]]
        )

        XCTAssertTrue(fixture.store.clearTemporaryPermissions())
        XCTAssertFalse(fixture.store.clearTemporaryPermissions())
        XCTAssertEqual(fixture.store.collection.temporary, [:])
        XCTAssertEqual(
            fixture.store.collection.permanent,
            ["server-a": ["permanent-action"]]
        )
    }

    @MainActor
    func testChangesPublishExactlyOnceAndNoOpMutationsStaySilent() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let counter = NotificationCounter()
        fixture.notificationCenter.addObserver(
            counter,
            selector: #selector(NotificationCounter.didReceive(_:)),
            name: GModPermissionStore.didChangeNotification,
            object: fixture.store
        )
        defer { fixture.notificationCenter.removeObserver(counter) }

        XCTAssertTrue(try fixture.store.grant(
            "connect",
            for: "server-a",
            lifetime: .temporary
        ))
        XCTAssertEqual(counter.value, 1)

        XCTAssertFalse(try fixture.store.grant(
            "connect",
            for: "server-a",
            lifetime: .temporary
        ))
        XCTAssertEqual(counter.value, 1)

        XCTAssertTrue(try fixture.store.grant(
            "connect",
            for: "server-a",
            lifetime: .permanent
        ))
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(fixture.store.collection.temporary, [:])

        XCTAssertFalse(try fixture.store.grant(
            "connect",
            for: "server-a",
            lifetime: .temporary
        ))
        XCTAssertEqual(counter.value, 2)

        XCTAssertTrue(try fixture.store.revoke("connect", for: "server-a"))
        XCTAssertEqual(counter.value, 3)
        XCTAssertFalse(try fixture.store.revoke("connect", for: "server-a"))
        XCTAssertEqual(counter.value, 3)

        XCTAssertTrue(try fixture.store.grant(
            "openurl",
            for: "server-a",
            lifetime: .temporary
        ))
        XCTAssertEqual(counter.value, 4)
        XCTAssertTrue(fixture.store.clearTemporaryPermissions())
        XCTAssertEqual(counter.value, 5)
        XCTAssertFalse(fixture.store.clearTemporaryPermissions())
        XCTAssertEqual(counter.value, 5)
    }

    @MainActor
    func testMalformedInputsAndPersistenceAreRejectedWithoutPartialGrants()
        throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try fixture.store.grant(
            "connect",
            for: "  \n ",
            lifetime: .temporary
        )) { error in
            XCTAssertEqual(
                error as? GModPermissionStoreError,
                .malformedServerIdentifier
            )
        }
        XCTAssertThrowsError(try fixture.store.grant(
            "bad\u{0000}permission",
            for: "server-a",
            lifetime: .permanent
        )) { error in
            XCTAssertEqual(
                error as? GModPermissionStoreError,
                .malformedPermission
            )
        }
        XCTAssertEqual(fixture.store.collection, .empty)

        fixture.defaults.set(
            Data("{not-json".utf8),
            forKey: GModPermissionStore.permanentPermissionsKey
        )
        let corrupted = GModPermissionStore(
            defaults: fixture.defaults,
            notificationCenter: fixture.notificationCenter
        )
        XCTAssertEqual(corrupted.collection, .empty)
        XCTAssertEqual(
            corrupted.persistenceError,
            .malformedPersistedPermissions
        )
        let corruptedSnapshot = GModAppProblemSnapshotBuilder.build(
            retained: [],
            gameLogs: [],
            consoleLogs: [],
            worldScene: nil,
            surfaceDiagnostics: nil,
            contentError: nil,
            permissionCollection: corrupted.collection,
            permissionPersistenceError: corrupted.persistenceError
        )
        XCTAssertTrue(corruptedSnapshot.problems.contains {
            $0.id.hasPrefix("permissions-persistence|")
                && $0.severity == .error
        })

        fixture.defaults.set(
            "not-data",
            forKey: GModPermissionStore.permanentPermissionsKey
        )
        let wrongType = GModPermissionStore(
            defaults: fixture.defaults,
            notificationCenter: fixture.notificationCenter
        )
        XCTAssertEqual(wrongType.collection, .empty)
        XCTAssertEqual(
            wrongType.persistenceError,
            .malformedPersistedPermissions
        )
    }

    @MainActor
    func testConnectRejectsUnavailableTransportWithoutMutatingPermissions()
        throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try fixture.store.grant(
            "connect",
            for: "server-a",
            lifetime: .permanent
        )
        let before = fixture.store.collection

        XCTAssertThrowsError(
            try fixture.store.connect(to: "server-b:27015")
        ) { error in
            XCTAssertEqual(
                error as? GModPermissionStoreError,
                .multiplayerTransportUnavailable
            )
        }
        XCTAssertEqual(fixture.store.collection, before)

        XCTAssertThrowsError(try fixture.store.connect(to: "\u{0000}")) {
            error in
            XCTAssertEqual(
                error as? GModPermissionStoreError,
                .malformedConnectTarget
            )
        }
        XCTAssertEqual(fixture.store.collection, before)
    }

    @MainActor
    func testProblemsSnapshotShowsRealGrantsWithoutInventingAProblem()
        throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        try fixture.store.grant(
            "connect",
            for: "server-a",
            lifetime: .temporary
        )

        let snapshot = GModAppProblemSnapshotBuilder.build(
            retained: [],
            gameLogs: [],
            consoleLogs: [],
            worldScene: nil,
            surfaceDiagnostics: nil,
            contentError: nil,
            permissionCollection: fixture.store.collection,
            permissionPersistenceError: fixture.store.persistenceError
        )
        XCTAssertEqual(snapshot.permissions, [
            GModAppPermissionRecord(
                id: "server-a|temporary|connect",
                serverIdentifier: "server-a",
                permission: "connect",
                lifetime: .temporary
            ),
        ])
        XCTAssertFalse(snapshot.problems.contains {
            $0.id == "permissions-menu-transport-unavailable"
        })
        XCTAssertFalse(snapshot.problems.contains {
            $0.id == "permissions-bridge-unavailable"
        })
    }

    @MainActor
    private func makeFixture() -> PermissionFixture {
        let suite = "GModPermissionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let notificationCenter = NotificationCenter()
        return PermissionFixture(
            suite: suite,
            defaults: defaults,
            notificationCenter: notificationCenter,
            store: GModPermissionStore(
                defaults: defaults,
                notificationCenter: notificationCenter
            )
        )
    }
}

@MainActor
private final class NotificationCounter: NSObject {
    var value = 0

    @objc func didReceive(_ notification: Notification) {
        value += 1
    }
}

private struct PermissionFixture {
    let suite: String
    let defaults: UserDefaults
    let notificationCenter: NotificationCenter
    let store: GModPermissionStore

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
    }
}
