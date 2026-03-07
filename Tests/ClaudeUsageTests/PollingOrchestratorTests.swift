import XCTest
@testable import SageBar

final class PollingOrchestratorTests: XCTestCase {
    private func makeAccount(_ name: String = "test") -> Account {
        Account(name: name, type: .claudeCode)
    }

    private let noJitter: @Sendable (Account, Int) -> UInt64 = { _, _ in 0 }

    func testSingleAccountPollsSuccessfully() async {
        let account = makeAccount()
        let expectedID = account.id
        let results = await PollingOrchestrator.pollAccounts(
            [account],
            maxConcurrencyUpperCap: 4,
            fetchAccount: { _ in expectedID },
            jitterNanos: noJitter
        )
        XCTAssertEqual(results, [expectedID])
    }

    func testMultipleAccountsPolledConcurrently() async {
        let accounts = (0..<5).map { makeAccount("acct-\($0)") }
        let results = await PollingOrchestrator.pollAccounts(
            accounts,
            maxConcurrencyUpperCap: 5,
            fetchAccount: { $0.id },
            jitterNanos: noJitter
        )
        XCTAssertEqual(Set(results), Set(accounts.map(\.id)))
    }

    func testFailedAccountReturnsNilOthersSucceed() async {
        let accounts = (0..<3).map { makeAccount("acct-\($0)") }
        let failID = accounts[1].id
        let results = await PollingOrchestrator.pollAccounts(
            accounts,
            maxConcurrencyUpperCap: 4,
            fetchAccount: { $0.id == failID ? nil : $0.id },
            jitterNanos: noJitter
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertFalse(results.contains(failID))
        XCTAssertTrue(results.contains(accounts[0].id))
        XCTAssertTrue(results.contains(accounts[2].id))
    }

    func testMaxConcurrencyIsRespected() async {
        let accounts = (0..<10).map { makeAccount("acct-\($0)") }
        let results = await PollingOrchestrator.pollAccounts(
            accounts,
            maxConcurrencyUpperCap: 2,
            fetchAccount: { $0.id },
            jitterNanos: noJitter
        )
        XCTAssertEqual(Set(results), Set(accounts.map(\.id)))
    }

    func testEmptyAccountsReturnsEmpty() async {
        let results = await PollingOrchestrator.pollAccounts(
            [],
            maxConcurrencyUpperCap: 4,
            fetchAccount: { $0.id },
            jitterNanos: noJitter
        )
        XCTAssertTrue(results.isEmpty)
    }
}
