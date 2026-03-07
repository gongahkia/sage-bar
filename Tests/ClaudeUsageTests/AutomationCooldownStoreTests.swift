import XCTest
@testable import SageBar

final class AutomationCooldownStoreTests: XCTestCase {
    private var store: AutomationCooldownStore!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cooldown_test_\(UUID().uuidString).json")
        store = AutomationCooldownStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func drainQueue() {
        let exp = expectation(description: "drain")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    func testRecordAndRetrieveLastFiredAt() {
        let ruleID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.setLastFiredAt(now, ruleID: ruleID)
        drainQueue()
        let retrieved = store.lastFiredAt(ruleID: ruleID)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved!.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
    }

    func testReturnsNilForUnknownRuleID() {
        let result = store.lastFiredAt(ruleID: UUID())
        XCTAssertNil(result)
    }

    func testMultipleRulesTrackedIndependently() {
        let ruleA = UUID()
        let ruleB = UUID()
        let dateA = Date(timeIntervalSince1970: 1_000_000)
        let dateB = Date(timeIntervalSince1970: 2_000_000)
        store.setLastFiredAt(dateA, ruleID: ruleA)
        store.setLastFiredAt(dateB, ruleID: ruleB)
        drainQueue()
        let retrievedA = store.lastFiredAt(ruleID: ruleA)
        let retrievedB = store.lastFiredAt(ruleID: ruleB)
        XCTAssertNotNil(retrievedA)
        XCTAssertNotNil(retrievedB)
        XCTAssertEqual(retrievedA!.timeIntervalSince1970, dateA.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(retrievedB!.timeIntervalSince1970, dateB.timeIntervalSince1970, accuracy: 1)
    }

    func testResetClearsStore() {
        let ruleID = UUID()
        store.setLastFiredAt(Date(), ruleID: ruleID)
        drainQueue()
        store.reset()
        let result = store.lastFiredAt(ruleID: ruleID)
        XCTAssertNil(result)
    }
}
