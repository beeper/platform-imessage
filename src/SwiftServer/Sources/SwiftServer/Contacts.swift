import Contacts
import SwiftServerFoundation
import Logging

private let log = Logger(swiftServerLabel: "contacts")

final class Contacts {
    private let store = CNContactStore()

    private var cache = [String: String?]()

    init?() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            log.notice("contacts access not authorized")
            return nil
        }
        NotificationCenter.default.addObserver(self, selector: #selector(self.contactStoreDidChange), name: .CNContactStoreDidChange, object: nil)
    }

    func fetchID(for emailOrPhoneNumber: String) -> String? {
        if let identifier = cache[emailOrPhoneNumber] {
            return identifier
        }
        let startTime = Date()
        defer { log.debug("fetchContactID took \(startTime.timeIntervalSinceNow * -1000)ms") }
        let isEmail = emailOrPhoneNumber.contains("@")
        let predicate = isEmail
            ? CNContact.predicateForContacts(matchingEmailAddress: emailOrPhoneNumber)
            // this might be slightly unreliable bc of the numerous ways a phone number is stored (w and w/o country code)
            : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: emailOrPhoneNumber))
        let contacts = try? store.unifiedContacts(
            matching: predicate,
            keysToFetch: [CNContactIdentifierKey, isEmail ? CNContactEmailAddressesKey : CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        )
        if let contacts, contacts.count > 1 {
            log.notice("fetchContactID: found more than one contact for \(emailOrPhoneNumber)")
        }
        let identifier = contacts?.first?.identifier
        cache[emailOrPhoneNumber] = identifier
        return identifier
    }

    @objc private func contactStoreDidChange() {
        cache.removeAll()
    }
}
