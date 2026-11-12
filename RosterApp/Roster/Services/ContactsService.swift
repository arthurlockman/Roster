import Contacts
import Observation
import Foundation

/// A saved/synced contact as shown in the picker. A contact with several
/// addresses lists every labeled address; the user picks exactly one to
/// become a roster member.
nonisolated struct ContactSummary: Identifiable, Hashable, Sendable {
    struct LabeledEmail: Identifiable, Hashable, Sendable {
        let id: String
        let label: String
        let value: String
    }

    let id: String
    let displayName: String
    let emailAddresses: [LabeledEmail]
}

/// Reads saved/synced contacts across all account containers. Live network
/// directories (GAL/LDAP) are not queryable through Contacts.framework; the UI
/// shows the approved workaround (search in Contacts.app, save the result into
/// a non-directory list, refresh here).
@Observable
final class ContactsService {
    enum AccessState: Equatable {
        case notDetermined
        case denied
        case authorized
    }

    private(set) var accessState: AccessState = .notDetermined
    private(set) var summaries: [ContactSummary] = []
    /// Read failure text distinct from "there are no contacts".
    private(set) var loadError: String?

    private let store = CNContactStore()
    private var changeObserver: (any NSObjectProtocol)?
    private var refreshTask: Task<Void, Never>?

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Notifications can arrive in bursts; coalesce to one refresh.
            self?.refreshTask?.cancel()
            self?.refreshTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    func requestAccess() async {
        do {
            let granted = try await store.requestAccess(for: .contacts)
            accessState = granted ? .authorized : .denied
        } catch {
            accessState = .denied
            loadError = error.localizedDescription
        }
        if accessState == .authorized {
            await refresh()
        }
    }

    /// Enumerates unified contacts with only the keys we display.
    /// Contacts flags main-thread enumeration as a UI hazard, so the
    /// store scan runs on a background task.
    func refresh() async {
        guard accessState == .authorized else { return }
        do {
            let fetched = try await Self.fetchSummaries()
            summaries = fetched.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// `CNContactStore` is not Sendable, so the store is created inside
    /// the detached task; access is granted per process, not per instance.
    nonisolated private static func fetchSummaries() async throws -> [ContactSummary] {
        try await Task.detached(priority: .userInitiated) {
            try Self.fetchAll(from: CNContactStore())
        }.value
    }

    nonisolated private static func fetchAll(from store: CNContactStore) throws -> [ContactSummary] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var results: [ContactSummary] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let emails = contact.emailAddresses.map { labeled in
                ContactSummary.LabeledEmail(
                    id: contact.identifier + "|" + labeled.identifier,
                    label: CNLabeledValue<CNContact>.localizedString(forLabel: labeled.label ?? ""),
                    value: labeled.value as String
                )
            }
            results.append(ContactSummary(id: contact.identifier, displayName: Self.displayName(of: contact), emailAddresses: emails))
        }
        return results
    }

    nonisolated private static func displayName(of contact: CNContact) -> String {
        let full = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !full.isEmpty { return full }
        if !contact.nickname.isEmpty { return contact.nickname }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        return "Unnamed contact"
    }
}
