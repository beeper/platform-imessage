import Foundation
import IMDatabase
import IMessageCore

enum ThreadMapper {
    struct PollingCursor {
        var maxRowID: Int
        var maxDateReadNanoseconds: Int
    }

    struct Context {
        var handleRowsByChatRowID: [Int: [MappedHandleRow]]
        var latestMessagesByChatGUID: [String: [PlatformSDK.Message]]
        var unreadCounts: [Int: Int]
        var dndState: Set<String>
        var currentUser: CurrentUser
        var accountID: String
    }

    static func mapAndHashThread(_ chat: MappedChatRow, context: Context) throws -> PlatformSDK.Thread {
        try mapThread(chat, context: context)
    }

    static func pollingCursor(from latestMessageRows: [MappedMessageRow]) -> PollingCursor? {
        guard !latestMessageRows.isEmpty else {
            return nil
        }
        let (maxRowID, maxDateReadNanoseconds) = latestMessageRows.reduce(into: (0, 0)) { result, row in
            result.0 = max(result.0, row.rowID)
            result.1 = max(result.1, row.dateRead ?? 0)
        }
        return PollingCursor(maxRowID: maxRowID, maxDateReadNanoseconds: maxDateReadNanoseconds)
    }

    private static func mapThread(_ chat: MappedChatRow, context: Context) throws -> PlatformSDK.Thread {
        let guid = chat.guid
        let handleRows = context.handleRowsByChatRowID[chat.rowID] ?? []
        let messages = context.latestMessagesByChatGUID[guid] ?? []
        let selfID = chat.lastAddressedHandle.flatMap(\.nonEmpty)
            ?? chat.accountLogin.map(mapAccountLogin).flatMap(\.nonEmpty)
            ?? context.currentUser.id
        let firstParticipantID = handleRows.first?.participantID

        let chatDisplayName = chat.displayName
        var participants = handleRows.compactMap { mapParticipant($0, chatDisplayName: chatDisplayName) }
        if context.currentUser.id != firstParticipantID {
            participants.append(mapSelfParticipant(selfID: selfID, currentUserID: context.currentUser.id))
        }

        let isGroup = chat.roomName?.isEmpty == false
        let isReadOnly = chat.state == 0 && chat.properties != nil
        let props = propertyListDictionary(chat.properties)
        let unreadCount = context.unreadCounts[chat.rowID] ?? 0

        return PlatformSDK.Thread(
            id: Hasher.thread.tokenizeRemembering(pii: guid),
            // Works around PAS's "map missing" behavior where the folder name
            // can otherwise be filled with the thread ID.
            folderName: "normal",
            title: chat.displayName,
            // This mirrors Poller+Unreads.swift. Desktop computes unread state
            // from `isMarkedUnread || unreadCount > 0`.
            isUnread: unreadCount > 0,
            isReadOnly: isReadOnly,
            isPinned: false,
            mutedUntil: context.dndState.contains(isGroup ? (chat.groupID ?? "") : (chat.chatIdentifier ?? "")) ? "forever" : nil,
            type: isGroup ? .group : .single,
            timestamp: appleDateMilliseconds(chat.msgDate),
            imgURL: chatPhotoURL(props: props, accountID: context.accountID),
            messages: PlatformSDK.Paginated(items: messages, hasMore: true),
            participants: PlatformSDK.Paginated(items: participants, hasMore: false),
            extra: compactDictionary([
                "isSMS": (guid.hasPrefix("SMS;") || guid.hasPrefix("RCS;")) ? true : nil,
            ]),
            original: Preferences.stripInternalFields ? nil : (try? encodeJSON([chat.object, handleRows.objects])) ?? "",
            unreadCount: unreadCount,
            isMarkedUnread: unreadCount > 0,
            lastReadMessageSortKey: appleDateMilliseconds(chat.lastReadMessageTimestamp),
            isLowPriority: false
        )
    }

    private static func mapParticipant(_ row: MappedHandleRow, chatDisplayName: String?) -> PlatformSDK.Participant? {
        guard let id = row.participantID, !id.isEmpty else {
            return nil
        }

        let isEmail = id.contains("@")
        let isBusiness = id.hasPrefix("urn:")
        let isPhone = !isBusiness && !isEmail && id.rangeOfCharacter(from: .decimalDigits) != nil
        let uncanonicalizedID = row.uncanonicalizedID
        // iMessage can canonicalize SMS shortcodes with suffixes like
        // `(smsft_rm)` or `(smsft)`. Prefer the raw ID for sender-ID heuristics.
        let idPreferringUncanonicalized = uncanonicalizedID ?? id

        let participantID = !isPhone ? (uncanonicalizedID ?? id) : id
        let username: String?
        let phoneNumber: String?
        let email: String?
        let fullName: String?
        if isBusiness {
            fullName = chatDisplayName
            email = nil
            phoneNumber = nil
            username = nil
        } else if isEmail {
            fullName = nil
            email = id
            phoneNumber = nil
            username = nil
        } else if isPhone {
            fullName = nil
            email = nil
            phoneNumber = id
            username = nil
        } else if likelyAlphanumericSenderID(idPreferringUncanonicalized) {
            // Use `username` to avoid first/last-name splitting and preserve
            // the sender ID as-is.
            fullName = nil
            email = nil
            phoneNumber = nil
            username = idPreferringUncanonicalized
        } else {
            fullName = nil
            email = nil
            phoneNumber = nil
            username = nil
        }

        return PlatformSDK.Participant(user: PlatformSDK.User(
            id: Hasher.participant.tokenizeRemembering(pii: participantID),
            username: username,
            phoneNumber: phoneNumber,
            email: email,
            fullName: fullName
        ))
    }

    private static func mapSelfParticipant(selfID: String, currentUserID: String) -> PlatformSDK.Participant {
        let participant = mapParticipant(
            MappedHandleRow(chatID: nil, participantID: selfID, uncanonicalizedID: nil),
            chatDisplayName: nil
        )
        let user = participant?.user
        return PlatformSDK.Participant(user: PlatformSDK.User(
            id: Hasher.participant.tokenizeRemembering(pii: currentUserID),
            username: user?.username,
            phoneNumber: user?.phoneNumber,
            email: user?.email,
            fullName: user?.fullName,
            isSelf: true
        ))
    }

    private static let numbersAndSymbolsRegex = try! NSRegularExpression(pattern: #"^[\d\s+\-()]+$"#)
    private static let alphanumericSenderIDRegex = try! NSRegularExpression(pattern: #"^[\da-zA-Z .&_/-]{1,11}$"#)

    private static func likelyAlphanumericSenderID(_ id: String) -> Bool {
        !id.matches(against: numbersAndSymbolsRegex)
            && id.matches(against: alphanumericSenderIDRegex)
    }

    private static func chatPhotoURL(props: JSONObject?, accountID: String) -> String? {
        // `chat.properties` is a bplist; group chats may store a groupPhotoGuid
        // that resolves via the thread-image asset route.
        guard let groupPhotoGuid = props?["groupPhotoGuid"] as? String else {
            return nil
        }
        return "asset://\(accountID)/thread-image/\(groupPhotoGuid)"
    }

    private static func propertyListDictionary(_ data: Data?) -> JSONObject? {
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? JSONObject else {
            return nil
        }
        return plist
    }
}
