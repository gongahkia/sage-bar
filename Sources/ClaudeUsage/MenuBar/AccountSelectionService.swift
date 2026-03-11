import Foundation

enum AccountSelectionService {
    @discardableResult
    static func select(accountID: UUID, userDefaults: UserDefaults = .standard) -> UUID {
        userDefaults.set(accountID.uuidString, forKey: AppConstants.selectedAccountDefaultsKey)
        NotificationCenter.default.post(name: .selectedAccountDidChange, object: accountID)
        return accountID
    }

    @discardableResult
    static func selectNext(in accounts: [Account], userDefaults: UserDefaults = .standard) -> Account? {
        selectAdjacent(in: accounts, offset: 1, userDefaults: userDefaults)
    }

    @discardableResult
    static func selectPrevious(in accounts: [Account], userDefaults: UserDefaults = .standard) -> Account? {
        selectAdjacent(in: accounts, offset: -1, userDefaults: userDefaults)
    }

    static func currentAccount(in accounts: [Account], userDefaults: UserDefaults = .standard) -> Account? {
        Account.preferredAccount(from: accounts, userDefaults: userDefaults)
    }

    private static func selectAdjacent(
        in accounts: [Account],
        offset: Int,
        userDefaults: UserDefaults
    ) -> Account? {
        guard !accounts.isEmpty else { return nil }
        let current = currentAccount(in: accounts, userDefaults: userDefaults)
        let currentIndex = current.flatMap { current in
            accounts.firstIndex(where: { $0.id == current.id })
        } ?? 0
        let nextIndex = (currentIndex + offset + accounts.count) % accounts.count
        let selected = accounts[nextIndex]
        select(accountID: selected.id, userDefaults: userDefaults)
        return selected
    }
}

extension Notification.Name {
    static let selectedAccountDidChange = Notification.Name("SelectedAccountDidChange")
}
