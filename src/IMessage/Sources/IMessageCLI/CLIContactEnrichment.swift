import Contacts
import Foundation
import IMessageCore
import PlatformSDK

struct CLIResolvedContact: Equatable {
    var fullName: String?
    var nickname: String?
    var imgURL: String?

    init(fullName: String? = nil, nickname: String? = nil, imgURL: String? = nil) {
        self.fullName = fullName
        self.nickname = nickname
        self.imgURL = imgURL
    }
}

protocol CLIContactResolving {
    func resolvedContact(emailOrPhoneNumber: String) -> CLIResolvedContact?
}

final class CLIContactResolver: CLIContactResolving {
    private struct Lookup {
        enum Kind {
            case email
            case phoneNumber
        }

        var value: String
        var kind: Kind

        init?(_ rawValue: String) {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                return nil
            }
            self.value = value
            kind = value.contains("@") ? .email : .phoneNumber
        }

        var cacheKey: String {
            switch kind {
            case .email: value.lowercased()
            case .phoneNumber: value
            }
        }

        var predicate: NSPredicate {
            switch kind {
            case .email:
                CNContact.predicateForContacts(matchingEmailAddress: value)
            case .phoneNumber:
                CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: value))
            }
        }

        var contactKeysToFetch: [any CNKeyDescriptor] {
            var keys = [
                CNContactIdentifierKey,
                CNContactGivenNameKey,
                CNContactMiddleNameKey,
                CNContactFamilyNameKey,
                CNContactNicknameKey,
                CNContactOrganizationNameKey,
                kind == .email ? CNContactEmailAddressesKey : CNContactPhoneNumbersKey,
                CNContactThumbnailImageDataKey,
            ] as [any CNKeyDescriptor]
            keys.append(CNContactFormatter.descriptorForRequiredKeys(for: .fullName))
            return keys
        }
    }

    private enum CachedResolvedContact {
        case hit(CLIResolvedContact)
        case miss

        var value: CLIResolvedContact? {
            switch self {
            case let .hit(contact): return contact
            case .miss: return nil
            }
        }
    }

    private let store = CNContactStore()
    private lazy var formatter: CNContactFormatter = {
        let formatter = CNContactFormatter()
        formatter.style = .fullName
        return formatter
    }()
    private static let maxCachedContacts = 512
    private var cache = [String: CachedResolvedContact]()
    private var cacheKeys = [String]()

    init?() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return nil
        }
    }

    func resolvedContact(emailOrPhoneNumber rawValue: String) -> CLIResolvedContact? {
        guard let lookup = Lookup(rawValue) else {
            return nil
        }

        let key = lookup.cacheKey
        if let cached = cache[key] {
            return cached.value
        }

        let resolved = firstMatchingContact(lookup).map { contact in
            CLIResolvedContact(
                fullName: formatter.string(from: contact)?.nonEmpty ?? contact.organizationName.nonEmpty,
                nickname: contact.nickname.nonEmpty,
                imgURL: contact.thumbnailImageData?.dataURL
            )
        }
        cache(resolved.map(CachedResolvedContact.hit) ?? .miss, forKey: key)
        return resolved
    }

    private func firstMatchingContact(_ lookup: Lookup) -> CNContact? {
        return try? store.unifiedContacts(
            matching: lookup.predicate,
            keysToFetch: lookup.contactKeysToFetch
        ).first
    }

    private func cache(_ resolved: CachedResolvedContact, forKey key: String) {
        if cache[key] == nil {
            cacheKeys.append(key)
        }
        cache[key] = resolved

        while cacheKeys.count > Self.maxCachedContacts {
            cache.removeValue(forKey: cacheKeys.removeFirst())
        }
    }
}

enum CLIThreadContactEnricher {
    static func enrichThreadPageJSON(
        _ pageObject: JSONObject,
        resolver: (any CLIContactResolving)?
    ) -> JSONObject {
        guard let resolver,
              var items = pageObject["items"] as? [JSONObject] else {
            return pageObject
        }

        var pageObject = pageObject
        items = items.map { enrichThreadJSON($0, resolver: resolver) ?? $0 }
        pageObject["items"] = items
        return pageObject
    }

    static func enrichThreadJSON(
        _ threadObject: JSONObject?,
        resolver: (any CLIContactResolving)?
    ) -> JSONObject? {
        guard let resolver, var threadObject else {
            return threadObject
        }

        guard var participantsPage = threadObject["participants"] as? JSONObject,
              let participants = participantsPage["items"] as? [JSONObject] else {
            return threadObject
        }

        var titleNames = [String]()
        var hasNamedTitleCandidate = false
        var enrichedParticipants = [JSONObject]()
        for participant in participants {
            let enriched = enrichParticipantJSON(participant, resolver: resolver)
            enrichedParticipants.append(enriched.object)

            if !enriched.isSelf,
               let title = participantTitle(for: enriched.object) {
                titleNames.append(title)
                hasNamedTitleCandidate = hasNamedTitleCandidate || enriched.hasContactName
            }
        }

        participantsPage["items"] = enrichedParticipants
        threadObject["participants"] = participantsPage

        if threadObject.string("title")?.nonEmpty == nil,
           let title = derivedTitle(
            for: threadObject,
            titleNames: titleNames,
            hasNamedContact: hasNamedTitleCandidate
           ) {
            threadObject["title"] = title
        }

        return threadObject
    }

    private struct EnrichedParticipant {
        var object: JSONObject
        var isSelf: Bool
        var hasContactName: Bool
    }

    private static func enrichParticipantJSON(
        _ participantObject: JSONObject,
        resolver: any CLIContactResolving
    ) -> EnrichedParticipant {
        var participantObject = participantObject
        let isSelf = participantObject["isSelf"] as? Bool == true
        var hasContactName = participantObject.string("nickname")?.nonEmpty != nil
            || participantObject.string("fullName")?.nonEmpty != nil

        if let lookupValue = participantLookupValue(participantObject),
           let contact = resolver.resolvedContact(emailOrPhoneNumber: lookupValue) {
            if let nickname = contact.nickname?.nonEmpty {
                participantObject["nickname"] = nickname
                hasContactName = true
            }
            if let fullName = contact.fullName?.nonEmpty {
                participantObject["fullName"] = fullName
                hasContactName = true
            }
            if participantObject.string("imgURL")?.nonEmpty == nil,
               let imgURL = contact.imgURL?.nonEmpty {
                participantObject["imgURL"] = imgURL
            }
        }

        return EnrichedParticipant(
            object: participantObject,
            isSelf: isSelf,
            hasContactName: hasContactName
        )
    }

    private static func participantLookupValue(_ participantObject: JSONObject) -> String? {
        participantObject.string("email")?.nonEmpty
            ?? participantObject.string("phoneNumber")?.nonEmpty
    }

    private static func participantTitle(for participantObject: JSONObject) -> String? {
        participantObject.string("nickname")?.nonEmpty
            ?? participantObject.string("fullName")?.nonEmpty
            ?? participantObject.string("username")?.nonEmpty
            ?? participantObject.string("email")?.nonEmpty
            ?? participantObject.string("phoneNumber")?.nonEmpty
            ?? participantObject.string("id")?.nonEmpty
    }

    private static func derivedTitle(
        for threadObject: JSONObject,
        titleNames: [String],
        hasNamedContact: Bool
    ) -> String? {
        guard hasNamedContact else {
            return nil
        }

        if threadObject.string("type") == PlatformSDK.ThreadType.single.rawValue || titleNames.count == 1 {
            return titleNames.first
        }

        return formattedTitleList(titleNames)
    }

    private static func formattedTitleList(_ items: [String]) -> String {
        if #available(macOS 12, *) {
            return items.formatted(.list(type: .and, width: .short))
        }
        return ListFormatter.localizedString(byJoining: items)
    }
}
