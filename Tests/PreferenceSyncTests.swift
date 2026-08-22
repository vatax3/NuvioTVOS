import XCTest
@testable import Nuvio

/// Why deleting fifty-two unread settings fields did not break account sync.
///
/// The audit's second finding was ~60 store fields that were stored, defaulted and synced, and
/// read by nothing. The obvious worry about deleting them is that the account payload is shared
/// with the Android and mobile apps, and dropping a field would drop their value on the floor.
///
/// It does not, and this is the proof: `PreferenceStore` syncs its **raw storage**, not its
/// declared properties. A key that arrives from another platform is persisted and written back
/// whether or not any Swift property names it. What would lose data is removing a namespace from
/// `AppSettings.syncedStores` — which is why the now-empty `TrailerSettingsStore` is still there.
@MainActor
final class PreferenceSyncTests: XCTestCase {
    /// A namespace of its own so the test never touches a real setting.
    private final class ProbeStore: PreferenceStore {
        init() { super.init(namespace: "test_probe") }

        var declared: Bool {
            get { bool("declared_key", default: false) }
            set { setBool("declared_key", newValue) }
        }
    }

    private var store: ProbeStore!

    override func setUp() async throws {
        try await super.setUp()
        store = ProbeStore()
    }

    override func tearDown() async throws {
        // The probe writes into UserDefaults like any store; leave nothing behind.
        for key in ["undeclared_from_android", "declared_key", "undeclared_number", "undeclared_list"] {
            UserDefaults.standard.removeObject(forKey: "test_probe.\(key)")
        }
        store = nil
        try await super.tearDown()
    }

    func testAKeyNoSwiftPropertyDeclaresStillComesBackOut() {
        store.importFromSync([
            "declared_key": .bool(true),
            "undeclared_from_android": .string("some-android-only-value"),
            "undeclared_number": .number(1440),
            "undeclared_list": .array([.string("a"), .string("b")])
        ])

        let exported = store.exportForSync()

        XCTAssertEqual(exported["undeclared_from_android"], .string("some-android-only-value"))
        XCTAssertEqual(exported["undeclared_number"], .int(1440))
        XCTAssertEqual(exported["undeclared_list"], .array([.string("a"), .string("b")]))
        XCTAssertEqual(exported["declared_key"], .bool(true))
        XCTAssertTrue(store.declared, "and a declared key is readable as usual")
    }

    /// Integral JSON numbers have to come back as integers: they left Android as `Int`, and a
    /// round trip that turned 1440 into 1440.0 would change the value's type on the way home.
    func testIntegralNumbersDoNotBecomeFloats() {
        store.importFromSync(["undeclared_number": .number(90)])
        XCTAssertEqual(store.exportForSync()["undeclared_number"], .int(90))
    }

    /// The trailer namespace has no properties left — hero trailers cannot exist on tvOS — but it
    /// is still registered for sync, and that is the part that matters.
    func testTheEmptiedTrailerNamespaceStillRoundTrips() {
        let trailers = TrailerSettingsStore()
        trailers.importFromSync(["trailer_enabled": .bool(true), "trailer_delay_seconds": .number(5)])
        let exported = trailers.exportForSync()
        XCTAssertEqual(exported["trailer_enabled"], .bool(true))
        XCTAssertEqual(exported["trailer_delay_seconds"], .int(5))
        UserDefaults.standard.removeObject(forKey: "trailer.trailer_enabled")
        UserDefaults.standard.removeObject(forKey: "trailer.trailer_delay_seconds")
    }
}
