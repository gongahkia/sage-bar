import XCTest
@testable import SageBar

final class KeychainManagerTests: XCTestCase {
    private let service = "claude-usage-test"
    private let account = "test-\(UUID().uuidString)"

    override func tearDown() {
        try? KeychainManager.delete(service: service, account: account)
        super.tearDown()
    }

    func testStoreAndRetrieve() throws {
        try KeychainManager.store(key: "secret-value", service: service, account: account)
        let retrieved = try KeychainManager.retrieve(service: service, account: account)
        XCTAssertEqual(retrieved, "secret-value")
    }

    func testStoreUpdateAndRetrieve() throws {
        try KeychainManager.store(key: "first", service: service, account: account)
        try KeychainManager.store(key: "updated", service: service, account: account)
        let retrieved = try KeychainManager.retrieve(service: service, account: account)
        XCTAssertEqual(retrieved, "updated")
    }

    func testDeleteRemovesItem() throws {
        try KeychainManager.store(key: "to-delete", service: service, account: account)
        try KeychainManager.delete(service: service, account: account)
        XCTAssertThrowsError(try KeychainManager.retrieve(service: service, account: account)) { error in
            guard case KeychainError.itemNotFound = error else { XCTFail("expected itemNotFound"); return }
        }
    }

    func testRetrieveMissingReturnsItemNotFound() {
        XCTAssertThrowsError(try KeychainManager.retrieve(service: service, account: "nonexistent-\(UUID())")) { error in
            guard case KeychainError.itemNotFound = error else { XCTFail("expected itemNotFound"); return }
        }
    }

    func testDeleteNonExistentDoesNotThrow() {
        XCTAssertNoThrow(try KeychainManager.delete(service: service, account: "nonexistent-\(UUID())"))
    }
}
