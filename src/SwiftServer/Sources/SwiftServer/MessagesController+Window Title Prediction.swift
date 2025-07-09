import Logging
import Contacts
import IMDatabase
import SwiftServerFoundation
import Foundation

// we can no longer access the `com.apple.MobileSMS` defaults suite in recent
// macOS versions, which is done to defend against any potential misfires (sending
// a message to the wrong chat due to timing/ordering issues). to get around
// this, predict what the window title should be from database data, which we
// _do_ have access to, and check that instead

private let log = Logger(swiftServerLabel: "window-title-prediction")

private enum ChatMember {
    case contact(CNContact)
    case stranger(Handle)
}

@available(macOS 11, *)
extension MessagesController {
    // `address` looks like `chat01234…`
    private func predictGroupChatDisplayNames(forChatGUID guid: String) throws -> Set<String> {
        guard let contacts else {
            throw ErrorMessage("misfire prevention: contacts access not authorized")
        }

        let db: IMDatabase
        if let cachedDatabase {
            db = cachedDatabase
        } else {
            do {
                db = try IMDatabase()
            } catch {
                throw ErrorMessage("misfire prevention: couldn't open database: \(error)")
            }
            cachedDatabase = db
        }

        guard let chat = try db.chat(withGUID: guid) else {
            throw ErrorMessage("misfire prevention: couldn't find desired chat in the database at all")
        }

        // if the group chat has a custom display name, then only match against that
        if let displayName = chat.displayName {
            return [displayName]
        }

        let members = try db.handles(inChatWithGUID: guid).map { handle in
            if let contact = contacts.firstMatching(emailOrPhoneNumber: handle.id) {
                ChatMember.contact(contact)
            } else {
                ChatMember.stranger(handle)
            }
        }

        var predictions = Set<String>()

        func groupChatDisplayNamePredictions(formattingContactsUsingStyle style: Contacts.FormatStyle) throws -> Set<String> {
            let memberNames = try members.map { member in
                switch member {
                case let .contact(contact):
                    try contacts.formatPreferringShortStyle(contact: contact)
                        .orThrow(ErrorMessage("misfire prevention: couldn't format a group chat member's contact"))
                case let .stranger(handle): handle.id
                }
            }

            var predictions: Set<String> = [shortFormattedList(memberNames)]

            // HACK: in test group chats with a test account and myself (added
            // redundantly, which is possible during creation), for whatever
            // reason my clone appears at the end of the name list despite the
            // clone appearing _first_ in the database. account for this by
            // blindly adding a swapped prediction for group chats with only
            // two other people, which might help with some other edge cases
            // too
            if Defaults.swiftServer.bool(forKey: DefaultsKeys.predictionEnableSwapping), memberNames.count == 2 {
                predictions.insert(shortFormattedList([memberNames[1], memberNames[0]]))
            }

            return predictions
        }

        predictions.formUnion(try groupChatDisplayNamePredictions(formattingContactsUsingStyle: .standard))
        do {
            predictions.formUnion(try groupChatDisplayNamePredictions(formattingContactsUsingStyle: .short))
        } catch {
            log.warning("misfire prevention: couldn't format using short style to form display name proposals: \(error)")
        }
        return predictions
    }

    private func predictWindowTitles(forChatGUID guid: String) throws -> Set<String> {
        guard let contacts else {
            throw ErrorMessage("misfire prevention: contacts access not authorized")
        }

        let (_, type, address) = try splitThreadID(guid).orThrow(ErrorMessage("couldn't predict window titles: invalid thread id"))

        guard type == singleThreadType else {
            return try predictGroupChatDisplayNames(forChatGUID: guid)
        }

        // should map onto a single person
        guard let contact = contacts.firstMatching(emailOrPhoneNumber: address) else {
            throw ErrorMessage("misfire prevention: couldn't find a contact that matches the desired thread id")
        }

        return Set([
            // attempt to match against the private "short" contact format style
            // that prefers nicknames, since iMessage uses it for the window title
            contacts.format(contact: contact, style: .short),

            contacts.format(contact: contact, style: .standard),
        ].compactMap({ $0 }))
    }

    func assertSelectedThreadByPredictingWindowTitle(desiredChatGUID: String, currentWindowTitle: String) throws {
        if !Defaults.swiftServer.bool(forKey: DefaultsKeys.predictionPredictsGroupChats) {
            guard !threadIDIsForGroup(desiredChatGUID) else {
                log.debug("misfire prevention: not asserting for group chat; prediction for group chats is disabled")
                return
            }
        }

        let predictedWindowTitles = try predictWindowTitles(forChatGUID: desiredChatGUID)
#if DEBUG
        log.debug("[PII] predicted window titles: \(String(describing: predictedWindowTitles)), current window title: \(currentWindowTitle.quoted)")
#endif
        guard !predictedWindowTitles.isEmpty else {
            throw ErrorMessage("misfire prevention: couldn't predict any window titles")
        }
        guard predictedWindowTitles.contains(currentWindowTitle) else {
            throw ErrorMessage("misfire prevention: window title doesn't match any predictions")
        }

        log.debug("misfire prevention: successfully matched window title to an applicable contact")
    }
}


private extension String {
    var quoted: String {
        "\"\(self)\""
    }
}

private func shortFormattedList(_ items: [String]) -> String {
    if #available(*, macOS 12) {
        // e.g. "John & Jane" or "John, Jeff, & Jane"
        return items.formatted(.list(type: .and, width: .short))
    } else {
        log.error("not on macOS 12 or later, window title predictions are almost certainly wrong")
        // FIXME: this won't work because it doesn't use the short style
        return ListFormatter.localizedString(byJoining: items)
    }
}
