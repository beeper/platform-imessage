import Contacts
import Combine
import ExceptionCatcher
import SwiftServerFoundation
import Logging

private let log = Logger(swiftServerLabel: "contacts")

extension CNContactFormatterStyle {
    // seemingly used by Messages; prefers nickname, then given name
    static var short: Self? {
        CNContactFormatterStyle(rawValue: 1000)
    }
    
    // similar to `short`? identical?
    static var abbreviated: Self? {
        CNContactFormatterStyle(rawValue: 1001)
    }
    
    // returns e.g. "JD" for "John Doe"
    static var monogram: Self? {
        CNContactFormatterStyle(rawValue: 1002)
    }
}

final class Contacts {
    private let store = CNContactStore()
    private var cache = [String: String?]()
    private var cancellables: Set<AnyCancellable> = []
    
    init?() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            log.notice("contacts access not authorized")
            return nil
        }
        NotificationCenter.default.publisher(for: .CNContactStoreDidChange)
            .sink { [weak self] _ in
                guard let self else { return }
                contactStoreDidChange()
            }
            .store(in: &cancellables)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private lazy var standardFormatter = CNContactFormatter()
    
    // instantiate the short formatter in a defensive manner because it's private
    // we can't rely on its availability
    private lazy var shortFormatter: CNContactFormatter? = {
        guard Defaults.swiftServer.bool(forKey: DefaultsKeys.contactsAttemptFormattingWithShortStyle) else {
            log.debug("default is preventing creation of a contact formatter with the short style")
            return nil
        }
        
        do {
            return try ExceptionCatcher.catch {
                guard let style = CNContactFormatterStyle.short else {
                    return nil
                }
                
                var formatter = CNContactFormatter()
                formatter.style = style
                return formatter
            }
        } catch {
            log.warning("couldn't create contact formatter with short style: \(error)")
            return nil
        }
    }()
    
    private func tryFormattingWithShortStyle(_ contact: CNContact) -> String? {
        do {
            return try ExceptionCatcher.catch {
                shortFormatter?.string(from: contact)
            }
        } catch {
            log.warning("couldn't format with short style: \(error)")
            return nil
        }
    }
    
    private lazy var descriptorForShortFormatting: (any CNKeyDescriptor)? = {
        guard Defaults.swiftServer.bool(forKey: DefaultsKeys.contactsAttemptFormattingWithShortStyle), let short = CNContactFormatterStyle.short else {
            return nil
        }
        
        return try? ExceptionCatcher.catch {
            CNContactFormatter.descriptorForRequiredKeys(for: short)
        }
    }()
    
    // NOTE: attempting to access unfetched properties on a contact will raise an ObjC exception
    private func contactKeysToFetch(isEmail: Bool) -> [any CNKeyDescriptor] {
        var keys = [
            CNContactIdentifierKey,
            isEmail ? CNContactEmailAddressesKey : CNContactPhoneNumbersKey,
            CNContactNicknameKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
        ] as [any CNKeyDescriptor]
        
        if let descriptorForShortFormatting {
            keys.append(descriptorForShortFormatting)
        }
        keys.append(CNContactFormatter.descriptorForRequiredKeys(for: .fullName))
        
        return keys
    }
    
    private func contactStoreDidChange() {
        cache.removeAll()
    }
}

extension Contacts {
    func firstMatching(emailOrPhoneNumber: String) -> CNContact? {
        let isEmail = emailOrPhoneNumber.contains("@")
        let predicate = isEmail
        ? CNContact.predicateForContacts(matchingEmailAddress: emailOrPhoneNumber)
        // this might be slightly unreliable bc of the numerous ways a phone number is stored (w and w/o country code)
        : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: emailOrPhoneNumber))
        
        let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: contactKeysToFetch(isEmail: isEmail))
        if let contacts, contacts.count > 1 {
            log.warning("firstMatching: more than one contact matched the desired criteria")
        }
        return contacts?.first
    }
    
    func format(contact: CNContact, style: FormatStyle = .standard) -> String? {
        do {
            return try ExceptionCatcher.catch {
                switch style {
                    case .short: tryFormattingWithShortStyle(contact)
                    case .standard: standardFormatter.string(from: contact)
                }
            }
        } catch {
            log.error("couldn't format contact using style \(style): \(error)")
            return nil
        }
    }
    
    func formatPreferringShortStyle(contact: CNContact) -> String? {
        format(contact: contact, style: .short) ?? format(contact: contact, style: .standard)
    }
    
    func fetchID(for emailOrPhoneNumber: String) -> String? {
        if let identifier = cache[emailOrPhoneNumber] {
            return identifier
        }
        let id = firstMatching(emailOrPhoneNumber: emailOrPhoneNumber)?.identifier
        cache[emailOrPhoneNumber] = id
        return id
    }
}

extension Contacts {
    enum FormatStyle: Hashable, Equatable, CaseIterable {
        case standard
        case short
    }
}
